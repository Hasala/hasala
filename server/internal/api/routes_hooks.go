package api

import (
	"cmp"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/salehtl/hasala/server/internal/gmailpush"
	"github.com/salehtl/hasala/server/internal/googlejwt"
	"github.com/salehtl/hasala/server/internal/outlookpush"
	"github.com/salehtl/hasala/server/internal/pushv2"
)

const (
	hookIPRate       = 20.0
	hookIPBurst      = 100
	hookIPMaxKeys    = 4096
	hookGlobalRate   = 100.0
	hookGlobalBurst  = 500
	hookLinkRate     = 60.0 / 3600.0
	hookLinkBurst    = 10
	hookLinkMaxKeys  = 10_000
	hookMaxBody      = 64 << 10
	hookMaxAuthBytes = 16 << 10
	hookDeadline     = 10 * time.Second
	hookMaxRows      = 10
)

const (
	outlookHookPath      = "/hooks/outlook/graph"
	outlookLifecyclePath = "/hooks/outlook/graph/lifecycle"
)

func (s *Server) mountHooks(mux *http.ServeMux) {
	g, o := s.gmailPush(), s.outlookPush()
	if g == nil && o == nil {
		return
	}
	var perIP *Limiter
	if g != nil {
		perIP = g.HookPerIP
	}
	if o != nil {
		perIP = cmp.Or(perIP, o.HookPerIP)
	}
	s.ensureLimiter(&perIP, hookIPRate, hookIPBurst, hookIPMaxKeys)
	if g != nil {
		g.HookPerIP = perIP
		s.ensureLimiter(&g.HookGlobal, hookGlobalRate, hookGlobalBurst, 1)
		s.ensureLimiter(&g.HookLink, hookLinkRate, hookLinkBurst, hookLinkMaxKeys)
		mux.HandleFunc("POST /hooks/gmail/pubsub", s.handleGmailHook)
	}
	if o != nil {
		o.HookPerIP = perIP
		if o.HookGlobal == nil || (g != nil && o.HookGlobal == g.HookGlobal) {
			o.HookGlobal = NewLimiter(hookGlobalRate, hookGlobalBurst, 1, s.now)
		}
		s.ensureLimiter(&o.HookLink, hookLinkRate, hookLinkBurst, hookLinkMaxKeys)
		mux.HandleFunc("POST "+outlookHookPath, func(w http.ResponseWriter, r *http.Request) {
			s.handleOutlookHook(w, r, false)
		})
		mux.HandleFunc("POST "+outlookLifecyclePath, func(w http.ResponseWriter, r *http.Request) {
			s.handleOutlookHook(w, r, true)
		})
	}
}

func (s *Server) handleGmailHook(w http.ResponseWriter, r *http.Request) {
	g := s.Gmail.Push
	g.Counters.Pushes.Add(1)
	ctx, cancel := context.WithTimeout(r.Context(), hookDeadline)
	defer cancel()
	if !g.HookPerIP.Allow(clientKey(r)) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "")
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, hookMaxBody))
	if err != nil {
		writeErr(w, http.StatusRequestEntityTooLarge, "too_large", "")
		return
	}
	authz := r.Header.Get("Authorization")
	const scheme = "bearer "
	if len(authz) <= len(scheme) || len(authz) > hookMaxAuthBytes || !strings.EqualFold(authz[:len(scheme)], scheme) {
		g.Counters.Unauthorized.Add(1)
		writeUnauthorized(w)
		return
	}
	claims, err := g.Hook.Verify(ctx, strings.TrimSpace(authz[len(scheme):]))
	if errors.Is(err, googlejwt.ErrKeySetUnavailable) {
		s.logf("api: gmail hook: %v", err)
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "")
		return
	}
	if err != nil {
		g.Counters.Unauthorized.Add(1)
		s.logf("api: gmail hook: token rejected: %v", err)
		writeUnauthorized(w)
		return
	}
	if claims.Email != g.ServiceAccount || !claims.EmailVerified {
		g.Counters.Forbidden.Add(1)
		writeErr(w, http.StatusForbidden, "forbidden", "")
		return
	}
	if !g.HookGlobal.Allow("") {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "")
		return
	}
	n, err := gmailpush.ParseEnvelope(body, g.Subscription)
	switch {
	case errors.Is(err, gmailpush.ErrForeignSubscription):
		g.Counters.ForeignSubscription.Add(1)
		w.WriteHeader(http.StatusNoContent)
		return
	case err != nil:
		g.Counters.Malformed.Add(1)
		w.WriteHeader(http.StatusNoContent)
		return
	}
	addrHMAC := s.Gmail.RouteKey.AddressHMAC(n.EmailAddress)
	n = gmailpush.Notice{}
	linkKey := hex.EncodeToString(addrHMAC)
	if !g.HookLink.Allow(linkKey) {
		g.Counters.LinkLimited.Add(1)
		w.WriteHeader(http.StatusNoContent)
		return
	}
	holders, err := s.gmailHolders(ctx, addrHMAC)
	if err != nil {
		s.logf("api: gmail hook: route: %v", err)
		g.HookLink.RefundN(linkKey, 1)
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "")
		return
	}
	if len(holders) == 0 {
		g.Counters.Unknown.Add(1)
		w.WriteHeader(http.StatusNoContent)
		return
	}
	hour := s.now().UTC().Truncate(time.Hour)
	tripped := s.fuseTripped()
	allQueued := true
	for _, h := range holders {
		if !s.queueWake(ctx, h, pushv2.ReasonMail) {
			allQueued = false
			continue
		}
		g.Counters.Woken.Add(1)
		if !tripped {
			s.markWakeHour(ctx, gmailpush.ProviderGmail, h, hour)
		}
	}
	if !allQueued {
		g.HookLink.RefundN(linkKey, 1)
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) gmailHolders(ctx context.Context, addrHMAC []byte) ([]gmailpush.Holder, error) {
	rows, err := s.Pool.Query(ctx,
		`SELECT user_id, holder_writer_id FROM mailbox_links
		  WHERE address_hmac = $1 AND route_key_id = $2 AND provider = 'gmail' LIMIT $3`,
		addrHMAC, s.Gmail.RouteKey.KeyID(), hookMaxRows)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var holders []gmailpush.Holder
	for rows.Next() {
		var h gmailpush.Holder
		if err := rows.Scan(&h.UserID, &h.WriterID); err != nil {
			return nil, err
		}
		holders = append(holders, h)
	}
	return holders, rows.Err()
}

func (s *Server) queueWake(ctx context.Context, h gmailpush.Holder, r pushv2.Reason) bool {
	wake := context.WithoutCancel(ctx)
	waker := s.waker()
	if q, ok := waker.(gmailpush.QueueingWaker); ok {
		return q.TryWakeWriter(wake, h.UserID, h.WriterID, r)
	}
	waker.WakeWriter(wake, h.UserID, h.WriterID, r)
	return true
}

func (s *Server) handleOutlookHook(w http.ResponseWriter, r *http.Request, lifecycle bool) {
	o := s.Outlook.Push
	if !o.HookPerIP.Allow(clientKey(r)) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "")
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, hookMaxBody))
	if err != nil {
		writeErr(w, http.StatusRequestEntityTooLarge, "too_large", "")
		return
	}
	if q := r.URL.Query(); q.Has("validationToken") {
		if len(body) != 0 {
			o.Counters.ValidationWithBody.Add(1)
			w.WriteHeader(http.StatusNoContent)
			return
		}
		toks := q["validationToken"]
		if len(toks) != 1 || !outlookpush.ValidToken(toks[0]) {
			o.Counters.BadValidation.Add(1)
			writeErr(w, http.StatusBadRequest, "bad_request", "")
			return
		}
		o.Counters.Validations.Add(1)
		h := w.Header()
		h.Set("Content-Type", "text/plain; charset=utf-8")
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Cache-Control", "no-store")
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, toks[0])
		return
	}

	o.Counters.Notifications.Add(1)
	p, err := outlookpush.Parse(body, lifecycle)
	if err != nil {
		o.Counters.Malformed.Add(1)
		w.WriteHeader(http.StatusNoContent)
		return
	}
	o.Counters.BadClientState.Add(int64(p.BadClientState))
	o.Counters.Ignored.Add(int64(p.Ignored))
	if len(p.Hashes) == 0 {
		w.WriteHeader(http.StatusAccepted)
		return
	}
	hashes := hashBytes(p.Hashes)

	ctx, cancel := context.WithTimeout(r.Context(), hookDeadline)
	defer cancel()
	rows, err := s.Pool.Query(ctx,
		`SELECT client_state_hash, user_id, holder_writer_id FROM mailbox_links
		  WHERE provider = 'outlook' AND client_state_hash = ANY($1::bytea[])`, hashes)
	if err != nil {
		s.logf("api: outlook hook: route: %v", err)
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "")
		return
	}
	type match struct {
		hash []byte
		h    gmailpush.Holder
	}
	var matched []match
	for rows.Next() {
		var m match
		if err := rows.Scan(&m.hash, &m.h.UserID, &m.h.WriterID); err != nil {
			rows.Close()
			s.logf("api: outlook hook: route: %v", err)
			writeErr(w, http.StatusServiceUnavailable, "unavailable", "")
			return
		}
		matched = append(matched, m)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		s.logf("api: outlook hook: route: %v", err)
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "")
		return
	}
	o.Counters.Unknown.Add(int64(len(hashes) - len(matched)))
	if len(p.Removed)+len(p.Reauthorize) > 0 && !s.fuseTripped() {
		if _, err := s.Pool.Exec(ctx,
			`UPDATE mailbox_links
			    SET watch_expires_at = CASE WHEN client_state_hash = ANY($1::bytea[]) THEN NULL ELSE $3::timestamptz END,
			        updated_at = $3
			  WHERE provider = 'outlook'
			    AND (client_state_hash = ANY($1::bytea[]) AND watch_expires_at IS NOT NULL
			         OR client_state_hash = ANY($2::bytea[]) AND watch_expires_at > $3)`,
			hashBytes(p.Removed), hashBytes(p.Reauthorize), s.now()); err != nil {
			s.logf("api: outlook hook: end watch: %v", err)
			writeErr(w, http.StatusServiceUnavailable, "unavailable", "")
			return
		}
	}
	var (
		holders []gmailpush.Holder
		spent   []string
	)
	for _, m := range matched {
		key := hex.EncodeToString(m.hash)
		if !o.HookLink.Allow(key) {
			o.Counters.LinkLimited.Add(1)
			continue
		}
		holders = append(holders, m.h)
		spent = append(spent, key)
	}
	if len(holders) > 0 && !o.HookGlobal.Allow("") {
		for _, key := range spent {
			o.HookLink.RefundN(key, 1)
		}
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "")
		return
	}

	reason := pushv2.ReasonMail
	if lifecycle {
		reason = pushv2.ReasonNudge
	}
	hour := s.now().UTC().Truncate(time.Hour)
	tripped := s.fuseTripped()
	allQueued := true
	for _, h := range holders {
		if !s.queueWake(ctx, h, reason) {
			allQueued = false
			continue
		}
		o.Counters.Woken.Add(1)
		if !lifecycle && !tripped {
			s.markWakeHour(ctx, gmailpush.ProviderOutlook, h, hour)
		}
	}
	if !allQueued {
		for _, key := range spent {
			o.HookLink.RefundN(key, 1)
		}
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "")
		return
	}
	w.WriteHeader(http.StatusAccepted)
}

func hashBytes(hashes [][sha256.Size]byte) [][]byte {
	out := make([][]byte, len(hashes))
	for i := range hashes {
		out[i] = hashes[i][:]
	}
	return out
}

func (s *Server) markWakeHour(ctx context.Context, provider string, h gmailpush.Holder, hour time.Time) {
	if _, err := s.Pool.Exec(ctx,
		`UPDATE mailbox_links SET last_wake_hour = $3
		  WHERE user_id = $1 AND holder_writer_id = $2 AND provider = $4
		    AND last_wake_hour IS DISTINCT FROM $3`, h.UserID, h.WriterID, hour, provider); err != nil {
		s.logf("api: %s hook: wake hour: %v", provider, err)
	}
}
