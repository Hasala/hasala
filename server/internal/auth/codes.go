package auth

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"errors"
	"fmt"
	"math/big"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/authkeys"
	"github.com/salehtl/hasala/server/internal/pgtx"
)

const (
	CodeTTL             = 10 * time.Minute
	codeMaxAttempts     = 5
	codeSendsPerHour    = 5
	codePause           = 15 * time.Minute
	codeVerifyWindow    = 15 * time.Minute
	codeVerifiesPerSpan = 20
	codeSendDeadline    = 30 * time.Second
	codeSendWindow      = 4 * codeSendDeadline
)

const (
	PurposeSignup         = "signup"
	PurposeEmailVerify    = "email_verify"
	PurposeEmailChangeOld = "email_change_old"
	PurposeEmailChangeNew = "email_change_new"
	PurposePasswordReset  = "password_reset"
	PurposeRecovery       = "recovery"

	CeremonySignup        = "signup"
	CeremonyStepUp        = "step_up"
	CeremonyEmailChange   = "email_change"
	CeremonyEmailVerify   = "email_verify"
	CeremonyPasswordReset = "password_reset"
	CeremonyRecovery      = "recovery"
)

var (
	ErrCodeRejected = errors.New("auth: the code did not verify")
	ErrRateLimited  = errors.New("auth: rate limited")
)

type IssuedCode struct {
	ID      uuid.UUID
	Purpose string
	To      string
	Tag     []byte
	UserID  *uuid.UUID
	Code    string
	Send    bool
	Notice  bool
	Name    string
}

func newCode() (string, error) {
	n, err := rand.Int(rand.Reader, big.NewInt(1_000_000))
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%06d", n.Int64()), nil
}

func issueCodeTx(ctx context.Context, tx pgx.Tx, keys *authkeys.Keys, now time.Time, purpose, emailNorm string,
	userID *uuid.UUID, ceremonyKind, ceremonyID string, send bool) (IssuedCode, error) {
	return insertCodeTx(ctx, tx, keys, now, purpose, emailNorm, userID, ceremonyKind, ceremonyID, send,
		purpose != PurposePasswordReset)
}

func insertCodeTx(ctx context.Context, tx pgx.Tx, keys *authkeys.Keys, now time.Time, purpose, emailNorm string,
	userID *uuid.UUID, ceremonyKind, ceremonyID string, send, waitsForSend bool) (IssuedCode, error) {
	tag := keys.EmailTag(emailNorm)
	if ceremonyKind != CeremonyStepUp {
		var paused bool
		if err := tx.QueryRow(ctx,
			`SELECT EXISTS (SELECT 1 FROM email_code_pauses WHERE purpose = $1 AND email_tag = $2 AND paused_until > $3)
			     OR EXISTS (SELECT 1 FROM email_codes WHERE purpose = $1 AND email_tag = $2 AND ceremony_kind <> 'step_up'
			                   AND used_at IS NULL AND out_of_attempts_at > $4)`,
			purpose, tag, now, now.Add(-codePause)).Scan(&paused); err != nil {
			return IssuedCode{}, fmt.Errorf("auth: code pause: %w", err)
		}
		var sends int
		if err := tx.QueryRow(ctx,
			`SELECT count(*) FROM email_codes WHERE purpose = $1 AND email_tag = $2
			    AND ceremony_kind <> 'step_up' AND created_at > $3
			    AND (awaiting_send_until IS NULL OR awaiting_send_until > $4)`,
			purpose, tag, now.Add(-time.Hour), now).Scan(&sends); err != nil {
			return IssuedCode{}, fmt.Errorf("auth: code sends: %w", err)
		}
		if paused || sends >= codeSendsPerHour {
			return IssuedCode{}, fmt.Errorf("%w: codes for this address", ErrRateLimited)
		}
	}
	code, err := newCode()
	if err != nil {
		return IssuedCode{}, err
	}
	id := uuid.New()
	m, err := keys.CodeMAC(purpose, id, tag, code)
	if err != nil {
		return IssuedCode{}, err
	}
	var awaitingSend *time.Time
	if waitsForSend {
		until := now.Add(codeSendWindow)
		awaitingSend = &until
	}
	if _, err := tx.Exec(ctx,
		`INSERT INTO email_codes (code_id, purpose, email_tag, user_id, ceremony_kind, ceremony_id, code_mac, sent,
		   created_at, expires_at, awaiting_send_until)
		 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)`,
		id, purpose, tag, userID, ceremonyKind, ceremonyID, m, send, now, now.Add(CodeTTL), awaitingSend); err != nil {
		return IssuedCode{}, fmt.Errorf("auth: insert code: %w", err)
	}
	return IssuedCode{ID: id, Purpose: purpose, To: emailNorm, Tag: tag, UserID: userID, Code: code, Send: send}, nil
}

type codeCheck struct {
	CodeID       uuid.UUID
	Purpose      string
	CeremonyKind string
	CeremonyID   string
	Submitted    string
}

type codeFailure struct {
	codeID       uuid.UUID
	purpose      string
	ceremonyKind string
	tag          []byte
}

func (f *codeFailure) apply(ctx context.Context, q queryExecer, now time.Time) (bool, error) {
	var attempts int
	if err := q.QueryRow(ctx,
		`UPDATE email_codes SET burned_at = $2
		  WHERE code_id = $1 AND used_at IS NULL AND burned_at IS NULL AND attempts >= $3 RETURNING attempts`,
		f.codeID, now, codeMaxAttempts).Scan(&attempts); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return false, nil
		}
		return false, fmt.Errorf("auth: burn a code: %w", err)
	}
	if f.ceremonyKind != CeremonyStepUp {
		if _, err := q.Exec(ctx,
			`INSERT INTO email_code_pauses (purpose, email_tag, paused_until) VALUES ($1, $2, $3)
			 ON CONFLICT (purpose, email_tag) DO UPDATE SET paused_until = greatest(email_code_pauses.paused_until, $3)`,
			f.purpose, f.tag, now.Add(codePause)); err != nil {
			return true, fmt.Errorf("auth: pause codes: %w", err)
		}
	}
	return true, nil
}

func limitCodeVerify(ctx context.Context, pool *pgxpool.Pool, now time.Time, codeID uuid.UUID) error {
	tx, err := pgtx.BeginReadCommitted(ctx, pool)
	if err != nil {
		return err
	}
	defer pgtx.Rollback(ctx, tx)
	var (
		purpose, kind string
		tag           []byte
	)
	err = tx.QueryRow(ctx,
		`UPDATE email_codes SET attempts = attempts + 1,
		        out_of_attempts_at = CASE WHEN attempts + 1 >= $2 AND expires_at > $3 THEN $3::timestamptz END
		  WHERE code_id = $1 AND used_at IS NULL AND burned_at IS NULL AND attempts < $2
		 RETURNING purpose, ceremony_kind, email_tag`,
		codeID, codeMaxAttempts, now).Scan(&purpose, &kind, &tag)
	if errors.Is(err, pgx.ErrNoRows) {
		return fmt.Errorf("%w: no attempts left", ErrCodeRejected)
	}
	if err != nil {
		return fmt.Errorf("auth: count a code attempt: %w", err)
	}
	n, err := bumpCounter(ctx, tx, "code-verify-email", codeVerifyKey(purpose, kind, tag), codeVerifyWindow, now)
	if err != nil {
		return err
	}
	if n > codeVerifiesPerSpan {
		return fmt.Errorf("%w: code checks for this address", ErrRateLimited)
	}
	return tx.Commit(ctx)
}

func codeVerifyKey(purpose, kind string, tag []byte) []byte {
	sum := sha256.Sum256(append([]byte(purpose+"\x00"+kind+"\x00"), tag...))
	return sum[:]
}

func verifyCodeTx(ctx context.Context, tx pgx.Tx, keys *authkeys.Keys, now time.Time, c codeCheck) (*codeFailure, error) {
	var (
		purpose, kind, cid string
		tag, stored        []byte
		sent               bool
		expires            time.Time
		used, burned       *time.Time
	)
	err := tx.QueryRow(ctx,
		`SELECT purpose, ceremony_kind, ceremony_id, email_tag, code_mac, sent, expires_at, used_at, burned_at
		   FROM email_codes WHERE code_id = $1 FOR UPDATE`, c.CodeID).
		Scan(&purpose, &kind, &cid, &tag, &stored, &sent, &expires, &used, &burned)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, fmt.Errorf("%w: no such code", ErrCodeRejected)
	}
	if err != nil {
		return nil, fmt.Errorf("auth: read code: %w", err)
	}
	switch {
	case purpose != c.Purpose || kind != c.CeremonyKind || cid != c.CeremonyID:
		return nil, fmt.Errorf("%w: another purpose or ceremony", ErrCodeRejected)
	case used != nil || burned != nil:
		return nil, fmt.Errorf("%w: used or burned", ErrCodeRejected)
	case !expires.After(now):
		return nil, fmt.Errorf("%w: expired", ErrCodeRejected)
	}
	if !sent || !sixDigits(c.Submitted) || !keys.CodeMatches(stored, purpose, c.CodeID, tag, c.Submitted) {
		return &codeFailure{codeID: c.CodeID, purpose: purpose, ceremonyKind: kind, tag: tag},
			fmt.Errorf("%w: wrong code", ErrCodeRejected)
	}
	if _, err := tx.Exec(ctx, `UPDATE email_codes SET used_at = $2 WHERE code_id = $1`, c.CodeID, now); err != nil {
		return nil, fmt.Errorf("auth: spend code: %w", err)
	}
	return nil, nil
}

func sixDigits(s string) bool {
	if len(s) != 6 {
		return false
	}
	for i := 0; i < 6; i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

func bumpCounter(ctx context.Context, q queryExecer, scope string, key []byte, window time.Duration, now time.Time) (int, error) {
	start := now.UTC().Truncate(window)
	var n int
	if err := q.QueryRow(ctx,
		`INSERT INTO rate_counters (scope, key, window_start, count) VALUES ($1, $2, $3, 1)
		 ON CONFLICT (scope, key, window_start) DO UPDATE SET count = rate_counters.count + 1 RETURNING count`,
		scope, key, start).Scan(&n); err != nil {
		return 0, fmt.Errorf("auth: rate counter %s: %w", scope, err)
	}
	return n, nil
}
