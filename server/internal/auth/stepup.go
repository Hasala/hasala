package auth

import (
	"context"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/authkeys"
	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/pgtx"
)

const StepUpTTL = 5 * time.Minute

const (
	deviceCodeBeginsPerHour = 5
	deviceCodeBurnPause     = 15 * time.Minute
)

var (
	ErrStepUpRequired   = errors.New("auth: step-up required")
	ErrStepUpFailed     = errors.New("auth: step-up failed")
	ErrStepUpBadRequest = errors.New("auth: step-up request is malformed")
	ErrWriterUnbound    = errors.New("auth: the session is not bound to a live writer")
)

type StepUpProof struct {
	Kind      string          `json:"kind"`
	Assertion json.RawMessage `json:"assertion,omitempty"`
	WriterID  string          `json:"writer_id,omitempty"`
	Sig       []byte          `json:"sig,omitempty"`
	Verifier  []byte          `json:"verifier,omitempty"`
	Code      string          `json:"code,omitempty"`
}

type StepUpObject struct {
	Nonce []byte      `json:"-"`
	Proof StepUpProof `json:"proof"`
}

type Proven struct {
	Kind         keyproto.ProofKind
	CredentialID []byte
	WriterID     string
	Nonce        []byte
}

type StepUp struct {
	Pool     *pgxpool.Pool
	Passkeys *Passkeys
	Keys     *authkeys.Keys
	Gate     *authkeys.Gate
	Mail     *Mailer
	Now      func() time.Time
}

func (s *StepUp) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

type Begun struct {
	Nonce            []byte
	Challenge        [32]byte
	ExpiresAt        time.Time
	AllowCredentials [][]byte
}

func (s *StepUp) Begin(ctx context.Context, userID uuid.UUID, sessionHash []byte, boundWriter string,
	action keyproto.Action, paramsHash []byte, kind keyproto.ProofKind) (Begun, error) {
	if s == nil || s.Pool == nil {
		return Begun{}, errors.New("auth: StepUp is not configured")
	}
	if !keyproto.ProofAllowed(action, kind) || len(paramsHash) != 32 || len(sessionHash) != 32 {
		return Begun{}, ErrStepUpBadRequest
	}
	now := s.now()
	tx, err := pgtx.BeginReadCommitted(ctx, s.Pool)
	if err != nil {
		return Begun{}, fmt.Errorf("auth: step-up begin: %w", err)
	}
	defer pgtx.Rollback(ctx, tx)
	if action == keyproto.ActionAccountUnfreeze {
		var by *string
		if err := tx.QueryRow(ctx, `SELECT frozen_by FROM users WHERE id = $1`, userID).Scan(&by); err != nil {
			return Begun{}, fmt.Errorf("auth: step-up begin: %w", err)
		}
		if by != nil && *by == "operator" {
			return Begun{}, fmt.Errorf("%w: an operator freeze", ErrAccountFrozen)
		}
	}
	if kind == keyproto.ProofDevice || kind == keyproto.ProofDeviceCode {
		live, err := liveWriterWithDAK(ctx, tx, userID, boundWriter)
		if err != nil {
			return Begun{}, err
		}
		if !live {
			return Begun{}, ErrWriterUnbound
		}
	}
	nonce, err := randBytes(keyproto.NonceSize)
	if err != nil {
		return Begun{}, err
	}
	c, err := keyproto.StepUpChallenge(nonce, action, [32]byte(paramsHash))
	if err != nil {
		return Begun{}, err
	}
	b := Begun{Nonce: nonce, Challenge: c, ExpiresAt: now.Add(StepUpTTL)}
	var (
		codeID any
		code   *IssuedCode
	)
	if kind == keyproto.ProofDeviceCode {
		if s.Keys == nil {
			return Begun{}, errors.New("auth: StepUp.Keys is nil")
		}
		var begins int
		var burned bool
		if err := tx.QueryRow(ctx,
			`SELECT (SELECT count(*) FROM step_up_challenges
			          WHERE user_id = $1 AND proof_kind = 'device_code' AND issued_at > $2),
			        EXISTS (SELECT 1 FROM email_codes WHERE user_id = $1 AND ceremony_kind = 'step_up'
			                   AND (burned_at > $3 OR (used_at IS NULL AND out_of_attempts_at > $3)))`,
			userID, now.Add(-time.Hour), now.Add(-deviceCodeBurnPause)).Scan(&begins, &burned); err != nil {
			return Begun{}, fmt.Errorf("auth: step-up begin: C8 budget: %w", err)
		}
		if begins >= deviceCodeBeginsPerHour || burned {
			return Begun{}, fmt.Errorf("%w: this account's reset codes", ErrRateLimited)
		}
		st, err := readAccount(ctx, tx, userID, false)
		if err != nil {
			return Begun{}, err
		}
		ic, err := issueCodeTx(ctx, tx, s.Keys, now, PurposePasswordReset, st.EmailNorm, &userID, CeremonyStepUp,
			hex.EncodeToString(nonce), true)
		if err != nil {
			return Begun{}, err
		}
		ic.Name = st.DisplayName
		codeID, code = ic.ID, &ic
	}
	if _, err := tx.Exec(ctx,
		`INSERT INTO step_up_challenges (nonce, user_id, session_hash, action, params_hash, proof_kind, code_id,
		   issued_at, expires_at)
		 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)`,
		nonce, userID, sessionHash, string(action), paramsHash, string(kind), codeID, now, b.ExpiresAt); err != nil {
		return Begun{}, fmt.Errorf("auth: record step-up: %w", err)
	}
	if kind == keyproto.ProofPasskey {
		rows, err := tx.Query(ctx,
			`SELECT credential_id FROM webauthn_credentials WHERE user_id = $1 ORDER BY created_at, credential_id`, userID)
		if err != nil {
			return Begun{}, fmt.Errorf("auth: step-up allow list: %w", err)
		}
		for rows.Next() {
			var id []byte
			if err := rows.Scan(&id); err != nil {
				rows.Close()
				return Begun{}, err
			}
			b.AllowCredentials = append(b.AllowCredentials, id)
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return Begun{}, err
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return Begun{}, fmt.Errorf("auth: step-up begin: commit: %w", err)
	}
	if code != nil {
		s.Mail.SendCodes(*code)
	}
	return b, nil
}

func liveWriterWithDAK(ctx context.Context, q querier, userID uuid.UUID, writerID string) (bool, error) {
	if writerID == "" {
		return false, nil
	}
	var live bool
	err := q.QueryRow(ctx,
		`SELECT revoked_at IS NULL FROM writers WHERE user_id = $1 AND writer_id = $2`, userID, writerID).Scan(&live)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("auth: read writer %s: %w", writerID, err)
	}
	return live, nil
}

type querier interface {
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

type Guarded struct {
	UserID      uuid.UUID
	SessionHash []byte
	BoundWriter string
	Action      keyproto.Action
	ParamsHash  [32]byte
	StepUp      *StepUpObject
}

func guardFor(session SessionInfo, action keyproto.Action, su *StepUpObject, fields ...[]byte) (Guarded, error) {
	ph, err := keyproto.ParamsHash(action, fields...)
	if err != nil {
		return Guarded{}, err
	}
	return Guarded{UserID: session.UserID, SessionHash: session.Hash, BoundWriter: session.WriterID,
		Action: action, ParamsHash: ph, StepUp: su}, nil
}

type failure func(ctx context.Context, tx pgx.Tx) (burn bool, err error)

func (s *StepUp) Run(ctx context.Context, g Guarded, action func(ctx context.Context, tx pgx.Tx, p Proven) error) error {
	if g.StepUp == nil || len(g.StepUp.Nonce) == 0 {
		return ErrStepUpRequired
	}
	ch, err := s.charge(ctx, g)
	if err != nil {
		if errors.Is(err, ErrStepUpFailed) {
			if ferr := s.fail(ctx, g, nil); ferr != nil {
				return ferr
			}
		}
		return err
	}
	abort := func(tx pgx.Tx) error {
		pgtx.Rollback(ctx, tx)
		return s.refund(ctx, g, ch)
	}
	tx, err := pgtx.BeginReadCommitted(ctx, s.Pool)
	if err != nil {
		if rerr := s.refund(ctx, g, ch); rerr != nil {
			return rerr
		}
		return fmt.Errorf("auth: step-up: begin: %w", err)
	}
	defer pgtx.Rollback(ctx, tx)
	p, fail, err := s.verify(ctx, tx, g, ch)
	if err != nil {
		pgtx.Rollback(ctx, tx)
		if fail == nil {
			if rerr := s.refund(ctx, g, ch); rerr != nil {
				return rerr
			}
		}
		if errors.Is(err, ErrStepUpFailed) {
			if ferr := s.fail(ctx, g, fail); ferr != nil {
				return ferr
			}
		}
		return err
	}
	if err := action(ctx, tx, p); err != nil {
		if rerr := abort(tx); rerr != nil {
			return rerr
		}
		if errors.Is(err, ErrStepUpFailed) {
			if ferr := s.fail(ctx, g, nil); ferr != nil {
				return ferr
			}
		}
		return err
	}
	if _, err := tx.Exec(ctx, `UPDATE step_up_challenges SET used_at = $2 WHERE nonce = $1`, g.StepUp.Nonce, s.now()); err != nil {
		if rerr := abort(tx); rerr != nil {
			return rerr
		}
		return fmt.Errorf("auth: step-up: spend: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		if rerr := s.refund(ctx, g, ch); rerr != nil {
			return rerr
		}
		return fmt.Errorf("auth: step-up: commit: %w", err)
	}
	return nil
}

type charged struct {
	writer bool
	code   bool
	at     time.Time
}

func (s *StepUp) charge(ctx context.Context, g Guarded) (charged, error) {
	kind := keyproto.ProofKind(g.StepUp.Proof.Kind)
	if kind != keyproto.ProofDevice && kind != keyproto.ProofDeviceCode {
		return charged{}, nil
	}
	ch, err := readChallenge(ctx, s.Pool, g.StepUp.Nonce, false)
	if errors.Is(err, ErrStepUpFailed) {
		return charged{}, nil
	}
	if err != nil {
		return charged{}, err
	}
	if s.checkChallenge(ch, g) != nil {
		return charged{}, nil
	}
	c, err := keyproto.StepUpChallenge(g.StepUp.Nonce, g.Action, g.ParamsHash)
	if err != nil || s.verifyDAK(ctx, s.Pool, g, c, g.StepUp.Proof.WriterID) != nil {
		return charged{}, nil
	}
	now := s.now()
	if kind == keyproto.ProofDevice {
		st, err := readAccount(ctx, s.Pool, g.UserID, false)
		if err != nil || !st.hasPassword() || s.Keys == nil {
			return charged{}, nil
		}
		if err := writerPasswordAttempt(ctx, s.Pool, g.UserID, g.StepUp.Proof.WriterID, now); err != nil {
			return charged{}, err
		}
		return charged{writer: true, at: now}, nil
	}
	if ch.codeID == nil {
		return charged{}, nil
	}
	if err := limitCodeVerify(ctx, s.Pool, now, *ch.codeID); err != nil {
		if errors.Is(err, ErrCodeRejected) {
			return charged{}, fmt.Errorf("%w: %v", ErrStepUpFailed, err)
		}
		return charged{}, err
	}
	return charged{code: true, at: now}, nil
}

func (s *StepUp) refund(ctx context.Context, g Guarded, ch charged) error {
	if !ch.writer {
		return nil
	}
	return refundWriterPasswordAttempt(ctx, s.Pool, g.UserID, g.StepUp.Proof.WriterID, ch.at)
}

func (s *StepUp) fail(ctx context.Context, g Guarded, f failure) error {
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("auth: step-up: record the failure: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	burn := true
	if f != nil {
		if burn, err = f(ctx, tx); err != nil {
			return err
		}
	}
	if burn {
		if _, err := tx.Exec(ctx,
			`UPDATE step_up_challenges SET used_at = $2
			  WHERE nonce = $1 AND user_id = $3 AND session_hash = $4 AND used_at IS NULL`,
			g.StepUp.Nonce, s.now(), g.UserID, g.SessionHash); err != nil {
			return fmt.Errorf("auth: step-up: burn: %w", err)
		}
	}
	return tx.Commit(ctx)
}

type challenge struct {
	user         uuid.UUID
	session, ph  []byte
	action, kind string
	codeID       *uuid.UUID
	expires      time.Time
	used         *time.Time
}

func readChallenge(ctx context.Context, q querier, nonce []byte, forUpdate bool) (challenge, error) {
	sql := `SELECT user_id, session_hash, action, params_hash, proof_kind, code_id, expires_at, used_at
	          FROM step_up_challenges WHERE nonce = $1`
	if forUpdate {
		sql += ` FOR UPDATE`
	}
	var ch challenge
	err := q.QueryRow(ctx, sql, nonce).
		Scan(&ch.user, &ch.session, &ch.action, &ch.ph, &ch.kind, &ch.codeID, &ch.expires, &ch.used)
	if errors.Is(err, pgx.ErrNoRows) {
		return challenge{}, fmt.Errorf("%w: unknown nonce", ErrStepUpFailed)
	}
	if err != nil {
		return challenge{}, fmt.Errorf("auth: step-up: read: %w", err)
	}
	return ch, nil
}

func (s *StepUp) checkChallenge(ch challenge, g Guarded) error {
	switch {
	case ch.user != g.UserID:
		return fmt.Errorf("%w: another account's nonce", ErrStepUpFailed)
	case subtle.ConstantTimeCompare(ch.session, g.SessionHash) != 1:
		return fmt.Errorf("%w: another session's nonce", ErrStepUpFailed)
	case ch.action != string(g.Action):
		return fmt.Errorf("%w: issued for %s, used for %s", ErrStepUpFailed, ch.action, g.Action)
	case subtle.ConstantTimeCompare(ch.ph, g.ParamsHash[:]) != 1:
		return fmt.Errorf("%w: params differ from the ones begun", ErrStepUpFailed)
	case ch.kind != g.StepUp.Proof.Kind:
		return fmt.Errorf("%w: the proof kind is not the one begun (%s)", ErrStepUpFailed, ch.kind)
	case ch.used != nil:
		return fmt.Errorf("%w: nonce already used", ErrStepUpFailed)
	case !ch.expires.After(s.now()):
		return fmt.Errorf("%w: nonce expired", ErrStepUpFailed)
	}
	return nil
}

func (s *StepUp) verify(ctx context.Context, tx pgx.Tx, g Guarded, charge charged) (Proven, failure, error) {
	ch, err := readChallenge(ctx, tx, g.StepUp.Nonce, true)
	if err != nil {
		return Proven{}, nil, err
	}
	if err := s.checkChallenge(ch, g); err != nil {
		return Proven{}, nil, err
	}
	kind, codeID := ch.kind, ch.codeID
	c, err := keyproto.StepUpChallenge(g.StepUp.Nonce, g.Action, g.ParamsHash)
	if err != nil {
		return Proven{}, nil, fmt.Errorf("%w: %v", ErrStepUpFailed, err)
	}
	p := Proven{Kind: keyproto.ProofKind(kind), Nonce: g.StepUp.Nonce}
	switch keyproto.ProofKind(kind) {
	case keyproto.ProofPasskey:
		if s.Passkeys == nil {
			return Proven{}, nil, fmt.Errorf("%w: no relying party is configured", ErrStepUpFailed)
		}
		cred, err := s.Passkeys.VerifyAssertionCredentialTx(ctx, tx, g.UserID, c[:], g.StepUp.Proof.Assertion)
		if err != nil {
			if errors.Is(err, ErrPasskeyRejected) {
				return Proven{}, nil, fmt.Errorf("%w: %v", ErrStepUpFailed, err)
			}
			return Proven{}, nil, err
		}
		p.CredentialID = cred
		return p, nil, nil
	case keyproto.ProofDevice, keyproto.ProofDeviceCode:
		w := g.StepUp.Proof.WriterID
		if err := s.verifyDAK(ctx, tx, g, c, w); err != nil {
			return Proven{}, nil, err
		}
		p.WriterID = w
		if keyproto.ProofKind(kind) == keyproto.ProofDevice {
			return s.verifyDevicePassword(ctx, tx, g, p, charge)
		}
		if codeID == nil {
			return Proven{}, nil, fmt.Errorf("%w: no code was issued", ErrStepUpFailed)
		}
		return s.verifyDeviceCode(ctx, tx, g, p, *codeID, charge)
	}
	return Proven{}, nil, fmt.Errorf("%w: proof kind %q", ErrStepUpFailed, kind)
}

func (s *StepUp) verifyDAK(ctx context.Context, q querier, g Guarded, c [32]byte, w string) error {
	if w == "" || w != g.BoundWriter {
		return fmt.Errorf("%w: the proof's writer is not the session's", ErrStepUpFailed)
	}
	var (
		dak  []byte
		live bool
	)
	err := q.QueryRow(ctx, `SELECT dak_pubkey, revoked_at IS NULL FROM writers WHERE user_id = $1 AND writer_id = $2`,
		g.UserID, w).Scan(&dak, &live)
	if err != nil || !live {
		return fmt.Errorf("%w: the session's writer is gone or revoked", ErrStepUpFailed)
	}
	msg, err := keyproto.DeviceStepUpMessage(c, w)
	if err != nil || !keyproto.VerifyDAKBytes(dak, msg, g.StepUp.Proof.Sig) {
		return fmt.Errorf("%w: the DAK signature does not verify", ErrStepUpFailed)
	}
	return nil
}

func (s *StepUp) verifyDevicePassword(ctx context.Context, tx pgx.Tx, g Guarded, p Proven, charge charged) (Proven, failure, error) {
	st, err := readAccount(ctx, tx, g.UserID, false)
	if err != nil {
		return Proven{}, nil, err
	}
	if !st.hasPassword() {
		return Proven{}, nil, fmt.Errorf("%w: the account has no password", ErrStepUpFailed)
	}
	if s.Keys == nil {
		return Proven{}, nil, errors.New("auth: StepUp.Keys is nil")
	}
	if !charge.writer {
		return Proven{}, nil, fmt.Errorf("%w: the attempt was not counted", ErrStepUpFailed)
	}
	now := charge.at
	ok, err := passwordMatches(ctx, s.Keys, s.Gate, st, g.StepUp.Proof.Verifier, true)
	if err != nil {
		return Proven{}, nil, err
	}
	if !ok {
		return Proven{}, func(ctx context.Context, tx pgx.Tx) (bool, error) {
			return true, recordPasswordFailure(ctx, tx, g.UserID, now)
		}, fmt.Errorf("%w: wrong password", ErrStepUpFailed)
	}
	if err := refundWriterPasswordAttempt(ctx, tx, g.UserID, p.WriterID, now); err != nil {
		return Proven{}, nil, err
	}
	if st.Failures != 0 || st.PausedUntil != nil {
		if _, err := tx.Exec(ctx, `UPDATE users SET password_failures = 0, password_paused_until = NULL WHERE id = $1`,
			g.UserID); err != nil {
			return Proven{}, nil, err
		}
	}
	return p, nil, nil
}

func (s *StepUp) verifyDeviceCode(ctx context.Context, tx pgx.Tx, g Guarded, p Proven, codeID uuid.UUID, charge charged) (Proven, failure, error) {
	if !charge.code {
		return Proven{}, nil, fmt.Errorf("%w: the check was not counted", ErrStepUpFailed)
	}
	now := charge.at
	fail, err := verifyCodeTx(ctx, tx, s.Keys, now, codeCheck{CodeID: codeID, Purpose: PurposePasswordReset,
		CeremonyKind: CeremonyStepUp, CeremonyID: hex.EncodeToString(g.StepUp.Nonce), Submitted: g.StepUp.Proof.Code})
	if err == nil {
		return p, nil, nil
	}
	if fail == nil {
		return Proven{}, nil, fmt.Errorf("%w: %v", ErrStepUpFailed, err)
	}
	return Proven{}, func(ctx context.Context, tx pgx.Tx) (bool, error) {
		return fail.apply(ctx, tx, now)
	}, fmt.Errorf("%w: wrong code", ErrStepUpFailed)
}

func (s *StepUp) ReapStepUps(ctx context.Context) (int64, error) {
	tag, err := s.Pool.Exec(ctx, `DELETE FROM step_up_challenges WHERE expires_at < $1`, s.now().Add(-time.Hour))
	if err != nil {
		return 0, err
	}
	return tag.RowsAffected(), nil
}
