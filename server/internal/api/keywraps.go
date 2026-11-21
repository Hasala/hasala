package api

import (
	"net/http"
	"time"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/auth"
	"github.com/salehtl/hasala/server/internal/pushv2"
)

type KeyWrap struct {
	CredentialID string    `json:"credential_id"`
	Wrap         string    `json:"wrap"`
	WrapVersion  int       `json:"wrap_version"`
	CreatedAt    time.Time `json:"created_at"`
}

type KeyWrapsResponse struct {
	Wraps []KeyWrap `json:"wraps"`
}

type PutKeyWrapRequest struct {
	CredentialID string      `json:"credential_id"`
	Wrap         string      `json:"wrap"`
	WrapVersion  int         `json:"wrap_version"`
	DWKSig       string      `json:"dwk_sig"`
	StepUp       *StepUpWire `json:"step_up"`
}

type DeleteKeyWrapRequest struct {
	CredentialID string      `json:"credential_id"`
	StepUp       *StepUpWire `json:"step_up"`
}

func (s *Server) handleGetKeyWraps(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	wraps, err := s.AccountKeys.Wraps(r.Context(), userID)
	if err != nil {
		s.writeKeyErr(w, r, err)
		return
	}
	out := KeyWrapsResponse{Wraps: make([]KeyWrap, 0, len(wraps))}
	for _, x := range wraps {
		out.Wraps = append(out.Wraps, KeyWrap{CredentialID: b64url(x.CredentialID), Wrap: b64(x.Wrap),
			WrapVersion: x.WrapVersion, CreatedAt: x.CreatedAt})
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handlePutKeyWrap(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	if !s.AccountPerUser.Allow(userID.String()) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "too many attempts; try again shortly")
		return
	}
	var req PutKeyWrapRequest
	if !decodeBody(w, r, maxSmallBodyBytes, &req) {
		return
	}
	cred, ok := b64urlField(w, req.CredentialID, "credential_id")
	if !ok {
		return
	}
	wrap, ok := b64Field(w, req.Wrap, "wrap")
	if !ok {
		return
	}
	sig, ok := b64Field(w, req.DWKSig, "dwk_sig")
	if !ok {
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
	if !s.requireBound(w, r, info) {
		return
	}
	if err := s.AccountKeys.PutWrap(r.Context(), info, auth.WrapPut{
		CredentialID: cred, Wrap: wrap, WrapVersion: req.WrapVersion, DWKSig: sig, StepUp: su,
	}); err != nil {
		s.writeKeyErr(w, r, err)
		return
	}
	s.wakeOthers(r.Context(), userID, info.WriterID, pushv2.ReasonSecurity)
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleDeleteKeyWrap(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	if !s.AccountPerUser.Allow(userID.String()) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "too many attempts; try again shortly")
		return
	}
	var req DeleteKeyWrapRequest
	if !decodeBody(w, r, maxSmallBodyBytes, &req) {
		return
	}
	cred, ok := b64urlField(w, req.CredentialID, "credential_id")
	if !ok {
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
	if err := s.AccountKeys.DeleteWrap(r.Context(), info, cred, su); err != nil {
		s.writeKeyErr(w, r, err)
		return
	}
	s.wakeOthers(r.Context(), userID, info.WriterID, pushv2.ReasonSecurity)
	w.WriteHeader(http.StatusNoContent)
}
