package auth

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/authkeys"
	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/purgeledger"
)

type Accounts struct {
	Pool     *pgxpool.Pool
	Keys     *authkeys.Keys
	Gate     *authkeys.Gate
	Sessions *Sessions
	Passkeys *Passkeys
	StepUp   *StepUp
	Mail     *Mailer
	Now      func() time.Time
	Record   func(purgeledger.Entry)
	Hold     purgeledger.HoldFunc
}

func (a *Accounts) now() time.Time {
	if a.Now != nil {
		return a.Now()
	}
	return time.Now()
}

var (
	ErrBadRequest        = errors.New("auth: malformed request")
	ErrBadEmail          = errors.New("auth: not an address this beta accepts")
	ErrEmailInUse        = errors.New("auth: the proven address already has an account")
	ErrPasswordRejected  = errors.New("auth: password sign-in failed")
	ErrRecoveryRefused   = errors.New("auth: recovery refused")
	ErrResetRefused      = errors.New("auth: reset refused")
	ErrNotApproved       = errors.New("auth: the reset is not approved yet")
	ErrFreezeRefused     = errors.New("auth: device freeze refused")
	ErrAccountFrozen     = errors.New("auth: the account is frozen")
	ErrAccountSuspended  = errors.New("auth: the account is suspended")
	ErrConflict          = errors.New("auth: the account already has a password")
	ErrLastAuthenticator = errors.New("auth: it is the account's last authenticator")
	ErrUnavailable       = errors.New("auth: try again shortly")
	ErrNoSuchAccount     = errors.New("auth: no such account")
)

func gateErr(err error) error {
	if errors.Is(err, authkeys.ErrGateBusy) {
		return fmt.Errorf("%w: %v", ErrUnavailable, err)
	}
	return err
}

func uniqueViolation(err error) *pgconn.PgError {
	var pg *pgconn.PgError
	if errors.As(err, &pg) && pg.Code == "23505" {
		return pg
	}
	return nil
}

func newCeremonyIDN(n int) (string, error) {
	raw := make([]byte, n)
	if _, err := rand.Read(raw); err != nil {
		return "", fmt.Errorf("auth: mint ceremony id: %w", err)
	}
	return base64.RawURLEncoding.EncodeToString(raw), nil
}

func randBytes(n int) ([]byte, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return nil, fmt.Errorf("auth: read random: %w", err)
	}
	return b, nil
}

type accountState struct {
	ID              uuid.UUID
	EmailNorm       string
	DisplayName     string
	Status          string
	PasswordHash    []byte
	PasswordSalt    []byte
	PasswordVersion *int16
	PasswordSetAt   *time.Time
	Failures        int
	PausedUntil     *time.Time
	FrozenAt        *time.Time
	FreezeTriggerAt *time.Time
	FrozenBy        *string
	HasKeys         bool
	InDoubt         bool
}

func (s accountState) frozen() bool      { return s.FrozenAt != nil }
func (s accountState) active() bool      { return s.Status == "active" }
func (s accountState) hasPassword() bool { return len(s.PasswordHash) > 0 }
func (s accountState) resettable() bool {
	return s.hasPassword() && s.active() && !s.frozen() && !s.InDoubt
}
func (s accountState) operatorFrozen() bool {
	return s.FrozenBy != nil && *s.FrozenBy == FrozenByOperator
}

const accountColumns = `u.id, u.email_norm, u.display_name, u.status, u.password_hash, u.password_salt,
	u.password_version, u.password_set_at, u.password_failures, u.password_paused_until, u.frozen_at,
	u.freeze_trigger_at, u.frozen_by, EXISTS (SELECT 1 FROM account_keys k WHERE k.user_id = u.id),
	u.reverify_requested_at IS NOT NULL`

func scanAccount(row pgx.Row) (accountState, error) {
	var s accountState
	err := row.Scan(&s.ID, &s.EmailNorm, &s.DisplayName, &s.Status, &s.PasswordHash, &s.PasswordSalt,
		&s.PasswordVersion, &s.PasswordSetAt, &s.Failures, &s.PausedUntil, &s.FrozenAt, &s.FreezeTriggerAt,
		&s.FrozenBy, &s.HasKeys, &s.InDoubt)
	return s, err
}

func readAccount(ctx context.Context, q querier, userID uuid.UUID, forUpdate bool) (accountState, error) {
	sql := `SELECT ` + accountColumns + ` FROM users u WHERE u.id = $1`
	if forUpdate {
		sql += ` FOR UPDATE OF u`
	}
	s, err := scanAccount(q.QueryRow(ctx, sql, userID))
	if errors.Is(err, pgx.ErrNoRows) {
		return accountState{}, ErrNoSuchAccount
	}
	if err != nil {
		return accountState{}, fmt.Errorf("auth: read account: %w", err)
	}
	return s, nil
}

func accountByEmail(ctx context.Context, q querier, emailNorm string) (accountState, bool, error) {
	s, err := scanAccount(q.QueryRow(ctx, `SELECT `+accountColumns+` FROM users u WHERE u.email_norm = $1`, emailNorm))
	if errors.Is(err, pgx.ErrNoRows) {
		return accountState{}, false, nil
	}
	if err != nil {
		return accountState{}, false, fmt.Errorf("auth: read account: %w", err)
	}
	return s, true, nil
}

const accountSuspended = "suspended"

type AccountStatus struct {
	Suspended bool
	Frozen    bool
}

func normEmail(x string) (string, error) {
	n, err := keyproto.EmailNorm(x)
	if err != nil {
		return "", ErrBadEmail
	}
	return n, nil
}
