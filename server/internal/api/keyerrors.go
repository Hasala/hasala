package api

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"

	"github.com/jackc/pgx/v5"

	"github.com/salehtl/hasala/server/internal/auth"
	"github.com/salehtl/hasala/server/internal/oplog"
)

func (s *Server) sessionInfo(w http.ResponseWriter, r *http.Request) (auth.SessionInfo, bool) {
	if info, ok := r.Context().Value(sessionCtxKey{}).(auth.SessionInfo); ok {
		return info, true
	}
	token, ok := bearerToken(r)
	if !ok {
		writeUnauthorized(w)
		return auth.SessionInfo{}, false
	}
	info, err := s.Sessions.Info(r.Context(), token)
	if err != nil {
		if errors.Is(err, auth.ErrSessionInvalid) {
			writeUnauthorized(w)
			return auth.SessionInfo{}, false
		}
		s.logf("api: %s: session binding: %v", route(r), err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return auth.SessionInfo{}, false
	}
	return info, true
}

func (s *Server) requireBound(w http.ResponseWriter, r *http.Request, info auth.SessionInfo) bool {
	if info.WriterID == "" {
		writeErr(w, http.StatusForbidden, "writer_unbound", "")
		return false
	}
	var live bool
	err := s.Pool.QueryRow(r.Context(),
		`SELECT revoked_at IS NULL FROM writers WHERE user_id = $1 AND writer_id = $2`, info.UserID, info.WriterID).Scan(&live)
	if errors.Is(err, pgx.ErrNoRows) {
		writeErr(w, http.StatusForbidden, "writer_unbound", "")
		return false
	}
	if err != nil {
		s.logf("api: %s: bound writer: %v", route(r), err)
		writeErr(w, http.StatusInternalServerError, "internal", "")
		return false
	}
	if !live {
		writeErr(w, http.StatusForbidden, "writer_revoked", "")
		return false
	}
	return true
}

type StepUpProofWire struct {
	Kind      string          `json:"kind"`
	Assertion json.RawMessage `json:"assertion,omitempty"`
	WriterID  string          `json:"writer_id,omitempty"`
	Sig       string          `json:"sig,omitempty"`
	Verifier  string          `json:"verifier,omitempty"`
	Code      string          `json:"code,omitempty"`
}

type StepUpWire struct {
	Nonce string          `json:"nonce"`
	Proof StepUpProofWire `json:"proof"`
}

func decodeStepUp(w http.ResponseWriter, su *StepUpWire) (*auth.StepUpObject, bool) {
	if su == nil {
		return nil, true
	}
	nonce, err := base64.RawURLEncoding.DecodeString(su.Nonce)
	if err != nil || len(nonce) != 32 {
		writeErr(w, http.StatusBadRequest, "bad_request", "step_up.nonce is not 32 bytes of b64url")
		return nil, false
	}
	o := &auth.StepUpObject{Nonce: nonce, Proof: auth.StepUpProof{
		Kind: su.Proof.Kind, Assertion: su.Proof.Assertion, WriterID: su.Proof.WriterID, Code: su.Proof.Code,
	}}
	if su.Proof.Sig != "" {
		if o.Proof.Sig, err = base64.StdEncoding.DecodeString(su.Proof.Sig); err != nil {
			writeErr(w, http.StatusBadRequest, "bad_request", "step_up.proof.sig is not base64")
			return nil, false
		}
	}
	if su.Proof.Verifier != "" {
		if o.Proof.Verifier, err = base64.StdEncoding.DecodeString(su.Proof.Verifier); err != nil {
			writeErr(w, http.StatusBadRequest, "bad_request", "step_up.proof.verifier is not base64")
			return nil, false
		}
	}
	return o, true
}

func b64Field(w http.ResponseWriter, value, field string) ([]byte, bool) {
	b, err := base64.StdEncoding.DecodeString(value)
	if err != nil || value == "" {
		writeErr(w, http.StatusBadRequest, "bad_request", field+" is not base64")
		return nil, false
	}
	return b, true
}

func b64urlField(w http.ResponseWriter, value, field string) ([]byte, bool) {
	b, err := base64.RawURLEncoding.DecodeString(value)
	if err != nil || value == "" {
		writeErr(w, http.StatusBadRequest, "bad_request", field+" is not b64url")
		return nil, false
	}
	return b, true
}

var (
	b64    = base64.StdEncoding.EncodeToString
	b64url = base64.RawURLEncoding.EncodeToString
)

type keyErrCode struct {
	target error
	status int
	code   string
}

var keyErrCodes = []keyErrCode{
	{auth.ErrStepUpRequired, http.StatusForbidden, "step_up_required"},
	{auth.ErrStepUpFailed, http.StatusForbidden, "step_up_failed"},
	{auth.ErrStepUpBadRequest, http.StatusBadRequest, "bad_request"},
	{auth.ErrWriterUnbound, http.StatusForbidden, "writer_unbound"},
	{auth.ErrKeysRequired, http.StatusForbidden, "keys_required"},
	{oplog.ErrKeysRequired, http.StatusForbidden, "keys_required"},
	{auth.ErrBadWriterID, http.StatusBadRequest, "bad_writer_id"},
	{auth.ErrWriterMalformed, http.StatusBadRequest, "bad_request"},
	{auth.ErrKeysMalformed, http.StatusBadRequest, "bad_request"},
	{auth.ErrBadSignature, http.StatusBadRequest, "bad_signature"},
	{oplog.ErrHeadSignature, http.StatusBadRequest, "bad_signature"},
	{auth.ErrTooManyDevices, http.StatusConflict, "too_many_devices"},
	{auth.ErrHeadMoved, http.StatusConflict, "head_moved"},
	{auth.ErrNoSuchWriter, http.StatusNotFound, "not_found"},
	{auth.ErrNotYours, http.StatusNotFound, "not_found"},
	{auth.ErrWriterRevoked, http.StatusForbidden, "writer_revoked"},
	{auth.ErrDeviceOtherAccount, http.StatusConflict, "other_account_device"},
	{oplog.ErrWriterRevoked, http.StatusForbidden, "writer_revoked"},
	{oplog.ErrUnknownWriter, http.StatusForbidden, "writer_unbound"},
	{auth.ErrSessionBound, http.StatusConflict, "session_bound"},
	{auth.ErrKeysExist, http.StatusConflict, "keys_exist"},
	{auth.ErrNoKeys, http.StatusNotFound, "no_keys"},
	{auth.ErrPhraseUnseen, http.StatusConflict, "phrase_unseen"},
	{auth.ErrBadAuthorityKey, http.StatusBadRequest, "bad_request"},
	{auth.ErrCodeRejected, http.StatusForbidden, "code_rejected"},
	{auth.ErrRateLimited, http.StatusTooManyRequests, "rate_limited"},
	{auth.ErrEmailInUse, http.StatusConflict, "email_in_use"},
	{auth.ErrNotInvited, http.StatusForbidden, "not_invited"},
	{auth.ErrPasswordRejected, http.StatusForbidden, "password_rejected"},
	{auth.ErrRecoveryRefused, http.StatusForbidden, "recovery_refused"},
	{auth.ErrResetRefused, http.StatusForbidden, "reset_refused"},
	{auth.ErrNotApproved, http.StatusConflict, "not_approved"},
	{auth.ErrFreezeRefused, http.StatusForbidden, "freeze_refused"},
	{auth.ErrAccountFrozen, http.StatusForbidden, "account_frozen"},
	{auth.ErrConflict, http.StatusConflict, "conflict"},
	{auth.ErrLastAuthenticator, http.StatusConflict, "last_authenticator"},
	{auth.ErrLastPasskey, http.StatusConflict, "last_authenticator"},
	{auth.ErrBadEmail, http.StatusBadRequest, "bad_email"},
	{auth.ErrBadRequest, http.StatusBadRequest, "bad_request"},
	{auth.ErrNoSuchAccount, http.StatusNotFound, "not_found"},
	{auth.ErrPasskeyRejected, http.StatusForbidden, "passkey_rejected"},
}

func (s *Server) writeKeyErr(w http.ResponseWriter, r *http.Request, err error) {
	s.logf("api: %s: %v", route(r), err)
	for _, x := range keyErrCodes {
		if errors.Is(err, x.target) {
			if x.status == http.StatusTooManyRequests {
				w.Header().Set("Retry-After", "60")
			}
			writeErr(w, x.status, x.code, "")
			return
		}
	}
	switch {
	case errors.Is(err, auth.ErrBadName):
		detail := "display_name: characters"
		if errors.Is(err, auth.ErrBadNameLength) {
			detail = "display_name: length"
		}
		writeErr(w, http.StatusBadRequest, "bad_name", detail)
		return
	case errors.Is(err, auth.ErrUnavailable):
		w.Header().Set("Retry-After", "2")
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "")
		return
	}
	writeErr(w, http.StatusInternalServerError, "internal", "")
}
