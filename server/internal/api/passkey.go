package api

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/auth"
	"github.com/salehtl/hasala/server/internal/pushv2"
)

const (
	passkeyPerIPRate   = 0.2
	passkeyPerIPBurst  = 12
	passkeyMaxKeys     = 4096
	passkeyPrefixRate  = 1
	passkeyPrefixBurst = 24
	passkeyGlobalRate  = 20
	passkeyGlobalBurst = 100
)

type PasskeyRegisterBeginRequest struct {
	SignupID        string `json:"signup_id"`
	AuthorityPubkey string `json:"authority_pubkey"`
}

type PasskeyRegisterBeginResponse struct {
	CeremonyID string          `json:"ceremony_id"`
	Nonce      string          `json:"nonce"`
	Options    json.RawMessage `json:"options"`
}

type PasskeyBeginResponse struct {
	CeremonyID string          `json:"ceremony_id"`
	Options    json.RawMessage `json:"options"`
}

type PasskeyFinishRequest struct {
	CeremonyID string          `json:"ceremony_id"`
	Credential json.RawMessage `json:"credential"`
}

type PasskeyAddBeginRequest struct {
	StepUp *StepUpWire `json:"step_up"`
}

type PasskeyAddFinishRequest struct {
	CeremonyID string            `json:"ceremony_id"`
	Credential json.RawMessage   `json:"credential"`
	PRFWrap    *BootstrapPRFWrap `json:"prf_wrap"`
	DWKSig     string            `json:"dwk_sig"`
}

type PasskeyAddResponse struct {
	CredentialID string `json:"credential_id"`
}

func (s *Server) passkeyLimited(h http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !s.PasskeyPerIP.Allow(clientKey(r)) || !s.globalAllow(r, s.PasskeyPerPrefix, s.PasskeyGlobal) {
			writeErr(w, http.StatusTooManyRequests, "rate_limited", "too many passkey attempts")
			return
		}
		h(w, r)
	}
}

func (s *Server) passkeyLimitedSession(h authedHandler) http.HandlerFunc {
	return s.passkeyLimited(s.requireSession(h))
}

func (s *Server) handlePasskeyRegisterBegin(w http.ResponseWriter, r *http.Request) {
	var req PasskeyRegisterBeginRequest
	if !decodeBody(w, r, maxSmallBodyBytes, &req) {
		return
	}
	authority, err := base64.StdEncoding.DecodeString(req.AuthorityPubkey)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", "authority_pubkey is not base64")
		return
	}
	id, opts, nonce, err := s.Passkeys.BeginRegistration(r.Context(), req.SignupID, authority)
	if err != nil {
		if errors.Is(err, auth.ErrBadAuthorityKey) {
			writeErr(w, http.StatusBadRequest, "bad_request", "authority_pubkey is not a usable Ed25519 public key")
			return
		}
		s.writeKeyErr(w, r, err)
		return
	}
	raw, err := json.Marshal(opts)
	if err != nil {
		s.logf("api: passkey register/begin: marshal options: %v", err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	writeJSON(w, http.StatusOK, PasskeyRegisterBeginResponse{CeremonyID: id, Nonce: b64(nonce), Options: raw})
}

func (s *Server) handlePasskeyRegisterFinish(w http.ResponseWriter, r *http.Request) {
	var req PasskeyFinishRequest
	if !decodeBody(w, r, maxSmallBodyBytes, &req) {
		return
	}
	out, err := s.Passkeys.FinishRegistrationSession(r.Context(), req.CeremonyID, req.Credential, s.Sessions)
	if err != nil {
		s.writeKeyErr(w, r, err)
		return
	}
	writeJSON(w, http.StatusCreated, SessionMintResponse{SessionToken: out.Session.Token, UserID: out.UserID.String(),
		ExpiresAt: out.Session.ExpiresAt.UTC()})
}

func (s *Server) handlePasskeyLoginBegin(w http.ResponseWriter, r *http.Request) {
	id, opts, err := s.Passkeys.BeginLogin(r.Context())
	if err != nil {
		s.writeKeyErr(w, r, err)
		return
	}
	s.writeBegin(w, r, id, opts)
}

func (s *Server) handlePasskeyLoginFinish(w http.ResponseWriter, r *http.Request) {
	var req PasskeyLoginFinishRequest
	if !decodeBody(w, r, maxSmallBodyBytes, &req) {
		return
	}
	device, ok := decodeDevice(w, req.Device)
	if !ok {
		return
	}
	out, err := s.accounts().PasskeyLoginFinish(r.Context(), req.CeremonyID, req.Credential, device)
	if err != nil {
		s.writeKeyErr(w, r, err)
		return
	}
	writeJSON(w, http.StatusOK, signInResponse(out))
}

type PasskeyLoginFinishRequest struct {
	CeremonyID string          `json:"ceremony_id"`
	Credential json.RawMessage `json:"credential"`
	Device     *DeviceWire     `json:"device"`
}

type DeviceWire struct {
	WriterID string `json:"writer_id"`
	Sig      string `json:"sig"`
}

func decodeDevice(w http.ResponseWriter, d *DeviceWire) (*auth.DeviceBinding, bool) {
	if d == nil {
		return nil, true
	}
	sig, ok := b64Field(w, d.Sig, "device.sig")
	if !ok {
		return nil, false
	}
	return &auth.DeviceBinding{WriterID: d.WriterID, Sig: sig}, true
}

func (s *Server) accounts() *auth.Accounts {
	if s.Accounts != nil {
		return s.Accounts
	}
	return &auth.Accounts{Pool: s.Pool, Sessions: s.Sessions, Passkeys: s.Passkeys, StepUp: s.StepUp, Now: s.Now, Record: s.recordRestore, Hold: s.holdRestore}
}

func (s *Server) handlePasskeyAddBegin(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	if !s.AccountPerUser.Allow(userID.String()) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "too many attempts; try again shortly")
		return
	}
	var req PasskeyAddBeginRequest
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
	if !s.requireBound(w, r, info) {
		return
	}
	id, opts, err := s.Passkeys.AddBegin(r.Context(), info, su)
	if err != nil {
		s.writeKeyErr(w, r, err)
		return
	}
	s.writeBegin(w, r, id, opts)
}

func (s *Server) handlePasskeyAddFinish(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	if !s.AccountPerUser.Allow(userID.String()) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "too many attempts; try again shortly")
		return
	}
	var req PasskeyAddFinishRequest
	if !decodeBody(w, r, maxSmallBodyBytes, &req) {
		return
	}
	sig, ok := b64Field(w, req.DWKSig, "dwk_sig")
	if !ok {
		return
	}
	add := auth.PasskeyAdd{CeremonyID: req.CeremonyID, Credential: req.Credential, DWKSig: sig}
	if req.PRFWrap != nil {
		if add.PRFCredentialID, ok = b64urlField(w, req.PRFWrap.CredentialID, "prf_wrap.credential_id"); !ok {
			return
		}
		if add.PRFWrap, ok = b64Field(w, req.PRFWrap.Wrap, "prf_wrap.wrap"); !ok {
			return
		}
		add.PRFWrapVersion = req.PRFWrap.WrapVersion
	}
	info, ok := s.sessionInfo(w, r)
	if !ok {
		return
	}
	if !s.requireBound(w, r, info) {
		return
	}
	credID, err := s.Passkeys.AddFinish(r.Context(), info, add)
	if err != nil {
		s.writeKeyErr(w, r, err)
		return
	}
	s.wakeOthers(r.Context(), userID, info.WriterID, pushv2.ReasonSecurity)
	writeJSON(w, http.StatusCreated, PasskeyAddResponse{CredentialID: b64url(credID)})
}

func (s *Server) writeBegin(w http.ResponseWriter, r *http.Request, ceremonyID string, opts any) {
	raw, err := json.Marshal(opts)
	if err != nil {
		s.logf("api: %s: marshal ceremony options: %v", route(r), err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return
	}
	writeJSON(w, http.StatusOK, PasskeyBeginResponse{CeremonyID: ceremonyID, Options: raw})
}
