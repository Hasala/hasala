package api

import (
	"context"
	"errors"
	"net/http"
	"slices"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/salehtl/hasala/server/internal/auth"
	"github.com/salehtl/hasala/server/internal/pushv2"
)

const (
	pushRate    = 1.0 / 60.0
	pushBurst   = 20
	pushMaxKeys = 4096
)

type PushOptions struct {
	Waker        pushv2.Waker
	Environments []string
	PerUser      *Limiter
}

func (s *Server) waker() pushv2.Waker {
	if s.Push.Waker == nil {
		return pushv2.NopWaker{}
	}
	return s.Push.Waker
}

func (s *Server) wakeOthers(ctx context.Context, userID uuid.UUID, except string, r pushv2.Reason) {
	s.waker().WakeOthers(context.WithoutCancel(ctx), userID, except, r)
}

func (s *Server) accountTokens(ctx context.Context, userID uuid.UUID, except string) []pushv2.Target {
	return s.tokensOrLog(userID, func(q pushv2.Querier) ([]pushv2.Target, error) {
		return pushv2.CollectTokens(ctx, q, userID, except)
	})
}

func (s *Server) tokensOrLog(userID uuid.UUID, read func(pushv2.Querier) ([]pushv2.Target, error)) []pushv2.Target {
	if s.Pool == nil {
		return nil
	}
	t, err := read(s.Pool)
	if err != nil {
		s.logf("api: collect push tokens for %s: %v", userID, err)
		return nil
	}
	return t
}

func (s *Server) wakeTokens(ctx context.Context, t []pushv2.Target, r pushv2.Reason) {
	s.waker().WakeTokens(context.WithoutCancel(ctx), t, r)
}

func (s *Server) securityWake(ctx context.Context, w auth.Wake) {
	if w.UserID == uuid.Nil {
		return
	}
	s.wakeOthers(ctx, w.UserID, w.Except, pushv2.ReasonSecurity)
	if len(w.Revoked) > 0 {
		s.wakeTokens(ctx, w.Revoked, pushv2.ReasonSecurity)
	}
}

func (s *Server) mountPush(mux *http.ServeMux) {
	s.ensureLimiter(&s.Push.PerUser, pushRate, pushBurst, pushMaxKeys)
	mux.HandleFunc("PUT /api/v1/push/apns", s.requireSession(s.handlePutAPNs))
	mux.HandleFunc("GET /api/v1/push/apns", s.requireSession(s.handleGetAPNs))
	mux.HandleFunc("DELETE /api/v1/push/apns", s.requireSession(s.handleDeleteAPNs))
}

type PutAPNsRequest struct {
	TokenHex    string `json:"token_hex"`
	Environment string `json:"environment"`
}

type APNsDevice struct {
	WriterID    string    `json:"writer_id"`
	Environment string    `json:"environment"`
	CreatedAt   time.Time `json:"created_at"`
	UpdatedAt   time.Time `json:"updated_at"`
	Current     bool      `json:"current"`
}

type APNsDevicesResponse struct {
	Devices []APNsDevice `json:"devices"`
}

func (s *Server) environmentAllowed(env string) bool {
	if env != pushv2.EnvProduction && env != pushv2.EnvSandbox {
		return false
	}
	return len(s.Push.Environments) == 0 || slices.Contains(s.Push.Environments, env)
}

func (s *Server) handlePutAPNs(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	if !s.Push.PerUser.Allow(userID.String()) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "too many push registrations; try again shortly")
		return
	}
	var req PutAPNsRequest
	if !decodeBody(w, r, maxSmallBodyBytes, &req) {
		return
	}
	token := strings.ToLower(req.TokenHex)
	if !pushv2.ValidTokenHex(token) {
		writeErr(w, http.StatusBadRequest, "bad_request", "token_hex must be 32 to 100 bytes of hex")
		return
	}
	if !s.environmentAllowed(req.Environment) {
		writeErr(w, http.StatusBadRequest, "bad_request", "environment must be one this server accepts")
		return
	}
	info, ok := s.sessionInfo(w, r)
	if !ok || !s.requireBound(w, r, info) {
		return
	}
	tx, err := s.Pool.Begin(r.Context())
	if err != nil {
		s.logf("api: put apns for %s: begin: %v", userID, err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	defer func() { _ = tx.Rollback(context.WithoutCancel(r.Context())) }()
	now := s.now()
	if _, err := tx.Exec(r.Context(),
		`DELETE FROM apns_tokens a
		  WHERE a.token_hex = $1 AND NOT (a.user_id = $2 AND a.writer_id = $3)
		    AND (a.user_id = $2
		         OR NOT EXISTS (SELECT 1 FROM sessions s WHERE s.token_hash = a.session_hash
		              AND `+auth.LiveSessionSQL("s", "$4", "$5")+`)
		         OR EXISTS (SELECT 1 FROM writers w WHERE w.user_id = a.user_id AND w.writer_id = a.writer_id
		              AND w.revoked_at IS NOT NULL))`,
		token, userID, info.WriterID, now, s.Sessions.IdleSince(now)); err != nil {
		s.logf("api: put apns for %s: move: %v", userID, err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	if _, err := tx.Exec(r.Context(),
		`INSERT INTO apns_tokens (user_id, writer_id, session_hash, token_hex, environment, created_at, updated_at)
		 VALUES ($1, $2, $3, $4, $5, $6, $6)
		 ON CONFLICT (user_id, writer_id) DO UPDATE
		   SET session_hash = EXCLUDED.session_hash, token_hex = EXCLUDED.token_hex,
		       environment = EXCLUDED.environment, updated_at = EXCLUDED.updated_at`,
		userID, info.WriterID, info.Hash, token, req.Environment, now); err != nil {
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) && pgErr.Code == "23505" && pgErr.ConstraintName == "apns_tokens_token_uniq" {
			writeErr(w, http.StatusConflict, "token_in_use", "this device token is registered to another account")
			return
		}
		s.logf("api: put apns for %s: upsert: %v", userID, err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		s.logf("api: put apns for %s: commit: %v", userID, err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleGetAPNs(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	info, ok := s.sessionInfo(w, r)
	if !ok {
		return
	}
	rows, err := s.Pool.Query(r.Context(),
		`SELECT writer_id, environment, created_at, updated_at FROM apns_tokens WHERE user_id = $1 ORDER BY created_at, writer_id`,
		userID)
	if err != nil {
		s.logf("api: get apns for %s: %v", userID, err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	defer rows.Close()
	out := APNsDevicesResponse{Devices: []APNsDevice{}}
	for rows.Next() {
		var d APNsDevice
		if err := rows.Scan(&d.WriterID, &d.Environment, &d.CreatedAt, &d.UpdatedAt); err != nil {
			s.logf("api: get apns for %s: %v", userID, err)
			writeErr(w, http.StatusInternalServerError, "internal", "")
			return
		}
		d.Current = d.WriterID == info.WriterID && info.WriterID != ""
		out.Devices = append(out.Devices, d)
	}
	if err := rows.Err(); err != nil {
		s.logf("api: get apns for %s: %v", userID, err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleDeleteAPNs(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	if !s.Push.PerUser.Allow(userID.String()) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "too many push registrations; try again shortly")
		return
	}
	if !decodeEmptyBody(w, r) {
		return
	}
	info, ok := s.sessionInfo(w, r)
	if !ok || !s.requireBound(w, r, info) {
		return
	}
	if _, err := s.Pool.Exec(r.Context(),
		`DELETE FROM apns_tokens WHERE user_id = $1 AND writer_id = $2`, userID, info.WriterID); err != nil {
		s.logf("api: delete apns for %s: %v", userID, err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
