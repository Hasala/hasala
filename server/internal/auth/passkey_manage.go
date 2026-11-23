package auth

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

var ErrLastPasskey = errors.New("auth: refusing to remove the account's last passkey")

type Credential struct {
	ID         []byte
	AAGUID     []byte
	CreatedAt  time.Time
	LastUsedAt *time.Time
}

func (p *Passkeys) ListCredentials(ctx context.Context, userID uuid.UUID) ([]Credential, error) {
	if p == nil || p.Pool == nil {
		return nil, errors.New("auth: Passkeys is not configured")
	}
	if userID == uuid.Nil {
		return nil, errors.New("auth: passkey: ListCredentials: user id is zero")
	}
	rows, err := p.Pool.Query(ctx,
		`SELECT credential_id, aaguid, created_at, last_used_at
		   FROM webauthn_credentials WHERE user_id = $1 ORDER BY created_at, credential_id`,
		userID)
	if err != nil {
		return nil, fmt.Errorf("auth: passkey: list credentials for %s: %w", userID, err)
	}
	defer rows.Close()
	var out []Credential
	for rows.Next() {
		var c Credential
		if err := rows.Scan(&c.ID, &c.AAGUID, &c.CreatedAt, &c.LastUsedAt); err != nil {
			return nil, fmt.Errorf("auth: passkey: list credentials for %s: %w", userID, err)
		}
		out = append(out, c)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("auth: passkey: list credentials for %s: %w", userID, err)
	}
	return out, nil
}

func deleteCredentialTx(ctx context.Context, tx pgx.Tx, userID uuid.UUID, credentialID, keepSessionHash []byte, now time.Time) (int64, error) {
	if userID == uuid.Nil {
		return 0, errors.New("auth: passkey: deleteCredentialTx: user id is zero")
	}
	if len(credentialID) == 0 {
		return 0, ErrCredentialUnknown
	}

	rows, err := tx.Query(ctx,
		`SELECT credential_id FROM webauthn_credentials WHERE user_id = $1 ORDER BY credential_id FOR UPDATE`,
		userID)
	if err != nil {
		return 0, fmt.Errorf("auth: passkey: delete credential: lock credentials: %w", err)
	}
	var (
		total int
		found bool
	)
	for rows.Next() {
		var id []byte
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return 0, fmt.Errorf("auth: passkey: delete credential: %w", err)
		}
		total++
		if bytes.Equal(id, credentialID) {
			found = true
		}
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return 0, fmt.Errorf("auth: passkey: delete credential: %w", err)
	}
	if !found {
		return 0, ErrCredentialUnknown
	}
	var hasPassword bool
	if err := tx.QueryRow(ctx, `SELECT password_hash IS NOT NULL FROM users WHERE id = $1`, userID).Scan(&hasPassword); err != nil {
		return 0, fmt.Errorf("auth: passkey: delete credential: %w", err)
	}
	if total <= 1 && !hasPassword {
		return 0, ErrLastPasskey
	}

	revoked, err := revokeCredentialSessionsTx(ctx, tx, userID, credentialID, keepSessionHash, now)
	if err != nil {
		return 0, err
	}

	tag, err := tx.Exec(ctx,
		`DELETE FROM webauthn_credentials WHERE credential_id = $1 AND user_id = $2`,
		credentialID, userID)
	if err != nil {
		return 0, fmt.Errorf("auth: passkey: delete credential: %w", err)
	}
	if tag.RowsAffected() != 1 {
		return 0, fmt.Errorf("auth: passkey: delete credential: removed %d rows, want 1", tag.RowsAffected())
	}

	return revoked, nil
}

func revokeCredentialSessionsTx(ctx context.Context, tx pgx.Tx, userID uuid.UUID,
	credID, keepHash []byte, now time.Time) (int64, error) {
	doomed := `user_id = $1
	                  AND (credential_id = $2::bytea
	                       OR (credential_id IS NULL AND token_hash IS DISTINCT FROM $3::bytea
	                           AND minted_by IN ('` + MintedRegister + `', '` + MintedLogin + `', '` + MintedRecover + `')))`

	tag, err := tx.Exec(ctx,
		`UPDATE sessions SET revoked_at = $4, revoked_reason = 'others' WHERE revoked_at IS NULL AND `+doomed,
		userID, credID, keepHash, now)
	if err != nil {
		return 0, fmt.Errorf("auth: revoke sessions of credential for %s: %w", userID, err)
	}
	if err := forgetPushTokens(ctx, tx,
		`user_id = $1 AND session_hash IN (SELECT token_hash FROM sessions WHERE `+doomed+`)`,
		userID, credID, keepHash); err != nil {
		return 0, err
	}
	return tag.RowsAffected(), nil
}
