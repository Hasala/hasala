package api

import (
	"context"
	"errors"
	"fmt"
	"net/http"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/salehtl/hasala/server/internal/auth"
	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/purge"
	"github.com/salehtl/hasala/server/internal/purgeledger"
	"github.com/salehtl/hasala/server/internal/pushv2"
)

type DeleteAccountRequest struct {
	StepUp   *StepUpWire `json:"step_up"`
	WriterID string      `json:"writer_id"`
	Sig      string      `json:"sig"`
}

func (s *Server) mountAccount(mux *http.ServeMux) {
	mux.HandleFunc("DELETE /api/v1/account", s.requireSessionSuspendedOK(s.handleDeleteAccount))
	mux.HandleFunc("GET /api/v1/account", s.requireSessionFrozenOK(s.handleGetAccount))
	if s.Accounts != nil {
		mux.HandleFunc("PUT /api/v1/account/display-name", s.requireSession(s.userLimited(s.handleSetDisplayName)))
		mux.HandleFunc("POST /api/v1/keys/phrase/view", s.requireSession(s.userLimited(s.handlePhraseView)))
	}
}

func (s *Server) handleDeleteAccount(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	if !s.AccountPerUser.Allow(userID.String()) {
		writeErr(w, http.StatusTooManyRequests, "rate_limited", "too many account requests; try again shortly")
		return
	}
	var req DeleteAccountRequest
	if !decodeBody(w, r, maxSmallBodyBytes, &req) {
		return
	}
	s.deleteWithStepUp(w, r, userID, req)
}

func (s *Server) deleteWithStepUp(w http.ResponseWriter, r *http.Request, userID uuid.UUID, req DeleteAccountRequest) {
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
	sig, ok := b64Field(w, req.Sig, "sig")
	if !ok {
		return
	}
	ph, err := keyproto.ParamsHash(keyproto.ActionAccountDelete, []byte(userID.String()))
	if err != nil {
		s.writeKeyErr(w, r, err)
		return
	}
	g := auth.Guarded{UserID: userID, SessionHash: info.Hash, BoundWriter: info.WriterID,
		Action: keyproto.ActionAccountDelete, ParamsHash: ph, StepUp: su}
	err = s.StepUp.Run(r.Context(), g, func(ctx context.Context, tx pgx.Tx, _ auth.Proven) error {
		var (
			pub  []byte
			live bool
		)
		err := tx.QueryRow(ctx, `SELECT pubkey, revoked_at IS NULL FROM writers WHERE user_id = $1 AND writer_id = $2`,
			userID, req.WriterID).Scan(&pub, &live)
		if errors.Is(err, pgx.ErrNoRows) || (err == nil && !live) {
			return fmt.Errorf("%w: the signer is not a live writer of the account", auth.ErrStepUpFailed)
		}
		if err != nil {
			return err
		}
		msg, err := keyproto.DeletionMessage(su.Nonce, userID)
		if err != nil || !keyproto.VerifyEd25519(pub, msg, sig) {
			return fmt.Errorf("%w: the deletion signature does not verify", auth.ErrStepUpFailed)
		}
		return nil
	})
	if err != nil {
		s.writeKeyErr(w, r, err)
		return
	}
	s.purgeAccount(w, r, userID)
}

func (s *Server) purgeAccount(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	tokens := s.accountTokens(r.Context(), userID, "")
	opts := purge.Options{Goodbye: true, Now: s.now}
	if s.Accounts != nil && s.Accounts.Keys != nil {
		opts.Tagger = s.Accounts.Keys
	}
	if s.PurgeLedger != "" {
		opts.Record = func(ids []uuid.UUID) error { return purgeledger.Append(s.PurgeLedger, ids, s.now()) }
		opts.Cancel = func(ids []uuid.UUID) error { return purgeledger.AppendCancelled(s.PurgeLedger, ids, s.now()) }
	}
	rep, err := purge.PurgeWith(r.Context(), s.Pool, userID, opts)
	if errors.Is(err, purge.ErrUnsettled) {
		s.logf("api: delete account %s: PURGE UNSETTLED: %v", userID, err)
		writeErr(w, http.StatusInternalServerError, "deletion_failed",
			"the deletion did not finish and may still take effect; this is a server-side "+
				"fault, not a problem with your request")
		return
	}
	if err != nil {
		s.logf("api: delete account %s: PURGE FAILED, account intact: %v", userID, err)
		writeErr(w, http.StatusInternalServerError, "deletion_failed",
			"the account was NOT deleted and nothing was removed; this is a server-side "+
				"fault, not a problem with your request")
		return
	}
	s.logf("api: delete account: purged %d rows across %d tables", rep.Total(), len(rep.Rows))
	if len(rep.SweptWithoutCascade) > 0 {
		s.logf("api: delete account %s: tables needed an explicit sweep (missing ON DELETE "+
			"CASCADE): %v", userID, rep.SweptWithoutCascade)
	}
	s.wakeTokens(r.Context(), tokens, pushv2.ReasonAccountGone)
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusNoContent)
}
