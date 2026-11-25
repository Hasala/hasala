package api

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/auth"
	"github.com/salehtl/hasala/server/internal/config"
	"github.com/salehtl/hasala/server/internal/oplog"
)

const (
	maxUploadBlobs    = 8
	maxUploadBytes    = 12 << 20
	maxSmallBodyBytes = 64 << 10

	defaultPullLimit = 100
	maxPullLimit     = 500
	pullByteBudget   = 4 << 20

	defaultHashLimit = 1000
	maxHashLimit     = 5000
)

const (
	challengeRate    = 1.0 / 60.0
	challengeBurst   = 10
	challengeMaxKeys = 4096

	registerRate    = 2.0 / 60.0
	registerBurst   = 20
	registerMaxKeys = 4096

	accountRate    = 1.0 / 60.0
	accountBurst   = 10
	accountMaxKeys = 4096

	sessionRate    = 1.0 / 60.0
	sessionBurst   = 20
	sessionMaxKeys = 4096

	stepUpRate    = 10.0 / 60.0
	stepUpBurst   = 20
	stepUpMaxKeys = 4096

	pullRate           = 10.0
	pullBurst          = 50
	pullMaxKeys        = 4096
	maxConcurrentPulls = 2

	syncRate             = 2.0
	syncBurst            = 20
	syncMaxKeys          = 4096
	maxConcurrentUploads = 2

	syncByteBurst   = 64 << 20
	syncByteRate    = (256 << 20) / 86400.
	syncByteMaxKeys = 4096
)

type Server struct {
	Pool     *pgxpool.Pool
	Sessions *auth.Sessions
	Writers  *auth.Writers
	Appender *oplog.Appender

	StepUp      *auth.StepUp
	AccountKeys *auth.AccountKeys

	Accounts *auth.Accounts

	Passkeys *auth.Passkeys

	ChallengePerUser   *Limiter
	RegisterPerUser    *Limiter
	AccountPerUser     *Limiter
	SessionPerUser     *Limiter
	StepUpPerUser      *Limiter
	PullPerUser        *Limiter
	pulls              accountSlots
	PasskeyPerIP       *Limiter
	PasskeyPerPrefix   *Limiter
	PasskeyGlobal      *Limiter
	SyncPerUser        *Limiter
	SyncUploadBytes    *Limiter
	uploads            accountSlots
	MetaPerIP          *Limiter
	RecoverPerIP       *Limiter
	CodePerIP          *Limiter
	ResetPerIP         *Limiter
	FreezePerIP        *Limiter
	FreezePerPrefix    *Limiter
	FreezeGlobal       *Limiter
	DevFreezeIP        *Limiter
	DevFreezePerPrefix *Limiter
	DevFreezeWriter    *Limiter
	DevFreezeGlobal    *Limiter

	Meta Meta

	Push     PushOptions
	Gmail    *GmailOptions
	Outlook  *OutlookOptions
	Web      *WebOptions
	BankUser *Limiter

	Headroom Fuse

	PullByteBudget int

	Logf func(format string, args ...any)

	TrustCloudflare bool

	Now func() time.Time

	PurgeLedger string
}

func NewServer(cfg config.Config, pool *pgxpool.Pool) (*Server, error) {
	if pool == nil {
		return nil, errors.New("api: NewServer: pool is nil")
	}
	if cfg.Auth.SessionIdle <= 0 {
		return nil, errors.New("api: NewServer: auth.session_idle must be positive")
	}
	now := time.Now
	s := &Server{
		Pool:     pool,
		Sessions: &auth.Sessions{Pool: pool, TTL: cfg.Auth.SessionIdle},
		Writers:  &auth.Writers{Pool: pool},
		Appender: &oplog.Appender{Pool: pool},
		Now:      now,

		TrustCloudflare: cfg.Server.TrustedProxy == config.ProxyCloudflare,
		PurgeLedger:     cfg.Server.PurgeLedgerPath,
		Meta: Meta{
			RPID:          cfg.Auth.RPID,
			MinIOSBuild:   cfg.Server.MinIOSBuild,
			LogGeneration: cfg.Server.LogGeneration,
		},
	}
	if cfg.Auth.RPID != "" {
		pk, err := auth.NewPasskeys(pool, cfg.Auth.RPID, cfg.Auth.RPDisplayName, cfg.Auth.RPOrigins)
		if err != nil {
			return nil, errors.New("api: NewServer: " + err.Error())
		}
		s.Passkeys = pk
	}
	s.StepUp = &auth.StepUp{Pool: pool, Passkeys: s.Passkeys}
	if s.Passkeys != nil {
		s.Passkeys.StepUp = s.StepUp
		s.Passkeys.Record = s.recordRestore
		s.Passkeys.Hold = s.holdRestore
	}
	s.Writers.StepUp = s.StepUp
	s.Writers.Record = s.recordRestore
	s.Writers.Hold = s.holdRestore
	s.AccountKeys = &auth.AccountKeys{Pool: pool, StepUp: s.StepUp, Record: s.recordRestore, Hold: s.holdRestore}
	s.Sessions.Max = cfg.Auth.SessionMax
	return s, nil
}

func (s *Server) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

func route(r *http.Request) string {
	if r.Pattern != "" {
		return r.Pattern
	}
	return r.Method + " (unmatched)"
}

func (s *Server) logf(format string, args ...any) {
	if s.Logf != nil {
		s.Logf(format, args...)
		return
	}
	log.Printf(format, args...)
}

func (s *Server) Handler() http.Handler {
	s.ensureLimiter(&s.ChallengePerUser, challengeRate, challengeBurst, challengeMaxKeys)
	s.ensureLimiter(&s.RegisterPerUser, registerRate, registerBurst, registerMaxKeys)
	s.ensureLimiter(&s.AccountPerUser, accountRate, accountBurst, accountMaxKeys)
	s.ensureLimiter(&s.SessionPerUser, sessionRate, sessionBurst, sessionMaxKeys)
	s.ensureLimiter(&s.SyncPerUser, syncRate, syncBurst, syncMaxKeys)
	s.ensureLimiter(&s.SyncUploadBytes, syncByteRate, syncByteBurst, syncByteMaxKeys)
	s.ensureClientLimiter(&s.PasskeyPerIP, passkeyPerIPRate, passkeyPerIPBurst, passkeyMaxKeys)
	s.ensureLimiter(&s.PasskeyPerPrefix, passkeyPrefixRate, passkeyPrefixBurst, passkeyMaxKeys)
	s.ensureLimiter(&s.PasskeyGlobal, passkeyGlobalRate, passkeyGlobalBurst, 1)
	s.ensureClientLimiter(&s.MetaPerIP, metaRate, metaBurst, metaMaxKeys)
	s.ensureLimiter(&s.StepUpPerUser, stepUpRate, stepUpBurst, stepUpMaxKeys)
	s.ensureLimiter(&s.PullPerUser, pullRate, pullBurst, pullMaxKeys)
	if s.StepUp == nil {
		s.StepUp = &auth.StepUp{Pool: s.Pool, Passkeys: s.Passkeys}
	}
	if s.StepUp.Passkeys == nil {
		s.StepUp.Passkeys = s.Passkeys
	}
	if s.Passkeys != nil && s.Passkeys.StepUp == nil {
		s.Passkeys.StepUp = s.StepUp
	}
	if s.Writers != nil && s.Writers.StepUp == nil {
		s.Writers.StepUp = s.StepUp
	}
	if s.AccountKeys == nil {
		s.AccountKeys = &auth.AccountKeys{Pool: s.Pool, StepUp: s.StepUp, Record: s.recordRestore, Hold: s.holdRestore}
	}
	if s.PullByteBudget <= 0 {
		s.PullByteBudget = pullByteBudget
	}
	s.defaultAccountLimiters()

	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/v1/healthz", s.handleHealthz)
	s.mountMeta(mux)
	s.mountPasskeys(mux)
	s.mountKeys(mux)
	s.mountSync(mux)

	s.mountSession(mux)
	s.mountWriters(mux)
	s.mountAccount(mux)
	s.mountStepUp(mux)
	s.mountSignup(mux)
	s.mountPassword(mux)
	s.mountReset(mux)
	s.mountRecover(mux)
	s.mountEmail(mux)
	s.mountFreeze(mux)
	s.mountEvents(mux)
	s.mountPush(mux)
	s.mountMailboxLink(mux)
	s.mountHooks(mux)
	s.mountWaitlist(mux)
	s.mountBankRequests(mux)

	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		writeErr(w, http.StatusNotFound, "not_found", "no such endpoint")
	})
	return securityHeaders(s.withClientKey(s.clientGate(s.headroomGate(mux))))
}

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'")
		h.Set("Cross-Origin-Resource-Policy", "same-origin")
		next.ServeHTTP(w, r)
	})
}

func (s *Server) mountPasskeys(mux *http.ServeMux) {
	if s.Passkeys == nil {
		return
	}
	mux.HandleFunc("POST /api/v1/auth/passkey/register/begin", s.passkeyLimited(s.handlePasskeyRegisterBegin))
	mux.HandleFunc("POST /api/v1/auth/passkey/register/finish", s.passkeyLimited(s.handlePasskeyRegisterFinish))
	mux.HandleFunc("POST /api/v1/auth/passkey/login/begin", s.passkeyLimited(s.handlePasskeyLoginBegin))
	mux.HandleFunc("POST /api/v1/auth/passkey/login/finish", s.passkeyLimited(s.handlePasskeyLoginFinish))
	mux.HandleFunc("POST /api/v1/auth/passkey/add/begin", s.passkeyLimitedSession(s.handlePasskeyAddBegin))
	mux.HandleFunc("POST /api/v1/auth/passkey/add/finish", s.passkeyLimitedSession(s.handlePasskeyAddFinish))
	mux.HandleFunc("GET /api/v1/auth/passkeys", s.passkeyLimitedSession(s.handleListPasskeys))
	mux.HandleFunc("DELETE /api/v1/auth/passkeys/{credential_id}", s.passkeyLimitedSession(s.handleDeletePasskey))
}

func (s *Server) mountKeys(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/v1/key-history", s.requireSession(s.handleKeyHistory))
	mux.HandleFunc("GET /api/v1/keys", s.requireSession(s.handleGetKeys))
	mux.HandleFunc("POST /api/v1/account/bootstrap", s.requireSession(s.handleBootstrap))
	mux.HandleFunc("GET /api/v1/keys/wraps", s.requireSession(s.handleGetKeyWraps))
	mux.HandleFunc("POST /api/v1/keys/wraps", s.requireSession(s.handlePutKeyWrap))
	mux.HandleFunc("DELETE /api/v1/keys/wraps", s.requireSession(s.handleDeleteKeyWrap))
}

func (s *Server) mountSync(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/v1/sync", s.requireSession(s.handlePull))
	mux.HandleFunc("GET /api/v1/sync/hashes", s.requireSession(s.handleHashes))
	mux.HandleFunc("POST /api/v1/sync", s.requireSession(s.handleUpload))
}

type authedHandler func(w http.ResponseWriter, r *http.Request, userID uuid.UUID)

func (s *Server) requireSession(h authedHandler) http.HandlerFunc {
	return s.sessionGate(h, false, false)
}

func (s *Server) requireSessionFrozenOK(h authedHandler) http.HandlerFunc {
	return s.sessionGate(h, true, false)
}

func (s *Server) requireSessionSuspendedOK(h authedHandler) http.HandlerFunc {
	return s.sessionGate(h, false, true)
}

func (s *Server) requireSessionForStepUpBegin(h authedHandler) http.HandlerFunc {
	return s.sessionGate(h, true, true)
}

type sessionCtxKey struct{}

func (s *Server) sessionGate(h authedHandler, frozenOK, suspendedOK bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token, ok := bearerToken(r)
		if !ok {
			s.logf("api: %s: no bearer token", route(r))
			writeUnauthorized(w)
			return
		}
		info, err := s.Sessions.Info(r.Context(), token)
		if err != nil {
			if errors.Is(err, auth.ErrSessionAccountDeleted) {
				s.logf("api: %s: session belongs to a deleted account", route(r))
				writeAccountDeleted(w)
				return
			}
			if errors.Is(err, auth.ErrSessionInvalid) {
				s.logf("api: %s: session rejected: %v", route(r), err)
				writeUnauthorized(w)
				return
			}
			s.logf("api: %s: resolve session: %v", route(r), err)
			writeErr(w, http.StatusInternalServerError, "internal", "")
			return
		}
		userID := info.UserID
		st := info.Account
		if !frozenOK && (st.Frozen || info.Restricted) {
			s.logf("api: %s: refused, the account is frozen", route(r))
			writeErr(w, http.StatusForbidden, "account_frozen", "")
			return
		}
		if !isRead(r.Method) && st.Suspended && !suspendedOK {
			s.logf("api: %s: refused, the account is suspended", route(r))
			writeAccountSuspended(w)
			return
		}
		h(w, r.WithContext(context.WithValue(r.Context(), sessionCtxKey{}, info)), userID)
	}
}

func bearerToken(r *http.Request) (string, bool) {
	h := r.Header.Get("Authorization")
	const scheme = "bearer "
	if len(h) <= len(scheme) || !strings.EqualFold(h[:len(scheme)], scheme) {
		return "", false
	}
	tok := strings.TrimSpace(h[len(scheme):])
	if tok == "" {
		return "", false
	}
	return tok, true
}

type errorBody struct {
	Error  string      `json:"error"`
	Detail string      `json:"detail,omitempty"`
	Budget *BudgetInfo `json:"budget,omitempty"`
}

type BudgetInfo struct {
	Resource string `json:"resource"`
	Have     int64  `json:"have"`
	Delta    int64  `json:"delta"`
	Limit    int64  `json:"limit"`
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	buf, err := json.Marshal(v)
	if err != nil {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_, _ = w.Write(buf)
}

func writeErr(w http.ResponseWriter, status int, code, detail string) {
	writeJSON(w, status, errorBody{Error: code, Detail: detail})
}

func writeUnauthorized(w http.ResponseWriter) {
	w.Header().Set("WWW-Authenticate", "Bearer")
	writeJSON(w, http.StatusUnauthorized, errorBody{Error: "unauthorized"})
}

func writeAccountDeleted(w http.ResponseWriter) {
	writeJSON(w, http.StatusGone, errorBody{Error: "account_deleted"})
}

func decodeBody(w http.ResponseWriter, r *http.Request, max int64, dst any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, max)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		var tooLarge *http.MaxBytesError
		if errors.As(err, &tooLarge) {
			writeErr(w, http.StatusRequestEntityTooLarge, "too_large",
				"request body exceeds "+strconv.FormatInt(max, 10)+" bytes")
			return false
		}
		writeErr(w, http.StatusBadRequest, "bad_request", "body is not valid JSON for this endpoint")
		return false
	}
	if err := dec.Decode(&struct{}{}); err != io.EOF {
		writeErr(w, http.StatusBadRequest, "bad_request", "body carries more than one JSON value")
		return false
	}
	return true
}

func parseCursor(r *http.Request) (int64, error) {
	raw := r.URL.Query().Get("after")
	if raw == "" {
		return 0, nil
	}
	n, err := strconv.ParseInt(raw, 10, 64)
	if err != nil || n < 0 {
		return 0, errors.New("after must be a non-negative decimal seq")
	}
	return n, nil
}

func parseLimit(r *http.Request, def, max int) (int, error) {
	raw := r.URL.Query().Get("limit")
	if raw == "" {
		return def, nil
	}
	n, err := strconv.Atoi(raw)
	if err != nil || n < 1 {
		return 0, errors.New("limit must be a positive integer")
	}
	if n > max {
		n = max
	}
	return n, nil
}
