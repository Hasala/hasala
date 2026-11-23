package auth

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"fmt"
	"time"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/authkeys"
)

const (
	passwordEmailWindow   = 15 * time.Minute
	passwordEmailLimit    = 20
	passwordWriterWindow  = time.Hour
	passwordWriterFailMax = 5
	passwordPauseAfter    = 5
	passwordPauseFirst    = time.Minute
	passwordPauseMax      = time.Hour
)

var dummySalt = make([]byte, authkeys.PasswordSaltSize)

func writerCounterKey(userID uuid.UUID, writerID string) []byte {
	h := sha256.New()
	h.Write(userID[:])
	h.Write([]byte(writerID))
	return h.Sum(nil)
}

func newPasswordHash(ctx context.Context, keys *authkeys.Keys, gate *authkeys.Gate, s []byte) (hash, salt []byte, err error) {
	if len(s) != authkeys.VerifierSize {
		return nil, nil, fmt.Errorf("%w: a verifier is %d bytes", ErrBadRequest, authkeys.VerifierSize)
	}
	if salt, err = randBytes(authkeys.PasswordSaltSize); err != nil {
		return nil, nil, err
	}
	hash, err = keys.HashGated(ctx, gate, s, salt, keys.Current())
	if err != nil {
		return nil, nil, gateErr(err)
	}
	return hash, salt, nil
}

func passwordMatches(ctx context.Context, keys *authkeys.Keys, gate *authkeys.Gate, st accountState, s []byte, compare bool) (bool, error) {
	salt, gen := dummySalt, keys.Current()
	if compare && st.hasPassword() {
		salt = st.PasswordSalt
		if st.PasswordVersion != nil {
			gen = int(*st.PasswordVersion)
		}
	}
	if len(s) != authkeys.VerifierSize {
		s = make([]byte, authkeys.VerifierSize)
		compare = false
	}
	h, err := keys.HashGated(ctx, gate, s, salt, gen)
	if err != nil {
		return false, gateErr(err)
	}
	return compare && st.hasPassword() && subtle.ConstantTimeCompare(h, st.PasswordHash) == 1, nil
}

func passwordPause(n int) time.Duration {
	if n < passwordPauseAfter {
		return 0
	}
	d := passwordPauseFirst
	for i := passwordPauseAfter; i < n && d < passwordPauseMax; i++ {
		d *= 2
	}
	if d > passwordPauseMax {
		d = passwordPauseMax
	}
	return d
}

func recordPasswordFailure(ctx context.Context, q queryExecer, userID uuid.UUID, now time.Time) error {
	var n int
	if err := q.QueryRow(ctx,
		`UPDATE users SET password_failures = password_failures + 1 WHERE id = $1 RETURNING password_failures`, userID).Scan(&n); err != nil {
		return fmt.Errorf("auth: count a password failure: %w", err)
	}
	if d := passwordPause(n); d > 0 {
		if _, err := q.Exec(ctx, `UPDATE users SET password_paused_until = $2 WHERE id = $1`, userID, now.Add(d)); err != nil {
			return fmt.Errorf("auth: pause passwords: %w", err)
		}
	}
	return nil
}

func writerPasswordAttempt(ctx context.Context, q queryExecer, userID uuid.UUID, writerID string, now time.Time) error {
	n, err := bumpCounter(ctx, q, "password-writer", writerCounterKey(userID, writerID), passwordWriterWindow, now)
	if err != nil {
		return err
	}
	if n > passwordWriterFailMax {
		return fmt.Errorf("%w: this device's password attempts", ErrRateLimited)
	}
	return nil
}

func refundCounter(ctx context.Context, q queryExecer, scope string, key []byte, window time.Duration, now time.Time) error {
	if _, err := q.Exec(ctx,
		`UPDATE rate_counters SET count = count - 1 WHERE scope = $1 AND key = $2 AND window_start = $3 AND count > 0`,
		scope, key, now.UTC().Truncate(window)); err != nil {
		return fmt.Errorf("auth: rate counter %s: %w", scope, err)
	}
	return nil
}

func refundWriterPasswordAttempt(ctx context.Context, q queryExecer, userID uuid.UUID, writerID string, now time.Time) error {
	return refundCounter(ctx, q, "password-writer", writerCounterKey(userID, writerID), passwordWriterWindow, now)
}

func refundEmailPasswordAttempt(ctx context.Context, q queryExecer, tag []byte, now time.Time) error {
	return refundCounter(ctx, q, "password-email", tag, passwordEmailWindow, now)
}

func clearPasswordTx(ctx context.Context, q queryExecer, userID uuid.UUID) error {
	_, err := q.Exec(ctx,
		`UPDATE users SET password_hash = NULL, password_salt = NULL, password_version = NULL, password_set_at = NULL,
		        password_failures = 0, password_paused_until = NULL WHERE id = $1`, userID)
	return err
}

func setPasswordTx(ctx context.Context, q queryExecer, userID uuid.UUID, hash, salt []byte, generation int, now time.Time) error {
	if _, err := q.Exec(ctx,
		`UPDATE users SET password_hash = $2, password_salt = $3, password_version = $4, password_set_at = $5,
		        password_failures = 0, password_paused_until = NULL
		  WHERE id = $1`, userID, hash, salt, generation, now); err != nil {
		return fmt.Errorf("auth: set password: %w", err)
	}
	if _, err := q.Exec(ctx, `DELETE FROM password_reset_ceremonies WHERE user_id = $1 AND consumed_at IS NULL`, userID); err != nil {
		return fmt.Errorf("auth: set password: end outstanding resets: %w", err)
	}
	return nil
}
