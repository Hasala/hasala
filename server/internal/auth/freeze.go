package auth

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/pgtx"
	"github.com/salehtl/hasala/server/internal/purgeledger"
	"github.com/salehtl/hasala/server/internal/pushv2"
)

const DeviceFreezeTTL = 5 * time.Minute

const deviceFreezeBackdate = 7 * 24 * time.Hour

var stepUpSignOutKinds = []string{
	EventSessionsRevoked,
	EventAccountFrozen,
	EventAccountUnfrozen,
	EventPasswordSet,
	EventPasswordChanged,
	EventPasswordRemoved,
	EventPasswordReset,
	EventPasskeyRemoved,
}

const (
	FrozenByHolder   = "holder"
	FrozenByOperator = "operator"
)

func freezeTx(ctx context.Context, tx pgx.Tx, m *Mailer, userID uuid.UUID, by string, trigger, now time.Time, keep [][]byte, writer string) ([]pushv2.Target, error) {
	if _, err := readAccount(ctx, tx, userID, true); err != nil {
		return nil, err
	}
	var q string
	if by == FrozenByOperator {
		q = `UPDATE users SET frozen_at = coalesce(frozen_at, $2),
		        freeze_trigger_at = least(coalesce(freeze_trigger_at, $3), $3),
		        holder_also_froze = holder_also_froze OR coalesce(frozen_by = 'holder', false),
		        frozen_by = 'operator'
		      WHERE id = $1`
	} else {
		q = `UPDATE users SET frozen_at = coalesce(frozen_at, $2),
		        freeze_trigger_at = least(coalesce(freeze_trigger_at, $3), $3),
		        holder_also_froze = holder_also_froze OR coalesce(frozen_by = 'operator', false),
		        frozen_by = CASE WHEN frozen_by = 'operator' THEN 'operator' ELSE 'holder' END
		      WHERE id = $1`
	}
	if trigger.After(now) {
		trigger = now
	}
	tag, err := tx.Exec(ctx, q, userID, now, trigger)
	if err != nil {
		return nil, fmt.Errorf("auth: freeze: %w", err)
	}
	if tag.RowsAffected() != 1 {
		return nil, ErrNoSuchAccount
	}
	revoked, err := RevokeOtherSessionsTx(ctx, tx, userID, keep, now)
	if err != nil {
		return nil, err
	}
	return revoked, recordEventTx(ctx, tx, m, userID, AuthEvent{Kind: EventAccountFrozen, WriterID: writer}, now)
}

func WellFormedFreezeToken(token string) bool {
	raw, err := base64.RawURLEncoding.DecodeString(token)
	return err == nil && len(raw) == 32 && len(token) == 43
}

func (a *Accounts) FreezeTokenLive(ctx context.Context, token string) (bool, error) {
	raw, err := base64.RawURLEncoding.DecodeString(token)
	if err != nil || !WellFormedFreezeToken(token) {
		return false, nil
	}
	h := sha256.Sum256(raw)
	var live bool
	err = a.Pool.QueryRow(ctx,
		`SELECT EXISTS (SELECT 1 FROM freeze_tokens t WHERE t.token_hash = $1 AND t.used_at IS NULL AND t.expires_at > $2
		    AND NOT EXISTS (SELECT 1 FROM auth_events e WHERE e.user_id = t.user_id AND e.kind = $3 AND e.at > t.trigger_at))`,
		h[:], a.now(), EventAccountUnfrozen).Scan(&live)
	return live, err
}

func (a *Accounts) FreezeByLink(ctx context.Context, token string) (Wake, error) {
	if !WellFormedFreezeToken(token) {
		return Wake{}, nil
	}
	raw, _ := base64.RawURLEncoding.DecodeString(token)
	h := sha256.Sum256(raw)
	now := a.now()
	tx, err := pgtx.BeginReadCommitted(ctx, a.Pool)
	if err != nil {
		return Wake{}, err
	}
	defer pgtx.Rollback(ctx, tx)
	var (
		userID  uuid.UUID
		trigger time.Time
	)
	err = tx.QueryRow(ctx,
		`UPDATE freeze_tokens SET used_at = $2 WHERE token_hash = $1 AND used_at IS NULL AND expires_at > $2
		 RETURNING user_id, trigger_at`, h[:], now).Scan(&userID, &trigger)
	if errors.Is(err, pgx.ErrNoRows) {
		return Wake{}, nil
	}
	if err != nil {
		return Wake{}, err
	}
	var lifted bool
	if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM auth_events WHERE user_id = $1 AND kind = $2 AND at > $3)`,
		userID, EventAccountUnfrozen, trigger).Scan(&lifted); err != nil {
		return Wake{}, err
	}
	if lifted {
		return Wake{}, tx.Commit(ctx)
	}
	revoked, err := freezeTx(ctx, tx, a.Mail, userID, FrozenByHolder, trigger, now, nil, "")
	if err != nil {
		return Wake{}, err
	}
	held, err := a.Hold.Tx(ctx, tx, freezeEntry(userID, trigger, now))
	if err != nil {
		return Wake{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return Wake{}, err
	}
	held.Release(a.Record)
	a.Mail.Kick()
	return wakeFor(userID, "", revoked), nil
}

func (a *Accounts) FreezeNow(ctx context.Context, session SessionInfo, su *StepUpObject) (Wake, error) {
	g, err := guardFor(session, keyproto.ActionAccountFreeze, su)
	if err != nil {
		return Wake{}, err
	}
	var (
		revoked []pushv2.Target
		held    purgeledger.Held
	)
	err = a.StepUp.Run(ctx, g, func(ctx context.Context, tx pgx.Tx, _ Proven) error {
		st, err := readAccount(ctx, tx, session.UserID, true)
		if err != nil {
			return err
		}
		if st.frozen() {
			return ErrAccountFrozen
		}
		now := a.now()
		if held, err = a.Hold.Tx(ctx, tx, freezeEntry(session.UserID, now, now)); err != nil {
			return err
		}
		if revoked, err = freezeTx(ctx, tx, a.Mail, session.UserID, FrozenByHolder, now, now, [][]byte{session.Hash}, session.WriterID); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx,
			`UPDATE sessions SET revoked_at = $2, revoked_reason = 'others' WHERE token_hash = $1 AND revoked_at IS NULL`,
			session.Hash, now); err != nil {
			return fmt.Errorf("auth: freeze: revoke this session: %w", err)
		}
		return forgetPushTokens(ctx, tx, `session_hash = $1`, session.Hash)
	})
	if err != nil {
		return Wake{}, err
	}
	held.Release(a.Record)
	a.Mail.Kick()
	return wakeFor(session.UserID, session.WriterID, revoked), nil
}

func (a *Accounts) Unfreeze(ctx context.Context, session SessionInfo, su *StepUpObject) (Wake, error) {
	st, err := readAccount(ctx, a.Pool, session.UserID, false)
	if err != nil {
		return Wake{}, err
	}
	if !st.frozen() {
		return Wake{}, fmt.Errorf("%w: the account is not frozen", ErrBadRequest)
	}
	if st.operatorFrozen() {
		return Wake{}, fmt.Errorf("%w: only the operator lifts an operator freeze", ErrAccountFrozen)
	}
	if su == nil {
		return Wake{}, ErrStepUpRequired
	}
	g, err := guardFor(session, keyproto.ActionAccountUnfreeze, su)
	if err != nil {
		return Wake{}, err
	}
	var (
		revoked []pushv2.Target
		held    purgeledger.Held
	)
	err = a.StepUp.Run(ctx, g, func(ctx context.Context, tx pgx.Tx, p Proven) error {
		st, err := readAccount(ctx, tx, session.UserID, true)
		if err != nil {
			return err
		}
		if !st.frozen() {
			return fmt.Errorf("%w: the account is not frozen", ErrBadRequest)
		}
		if st.operatorFrozen() {
			return fmt.Errorf("%w: only the operator lifts an operator freeze", ErrAccountFrozen)
		}
		trigger := *st.FreezeTriggerAt
		switch p.Kind {
		case keyproto.ProofPasskey:
			if ok, err := passkeyPredatesFreeze(ctx, tx, p.CredentialID, trigger); err != nil || !ok {
				return fmt.Errorf("%w: the passkey is not older than the freeze", ErrStepUpFailed)
			}
		case keyproto.ProofDevice:
			if ok, err := devicePredatesFreeze(ctx, tx, st, p.WriterID); err != nil || !ok {
				return fmt.Errorf("%w: the device or the password is not older than the freeze", ErrStepUpFailed)
			}
		default:
			return fmt.Errorf("%w: proof kind %s", ErrStepUpFailed, p.Kind)
		}
		now := a.now()
		if held, err = a.Hold.Tx(ctx, tx, UnfreezeEntry(session.UserID, now)); err != nil {
			return err
		}
		if err := clearFreezeTx(ctx, tx, session.UserID, now); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `UPDATE sessions SET restricted = false WHERE token_hash = $1`, session.Hash); err != nil {
			return err
		}
		if revoked, err = RevokeOtherSessionsTx(ctx, tx, session.UserID, [][]byte{session.Hash}, now); err != nil {
			return err
		}
		return recordEventTx(ctx, tx, a.Mail, session.UserID, AuthEvent{Kind: EventAccountUnfrozen,
			WriterID: session.WriterID, CredentialID: p.CredentialID}, now)
	})
	if err != nil {
		return Wake{}, err
	}
	held.Release(a.Record)
	a.Mail.Kick()
	return wakeFor(session.UserID, session.WriterID, revoked), nil
}

func passkeyPredatesFreeze(ctx context.Context, q querier, credentialID []byte, trigger time.Time) (bool, error) {
	var created time.Time
	err := q.QueryRow(ctx, `SELECT created_at FROM webauthn_credentials WHERE credential_id = $1`, credentialID).Scan(&created)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("auth: read the passkey's age: %w", err)
	}
	return created.Before(trigger), nil
}

func devicePredatesFreeze(ctx context.Context, q querier, st accountState, writerID string) (bool, error) {
	if writerID == "" || !st.hasPassword() || st.PasswordSetAt == nil || !st.PasswordSetAt.Before(*st.FreezeTriggerAt) {
		return false, nil
	}
	var (
		registered time.Time
		live       bool
	)
	err := q.QueryRow(ctx, `SELECT registered_at, revoked_at IS NULL FROM writers WHERE user_id = $1 AND writer_id = $2`,
		st.ID, writerID).Scan(&registered, &live)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("auth: read the device's age: %w", err)
	}
	return live && registered.Before(*st.FreezeTriggerAt), nil
}

func HolderCanLift(ctx context.Context, pool *pgxpool.Pool, userID uuid.UUID, writerID string) (bool, error) {
	st, err := readAccount(ctx, pool, userID, false)
	if err != nil {
		return false, err
	}
	if !st.frozen() || st.operatorFrozen() || st.FreezeTriggerAt == nil {
		return false, nil
	}
	var older bool
	if err := pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM webauthn_credentials WHERE user_id = $1 AND created_at < $2)`,
		userID, *st.FreezeTriggerAt).Scan(&older); err != nil {
		return false, fmt.Errorf("auth: read the passkeys' age: %w", err)
	}
	if older {
		return true, nil
	}
	return devicePredatesFreeze(ctx, pool, st, writerID)
}

func (a *Accounts) DeviceFreezeChallenge(ctx context.Context, writerID string) ([]byte, time.Time, error) {
	if !keyproto.ValidWriterID(writerID) {
		return nil, time.Time{}, ErrBadWriterID
	}
	nonce, err := randBytes(keyproto.NonceSize)
	if err != nil {
		return nil, time.Time{}, err
	}
	now := a.now()
	exp := now.Add(DeviceFreezeTTL)
	if _, err := a.Pool.Exec(ctx,
		`INSERT INTO device_freeze_challenges (nonce, writer_id, issued_at, expires_at) VALUES ($1, $2, $3, $4)`,
		nonce, writerID, now, exp); err != nil {
		return nil, time.Time{}, fmt.Errorf("auth: device freeze challenge: %w", err)
	}
	return nonce, exp, nil
}

func (a *Accounts) DeviceFreeze(ctx context.Context, writerID string, nonce, sig []byte, admit func(uuid.UUID) bool) (Wake, error) {
	if !keyproto.ValidWriterID(writerID) || len(nonce) != keyproto.NonceSize {
		return Wake{}, fmt.Errorf("%w: malformed", ErrFreezeRefused)
	}
	now := a.now()
	tag, err := a.Pool.Exec(ctx,
		`UPDATE device_freeze_challenges SET used_at = $3
		  WHERE nonce = $1 AND writer_id = $2 AND used_at IS NULL AND expires_at > $3`, nonce, writerID, now)
	if err != nil {
		return Wake{}, err
	}
	if tag.RowsAffected() != 1 {
		return Wake{}, fmt.Errorf("%w: unknown, used, expired or another writer's nonce", ErrFreezeRefused)
	}
	rows, err := a.Pool.Query(ctx, `SELECT user_id, dak_pubkey FROM writers WHERE writer_id = $1 AND revoked_at IS NULL`, writerID)
	if err != nil {
		return Wake{}, err
	}
	type cand struct {
		user uuid.UUID
		dak  []byte
	}
	var signed []cand
	for rows.Next() {
		var c cand
		if err := rows.Scan(&c.user, &c.dak); err != nil {
			rows.Close()
			return Wake{}, err
		}
		msg, err := keyproto.DeviceFreezeMessage(nonce, c.user, writerID)
		if err == nil && keyproto.VerifyDAKBytes(c.dak, msg, sig) {
			signed = append(signed, c)
		}
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return Wake{}, err
	}
	if len(signed) != 1 {
		return Wake{}, fmt.Errorf("%w: no single live writer signed it", ErrFreezeRefused)
	}
	c := signed[0]
	if admit != nil && !admit(c.user) {
		return Wake{}, fmt.Errorf("%w: device freezes for this writer", ErrRateLimited)
	}
	tx, err := pgtx.BeginReadCommitted(ctx, a.Pool)
	if err != nil {
		return Wake{}, err
	}
	defer pgtx.Rollback(ctx, tx)
	if err := lockUser(ctx, tx, c.user); err != nil {
		return Wake{}, fmt.Errorf("%w: %v", ErrFreezeRefused, err)
	}
	trigger := now
	var signedOut *time.Time
	if err := tx.QueryRow(ctx,
		`SELECT max(s.revoked_at) FROM sessions s
		  WHERE s.user_id = $1 AND s.writer_id = $2 AND s.revoked_reason = 'others'
		    AND NOT EXISTS (SELECT 1 FROM auth_events e
		                     WHERE e.user_id = s.user_id AND e.writer_id = s.writer_id AND e.at = s.revoked_at
		                       AND e.kind = ANY($3::text[]))`,
		c.user, writerID, stepUpSignOutKinds).Scan(&signedOut); err != nil {
		return Wake{}, err
	}
	if signedOut != nil && signedOut.After(now.Add(-deviceFreezeBackdate)) {
		trigger = *signedOut
	}
	revoked, err := freezeTx(ctx, tx, a.Mail, c.user, FrozenByHolder, trigger, now, nil, writerID)
	if err != nil {
		return Wake{}, err
	}
	held, err := a.Hold.Tx(ctx, tx, freezeEntry(c.user, trigger, now))
	if err != nil {
		return Wake{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return Wake{}, err
	}
	held.Release(a.Record)
	a.Mail.Kick()
	return wakeFor(c.user, writerID, revoked), nil
}

func OperatorFreeze(ctx context.Context, tx pgx.Tx, userID uuid.UUID, now time.Time, m *Mailer) error {
	if err := lockUser(ctx, tx, userID); err != nil {
		return err
	}
	_, err := freezeTx(ctx, tx, m, userID, FrozenByOperator, now, now, nil, "")
	return err
}

func clearFreezeTx(ctx context.Context, tx pgx.Tx, userID uuid.UUID, now time.Time) error {
	if _, err := tx.Exec(ctx,
		`UPDATE users SET frozen_at = NULL, freeze_trigger_at = NULL, frozen_by = NULL, holder_also_froze = false WHERE id = $1`,
		userID); err != nil {
		return err
	}
	_, err := tx.Exec(ctx, `UPDATE freeze_tokens SET used_at = $2 WHERE user_id = $1 AND used_at IS NULL`, userID, now)
	return err
}

type UnfreezeScope int

const (
	ScopeOperatorOnly UnfreezeScope = iota
	ScopeAny
)

var ErrHolderFreeze = errors.New("auth: the holder froze this account; the console does not lift it")

func OperatorUnfreeze(ctx context.Context, tx pgx.Tx, userID uuid.UUID, scope UnfreezeScope, now time.Time, m *Mailer) (bool, error) {
	st, err := readAccount(ctx, tx, userID, true)
	if err != nil {
		return false, err
	}
	if !st.frozen() {
		return true, nil
	}
	var holderToo bool
	if err := tx.QueryRow(ctx, `SELECT holder_also_froze FROM users WHERE id = $1`, userID).Scan(&holderToo); err != nil {
		return false, err
	}
	if scope == ScopeOperatorOnly {
		if !st.operatorFrozen() {
			return false, ErrHolderFreeze
		}
		if holderToo {
			_, err := tx.Exec(ctx, `UPDATE users SET frozen_by = 'holder', holder_also_froze = false WHERE id = $1`, userID)
			return false, err
		}
	}
	if err := clearFreezeTx(ctx, tx, userID, now); err != nil {
		return false, err
	}
	if _, err := RevokeOtherSessionsTx(ctx, tx, userID, nil, now); err != nil {
		return false, err
	}
	return true, recordEventTx(ctx, tx, m, userID, AuthEvent{Kind: EventAccountUnfrozen}, now)
}
