package api

import (
	"encoding/hex"
	"net/http"
	"time"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/keyproto"
)

func (s *Server) mountStepUp(mux *http.ServeMux) {
	mux.HandleFunc("POST /api/v1/auth/step-up/begin", s.requireSessionForStepUpBegin(s.handleStepUpBegin))
}

type StepUpBeginRequest struct {
	Action     string `json:"action"`
	ParamsHash string `json:"params_hash"`
	ProofKind  string `json:"proof_kind"`
}

type StepUpBeginResponse struct {
	Nonce            string    `json:"nonce"`
	Challenge        string    `json:"challenge"`
	ExpiresAt        time.Time `json:"expires_at"`
	RPID             string    `json:"rp_id,omitempty"`
	AllowCredentials []string  `json:"allow_credentials,omitempty"`
}

func (s *Server) handleStepUpBegin(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	if !s.StepUpPerUser.Allow(userID.String()) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "too many step-ups; try again shortly")
		return
	}
	var req StepUpBeginRequest
	if !decodeBody(w, r, maxSmallBodyBytes, &req) {
		return
	}
	ph, err := hex.DecodeString(req.ParamsHash)
	if err != nil || len(ph) != 32 {
		writeErr(w, http.StatusBadRequest, "bad_request", "params_hash is not 64 hex characters")
		return
	}
	info, ok := s.sessionInfo(w, r)
	if !ok {
		return
	}
	st := info.Account
	if st.Suspended && keyproto.Action(req.Action) != keyproto.ActionAccountDelete {
		s.logf("api: %s: refused, the account is suspended", route(r))
		writeAccountSuspended(w)
		return
	}
	if keyproto.Action(req.Action) != keyproto.ActionAccountUnfreeze && (st.Frozen || info.Restricted) {
		writeErr(w, http.StatusForbidden, "account_frozen", "")
		return
	}
	b, err := s.StepUp.Begin(r.Context(), userID, info.Hash, info.WriterID,
		keyproto.Action(req.Action), ph, keyproto.ProofKind(req.ProofKind))
	if err != nil {
		s.writeKeyErr(w, r, err)
		return
	}
	out := StepUpBeginResponse{Nonce: b64url(b.Nonce), Challenge: b64url(b.Challenge[:]), ExpiresAt: b.ExpiresAt}
	if keyproto.ProofKind(req.ProofKind) == keyproto.ProofPasskey {
		if s.Passkeys != nil {
			out.RPID = s.Passkeys.RPID()
		}
		out.AllowCredentials = []string{}
		for _, c := range b.AllowCredentials {
			out.AllowCredentials = append(out.AllowCredentials, b64url(c))
		}
	}
	writeJSON(w, http.StatusOK, out)
}
