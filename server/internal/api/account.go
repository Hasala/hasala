package api

import (
	"net/http"
	"time"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/auth"
	"github.com/salehtl/hasala/server/internal/pushv2"
)

type AccountUsage struct {
	OplogHotBytes int64 `json:"oplog_hot_bytes"`
	Limit         int64 `json:"limit"`
}

type AccountResponse struct {
	UserID                 string       `json:"user_id"`
	CreatedAt              time.Time    `json:"created_at"`
	Status                 string       `json:"status"`
	HasKeys                bool         `json:"has_keys"`
	Usage                  AccountUsage `json:"usage"`
	Email                  string       `json:"email"`
	EmailVerifiedAt        time.Time    `json:"email_verified_at"`
	EmailDeliverable       bool         `json:"email_deliverable"`
	EmailReverifyRequested bool         `json:"email_reverify_requested"`
	DisplayName            string       `json:"display_name"`
	HasPassword            bool         `json:"has_password"`
	PasswordSetAt          *time.Time   `json:"password_set_at"`
	PasswordSalt           string       `json:"password_salt"`
	HasPasskey             bool         `json:"has_passkey"`
	Frozen                 bool         `json:"frozen"`
	FreezeTriggerAt        *time.Time   `json:"freeze_trigger_at"`
	FrozenBy               *string      `json:"frozen_by"`
	HolderCanLift          *bool        `json:"holder_can_lift"`
	Restricted             bool         `json:"restricted"`
	ReviewAccount          bool         `json:"review_account"`
	PhraseUnseenSince      *time.Time   `json:"phrase_unseen_since"`
}

func (s *Server) handleGetAccount(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	info, ok := s.sessionInfo(w, r)
	if !ok {
		return
	}
	var (
		out      AccountResponse
		undeliv  *time.Time
		reverify *time.Time
		frozenAt *time.Time
	)
	err := s.Pool.QueryRow(r.Context(),
		`SELECT u.created_at, u.status, EXISTS (SELECT 1 FROM account_keys k WHERE k.user_id = u.id),
		        coalesce((SELECT amount FROM account_usage a WHERE a.user_id = u.id AND a.resource = 'oplog_hot_bytes'), 0),
		        coalesce((SELECT oplog_bytes FROM account_limits l WHERE l.user_id = u.id),
		                 (SELECT oplog_bytes FROM account_limits l WHERE l.user_id IS NULL)),
		        u.email_norm, u.email_verified_at, u.email_undeliverable_at, u.reverify_requested_at, u.display_name,
		        u.password_hash IS NOT NULL, u.password_set_at,
		        EXISTS (SELECT 1 FROM webauthn_credentials c WHERE c.user_id = u.id),
		        u.frozen_at, u.freeze_trigger_at, u.frozen_by, u.review_account,
		        (SELECT k.created_at FROM account_keys k WHERE k.user_id = u.id AND k.phrase_seen_at IS NULL)
		   FROM users u WHERE u.id = $1`, userID).
		Scan(&out.CreatedAt, &out.Status, &out.HasKeys, &out.Usage.OplogHotBytes, &out.Usage.Limit,
			&out.Email, &out.EmailVerifiedAt, &undeliv, &reverify, &out.DisplayName, &out.HasPassword, &out.PasswordSetAt,
			&out.HasPasskey, &frozenAt, &out.FreezeTriggerAt, &out.FrozenBy, &out.ReviewAccount, &out.PhraseUnseenSince)
	if err != nil {
		s.writeKeyErr(w, r, err)
		return
	}
	out.UserID = userID.String()
	out.EmailDeliverable = undeliv == nil
	out.EmailReverifyRequested = reverify != nil
	out.Frozen = frozenAt != nil
	if out.Frozen {
		canLift, err := auth.HolderCanLift(r.Context(), s.Pool, userID, info.WriterID)
		if err != nil {
			s.writeKeyErr(w, r, err)
			return
		}
		out.HolderCanLift = &canLift
	}
	out.Restricted = info.Restricted
	if s.Accounts != nil && s.Accounts.Keys != nil {
		out.PasswordSalt = b64(s.Accounts.Keys.PasswordSalt(out.Email))
	}
	writeJSON(w, http.StatusOK, out)
}

type DisplayNameRequest struct {
	DisplayName string `json:"display_name"`
}

func (s *Server) handleSetDisplayName(w http.ResponseWriter, r *http.Request, userID uuid.UUID) {
	var req DisplayNameRequest
	if !decodeBody(w, r, maxSmallBodyBytes, &req) {
		return
	}
	if err := s.Accounts.SetDisplayName(r.Context(), userID, req.DisplayName); err != nil {
		s.writeKeyErr(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

type PhraseViewResponse struct {
	PhraseBox string `json:"phrase_box"`
}

func (s *Server) handlePhraseView(w http.ResponseWriter, r *http.Request, _ uuid.UUID) {
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
	box, err := s.Accounts.ViewPhrase(r.Context(), info, su)
	if err != nil {
		s.writeKeyErr(w, r, err)
		return
	}
	s.wakeOthers(r.Context(), info.UserID, info.WriterID, pushv2.ReasonSecurity)
	writeJSON(w, http.StatusOK, PhraseViewResponse{PhraseBox: b64(box)})
}
