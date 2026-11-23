package api

import (
	"bytes"
	"encoding/base64"
	"errors"
	"net/http"
	"time"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/auth"
	"github.com/salehtl/hasala/server/internal/pushv2"
)

type PasskeySummary struct {
	CredentialID  string     `json:"credential_id"`
	CreatedAt     time.Time  `json:"created_at"`
	LastUsedAt    *time.Time `json:"last_used_at"`
	Authenticator *string    `json:"authenticator"`
	Current       bool       `json:"current"`
}

type DeletePasskeyRequest struct {
	StepUp *StepUpWire `json:"step_up"`
}

type PasskeysResponse struct {
	Passkeys []PasskeySummary `json:"passkeys"`
}

func (s *Server) handleListPasskeys(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	creds, err := s.Passkeys.ListCredentials(r.Context(), userID)
	if err != nil {
		s.logf("api: list passkeys for %s: %v", userID, err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	var mine []byte
	if tok, ok := bearerToken(r); ok {
		var err error
		if mine, err = s.Sessions.CredentialForSession(r.Context(), tok); err != nil {
			s.logf("api: list passkeys for %s: resolve current credential: %v", userID, err)
			mine = nil
		}
	}

	out := PasskeysResponse{Passkeys: make([]PasskeySummary, 0, len(creds))}
	for _, c := range creds {
		out.Passkeys = append(out.Passkeys, PasskeySummary{
			CredentialID:  base64.StdEncoding.EncodeToString(c.ID),
			CreatedAt:     c.CreatedAt,
			LastUsedAt:    c.LastUsedAt,
			Authenticator: nil,
			Current:       len(mine) > 0 && bytes.Equal(mine, c.ID),
		})
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleDeletePasskey(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	raw, err := base64.StdEncoding.DecodeString(r.PathValue("credential_id"))
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", "credential id is not standard base64")
		return
	}

	if !s.AccountPerUser.Allow(userID.String()) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "too many attempts; try again shortly")
		return
	}
	var req DeletePasskeyRequest
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
	revoked, err := s.Passkeys.DeletePasskey(r.Context(), info, raw, su)
	switch {
	case err == nil:
	case errors.Is(err, auth.ErrLastPasskey):
		s.logf("api: delete passkey for %s: refused, it is the account's last credential", userID)
		writeErr(w, http.StatusConflict, "last_authenticator",
			"this is the only passkey on the account; removing it would lock you out permanently")
		return
	case errors.Is(err, auth.ErrCredentialUnknown):
		s.logf("api: delete passkey for %s: no such credential on this account", userID)
		writeErr(w, http.StatusNotFound, "not_found", "no such passkey on this account")
		return
	default:
		s.writeKeyErr(w, r, err)
		return
	}

	s.logf("api: delete passkey for %s: removed, revoked %d session(s) it had authenticated", userID, revoked)
	s.wakeOthers(r.Context(), userID, "", pushv2.ReasonSecurity)
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusNoContent)
}
