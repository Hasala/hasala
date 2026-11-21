package api

import (
	"bytes"
	"errors"
	"io"
	"net/http"
	"time"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/auth"
	"github.com/salehtl/hasala/server/internal/pushv2"
)

func (s *Server) mountSession(mux *http.ServeMux) {
	mux.HandleFunc("POST /api/v1/auth/logout", s.handleLogout)
	mux.HandleFunc("POST /api/v1/auth/logout-all", s.requireSession(s.handleLogoutAll))
	mux.HandleFunc("GET /api/v1/auth/session", s.requireSession(s.handleGetSession))
}

type SessionWire struct {
	UserID        string    `json:"user_id"`
	MintedBy      string    `json:"minted_by"`
	CreatedAt     time.Time `json:"created_at"`
	ExpiresAt     time.Time `json:"expires_at"`
	IdleExpiresAt time.Time `json:"idle_expires_at"`
	WriterID      *string   `json:"writer_id"`
	CredentialID  *string   `json:"credential_id"`
	Restricted    bool      `json:"restricted"`
}

func (s *Server) handleGetSession(w http.ResponseWriter, r *http.Request, _ uuid.UUID) {
	info, ok := s.sessionInfo(w, r)
	if !ok {
		return
	}
	out := SessionWire{UserID: info.UserID.String(), MintedBy: info.MintedBy, CreatedAt: info.CreatedAt.UTC(),
		ExpiresAt: info.ExpiresAt.UTC(), IdleExpiresAt: info.IdleExpires.UTC(), Restricted: info.Restricted}
	if info.WriterID != "" {
		wid := info.WriterID
		out.WriterID = &wid
	}
	if len(info.CredentialID) > 0 {
		c := b64url(info.CredentialID)
		out.CredentialID = &c
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleLogout(w http.ResponseWriter, r *http.Request) {
	token, ok := bearerToken(r)
	if !ok {
		writeUnauthorized(w)
		return
	}
	if !decodeEmptyBody(w, r) {
		return
	}
	userID, err := s.Sessions.Resolve(r.Context(), token)
	switch {
	case errors.Is(err, auth.ErrSessionAccountDeleted):
		writeAccountDeleted(w)
		return
	case errors.Is(err, auth.ErrSessionInvalid):
		writeUnauthorized(w)
		return
	case err != nil:
		s.logf("api: logout: resolve session: %v", err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	if !s.SessionPerUser.Allow(userID.String()) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "too many sign-outs; try again shortly")
		return
	}
	if err := s.Sessions.Revoke(r.Context(), token); err != nil {
		s.logf("api: logout for %s: %v", userID, err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleLogoutAll(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	if !s.AccountPerUser.Allow(userID.String()) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "too many sign-outs; try again shortly")
		return
	}
	var req StepUpOnlyRequest
	if !decodeBody(w, r, maxSmallBodyBytes, &req) {
		return
	}
	su, ok := decodeStepUp(w, req.StepUp)
	if !ok {
		return
	}
	info, ok := s.sessionInfo(w, r)
	if !ok {
		return
	}
	if su == nil {
		s.writeKeyErr(w, r, auth.ErrStepUpRequired)
		return
	}
	revoked, err := s.accounts().LogoutAll(r.Context(), info, su)
	if err != nil {
		s.writeKeyErr(w, r, err)
		return
	}
	s.wakeTokens(r.Context(), revoked, pushv2.ReasonSecurity)
	w.WriteHeader(http.StatusNoContent)
}

func decodeEmptyBody(w http.ResponseWriter, r *http.Request) bool {
	raw, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxSmallBodyBytes))
	if err != nil {
		writeErr(w, http.StatusRequestEntityTooLarge, "too_large", "this endpoint takes no body")
		return false
	}
	if len(bytes.TrimSpace(raw)) == 0 {
		return true
	}
	r.Body = io.NopCloser(bytes.NewReader(raw))
	var body struct{}
	return decodeBody(w, r, maxSmallBodyBytes, &body)
}
