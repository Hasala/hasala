package auth

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/pgtx"
)

const ResetTTL = 10 * time.Minute

func (a *Accounts) ResetBegin(ctx context.Context, email string) (string, error) {
	addr, err := normEmail(email)
	if err != nil {
		return "", err
	}
	id, err := newCeremonyIDN(32)
	if err != nil {
		return "", err
	}
	nonce, err := randBytes(keyproto.NonceSize)
	if err != nil {
		return "", err
	}
	now := a.now()
	tx, err := pgtx.BeginReadCommitted(ctx, a.Pool)
	if err != nil {
		return "", err
	}
	defer pgtx.Rollback(ctx, tx)
	st, ok, err := accountByEmail(ctx, tx, addr)
	if err != nil {
		return "", err
	}
	eligible := ok && st.resettable()
	var userID *uuid.UUID
	if eligible {
		userID = &st.ID
	}
	code, err := issueCodeTx(ctx, tx, a.Keys, now, PurposePasswordReset, addr, userID, CeremonyPasswordReset, id, eligible)
	if err != nil {
		return "", err
	}
	if eligible {
		code.Name = st.DisplayName
	}
	if _, err := tx.Exec(ctx,
		`INSERT INTO password_reset_ceremonies (id, user_id, email_tag, code_id, reset_nonce, created_at, expires_at)
		 VALUES ($1, $2, $3, $4, $5, $6, $7)`,
		id, userID, a.Keys.EmailTag(addr), code.ID, nonce, now, now.Add(ResetTTL)); err != nil {
		return "", fmt.Errorf("auth: reset begin: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return "", err
	}
	a.Mail.SendCodes(code)
	return id, nil
}

type ResetVerified struct {
	Nonce     []byte
	Salt      []byte
	Approvers bool
}

func (a *Accounts) ResetVerify(ctx context.Context, resetID, code string) (ResetVerified, error) {
	now := a.now()
	var (
		codeID uuid.UUID
		userID *uuid.UUID
		nonce  []byte
	)
	err := a.Pool.QueryRow(ctx,
		`SELECT code_id, user_id, reset_nonce FROM password_reset_ceremonies
		  WHERE id = $1 AND verified_at IS NULL AND expires_at > $2`, resetID, now).Scan(&codeID, &userID, &nonce)
	if errors.Is(err, pgx.ErrNoRows) {
		return ResetVerified{}, fmt.Errorf("%w: no verifiable reset", ErrCodeRejected)
	}
	if err != nil {
		return ResetVerified{}, err
	}
	if err := limitCodeVerify(ctx, a.Pool, now, codeID); err != nil {
		return ResetVerified{}, err
	}
	var out ResetVerified
	err = a.consumeCode(ctx, codeCheck{CodeID: codeID, Purpose: PurposePasswordReset, CeremonyKind: CeremonyPasswordReset,
		CeremonyID: resetID, Submitted: code}, func(ctx context.Context, tx pgx.Tx) error {
		if userID == nil {
			return fmt.Errorf("%w: no eligible account", ErrCodeRejected)
		}
		if _, err := tx.Exec(ctx, `UPDATE password_reset_ceremonies SET verified_at = $2, expires_at = $3 WHERE id = $1`,
			resetID, now, now.Add(ResetTTL)); err != nil {
			return err
		}
		var email string
		if err := tx.QueryRow(ctx,
			`SELECT u.email_norm, EXISTS (SELECT 1 FROM writers w WHERE w.user_id = u.id AND w.revoked_at IS NULL)
			   FROM users u WHERE u.id = $1`, *userID).Scan(&email, &out.Approvers); err != nil {
			return err
		}
		out.Nonce, out.Salt = nonce, a.Keys.PasswordSalt(email)
		return nil
	})
	return out, err
}

func (a *Accounts) ResetRequest(ctx context.Context, resetID string, ekPub []byte) (Wake, error) {
	if keyproto.CheckEd25519PublicKey(ekPub) != nil {
		return Wake{}, fmt.Errorf("%w: ek_pub", ErrResetRefused)
	}
	var userID uuid.UUID
	err := a.Pool.QueryRow(ctx,
		`UPDATE password_reset_ceremonies SET ek_pubkey = $2
		  WHERE id = $1 AND verified_at IS NOT NULL AND expires_at > $3 AND ek_pubkey IS NULL AND user_id IS NOT NULL
		 RETURNING user_id`,
		resetID, ekPub, a.now()).Scan(&userID)
	if errors.Is(err, pgx.ErrNoRows) {
		return Wake{}, fmt.Errorf("%w: not a waiting ceremony", ErrResetRefused)
	}
	if err != nil {
		return Wake{}, err
	}
	return wakeFor(userID, "", nil), nil
}

type PendingReset struct {
	ResetID   string
	Nonce     []byte
	EKPub     []byte
	CreatedAt time.Time
}

func (a *Accounts) ResetPending(ctx context.Context, userID uuid.UUID) ([]PendingReset, error) {
	rows, err := a.Pool.Query(ctx,
		`SELECT id, reset_nonce, ek_pubkey, created_at FROM password_reset_ceremonies
		  WHERE user_id = $1 AND verified_at IS NOT NULL AND expires_at > $2 AND ek_pubkey IS NOT NULL
		    AND approved_at IS NULL ORDER BY created_at`, userID, a.now())
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []PendingReset{}
	for rows.Next() {
		var p PendingReset
		if err := rows.Scan(&p.ResetID, &p.Nonce, &p.EKPub, &p.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

func (a *Accounts) ResetApprove(ctx context.Context, session SessionInfo, resetID, writerID string, sig []byte) error {
	if writerID == "" || writerID != session.WriterID {
		return fmt.Errorf("%w: not the session's writer", ErrResetRefused)
	}
	tx, err := pgtx.BeginReadCommitted(ctx, a.Pool)
	if err != nil {
		return err
	}
	defer pgtx.Rollback(ctx, tx)
	now := a.now()
	var (
		nonce, ek []byte
		dak       []byte
		live      bool
	)
	err = tx.QueryRow(ctx,
		`SELECT reset_nonce, ek_pubkey FROM password_reset_ceremonies
		  WHERE id = $1 AND user_id = $2 AND verified_at IS NOT NULL AND expires_at > $3 AND ek_pubkey IS NOT NULL
		    AND approved_at IS NULL FOR UPDATE`, resetID, session.UserID, now).Scan(&nonce, &ek)
	if err != nil {
		return fmt.Errorf("%w: no ceremony awaiting approval", ErrResetRefused)
	}
	if err := tx.QueryRow(ctx, `SELECT dak_pubkey, revoked_at IS NULL FROM writers WHERE user_id = $1 AND writer_id = $2`,
		session.UserID, writerID).Scan(&dak, &live); err != nil || !live {
		return fmt.Errorf("%w: the writer is not live", ErrResetRefused)
	}
	msg, err := keyproto.ResetApproveMessage(nonce, session.UserID, ek, writerID)
	if err != nil || !keyproto.VerifyDAKBytes(dak, msg, sig) {
		return fmt.Errorf("%w: the approval does not verify", ErrResetRefused)
	}
	if _, err := tx.Exec(ctx,
		`UPDATE password_reset_ceremonies SET approved_by_writer = $2, approved_session = $3, approval_sig = $4, approved_at = $5
		  WHERE id = $1`,
		resetID, writerID, session.Hash, sig, now); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func (a *Accounts) ResetFinish(ctx context.Context, resetID string, verifier, ekSig []byte) (SignedIn, error) {
	if _, err := verifierHash(verifier); err != nil {
		return SignedIn{}, fmt.Errorf("%w: verifier", ErrResetRefused)
	}
	now := a.now()
	var (
		userID     *uuid.UUID
		nonce, ek  []byte
		approver   *string
		approvedAt *time.Time
		consumed   *time.Time
		expires    time.Time
	)
	err := a.Pool.QueryRow(ctx,
		`SELECT user_id, reset_nonce, ek_pubkey, approved_by_writer, approved_at, consumed_at, expires_at
		   FROM password_reset_ceremonies WHERE id = $1`, resetID).
		Scan(&userID, &nonce, &ek, &approver, &approvedAt, &consumed, &expires)
	if err != nil || userID == nil || ek == nil || consumed != nil || !expires.After(now) {
		return SignedIn{}, fmt.Errorf("%w: no ceremony to finish", ErrResetRefused)
	}
	if approvedAt == nil {
		return SignedIn{}, ErrNotApproved
	}
	msg, err := keyproto.ResetFinishMessage(nonce, verifier)
	if err != nil || !keyproto.VerifyEd25519(ek, msg, ekSig) {
		return SignedIn{}, fmt.Errorf("%w: ek_sig", ErrResetRefused)
	}
	hash, salt, err := newPasswordHash(ctx, a.Keys, a.Gate, verifier)
	if err != nil {
		return SignedIn{}, err
	}
	tx, err := pgtx.BeginReadCommitted(ctx, a.Pool)
	if err != nil {
		return SignedIn{}, err
	}
	defer pgtx.Rollback(ctx, tx)
	st, err := readAccount(ctx, tx, *userID, true)
	if err != nil {
		return SignedIn{}, fmt.Errorf("%w: %v", ErrResetRefused, err)
	}
	now = a.now()
	var approvedSession []byte
	err = tx.QueryRow(ctx,
		`UPDATE password_reset_ceremonies SET consumed_at = $2
		  WHERE id = $1 AND consumed_at IS NULL AND approved_at IS NOT NULL AND expires_at > $2
		 RETURNING approved_session`,
		resetID, now).Scan(&approvedSession)
	if errors.Is(err, pgx.ErrNoRows) {
		return SignedIn{}, fmt.Errorf("%w: already consumed or expired", ErrResetRefused)
	}
	if err != nil {
		return SignedIn{}, err
	}
	if !st.resettable() {
		return SignedIn{}, fmt.Errorf("%w: the account is no longer eligible", ErrResetRefused)
	}
	var live bool
	if err := tx.QueryRow(ctx, `SELECT revoked_at IS NULL FROM writers WHERE user_id = $1 AND writer_id = $2`,
		st.ID, *approver).Scan(&live); err != nil || !live {
		return SignedIn{}, fmt.Errorf("%w: the approver is gone", ErrResetRefused)
	}
	var sessionLive bool
	err = tx.QueryRow(ctx, `SELECT revoked_at IS NULL AND expires_at > $2 FROM sessions WHERE token_hash = $1 FOR SHARE`,
		approvedSession, now).Scan(&sessionLive)
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return SignedIn{}, err
	}
	if !sessionLive {
		return SignedIn{}, fmt.Errorf("%w: the approver's session is gone", ErrResetRefused)
	}
	if err := setPasswordTx(ctx, tx, st.ID, hash, salt, a.Keys.Current(), now); err != nil {
		return SignedIn{}, err
	}
	keep := [][]byte{approvedSession}
	revoked, err := RevokeOtherSessionsTx(ctx, tx, st.ID, keep, now)
	if err != nil {
		return SignedIn{}, err
	}
	if err := recordEventTx(ctx, tx, a.Mail, st.ID, AuthEvent{Kind: EventPasswordReset}, now); err != nil {
		return SignedIn{}, err
	}
	out, err := a.signInTx(ctx, tx, st, MintedPasswordReset, MethodPassword, nil, "")
	if err != nil {
		return SignedIn{}, err
	}
	held, err := a.Hold.Tx(ctx, tx, passwordEntry(st.ID, now))
	if err != nil {
		return SignedIn{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return SignedIn{}, err
	}
	held.Release(a.Record)
	a.Mail.Kick()
	out.Wake = wakeFor(st.ID, "", revoked)
	return out, nil
}
