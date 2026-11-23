package auth

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/go-webauthn/webauthn/protocol"
	"github.com/go-webauthn/webauthn/webauthn"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

type ceremonyKind string

const (
	ceremonyRegister ceremonyKind = "register"
	ceremonyLogin    ceremonyKind = "login"
	ceremonyAdd      ceremonyKind = "add"
)

type ceremony struct {
	ID              string
	Kind            ceremonyKind
	UserID          *uuid.UUID
	UserHandle      []byte
	Session         webauthn.SessionData
	SignupID        string
	AuthorityPubkey []byte
	RegisterNonce   []byte
	AddNonce        []byte
	ExpiresAt       time.Time
	sessionJSON     []byte
}

func (p *Passkeys) putCeremony(ctx context.Context, c ceremony) error {
	return p.putCeremonyOn(ctx, p.Pool, c)
}

func (p *Passkeys) putCeremonyOn(ctx context.Context, q execer, c ceremony) error {
	raw, err := json.Marshal(c.Session)
	if err != nil {
		return fmt.Errorf("auth: passkey: marshal session data: %w", err)
	}
	now := p.now()
	var handle, signup, authority, regNonce, addNonce any
	if len(c.UserHandle) > 0 {
		handle = c.UserHandle
	}
	if c.SignupID != "" {
		signup = c.SignupID
	}
	if len(c.AuthorityPubkey) > 0 {
		authority, regNonce = c.AuthorityPubkey, c.RegisterNonce
	}
	if len(c.AddNonce) > 0 {
		addNonce = c.AddNonce
	}
	if _, err := q.Exec(ctx,
		`INSERT INTO webauthn_ceremonies (id, kind, user_id, user_handle, session_data, signup_id,
		   authority_pubkey, register_nonce, add_nonce, created_at, expires_at)
		 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)`,
		c.ID, string(c.Kind), c.UserID, handle, raw, signup, authority, regNonce, addNonce, now, now.Add(CeremonyTTL)); err != nil {
		return fmt.Errorf("auth: passkey: record ceremony: %w", err)
	}
	return nil
}

func (p *Passkeys) claimCeremony(ctx context.Context, id string, kind ceremonyKind) (ceremony, error) {
	if id == "" {
		return ceremony{}, ErrCeremonyUnknown
	}
	var (
		c        ceremony
		signupID *string
	)
	err := p.Pool.QueryRow(ctx,
		`DELETE FROM webauthn_ceremonies WHERE id = $1 AND kind = $2
		 RETURNING id, kind, user_id, user_handle, session_data, signup_id, authority_pubkey, register_nonce,
		           add_nonce, expires_at`,
		id, string(kind)).Scan(&c.ID, &c.Kind, &c.UserID, &c.UserHandle, &c.sessionJSON, &signupID,
		&c.AuthorityPubkey, &c.RegisterNonce, &c.AddNonce, &c.ExpiresAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return ceremony{}, ErrCeremonyUnknown
	}
	if err != nil {
		return ceremony{}, fmt.Errorf("auth: passkey: claim ceremony: %w", err)
	}
	if !c.ExpiresAt.After(p.now()) {
		return ceremony{}, fmt.Errorf("%w: ceremony expired at %s", ErrCeremonyUnknown, c.ExpiresAt.UTC())
	}
	if err := json.Unmarshal(c.sessionJSON, &c.Session); err != nil {
		return ceremony{}, fmt.Errorf("auth: passkey: decode session data: %w", err)
	}
	if signupID != nil {
		c.SignupID = *signupID
	}
	return c, nil
}

func (p *Passkeys) ReapExpiredCeremonies(ctx context.Context) (int64, error) {
	if p.Pool == nil {
		return 0, errors.New("auth: Passkeys.Pool is nil")
	}
	tag, err := p.Pool.Exec(ctx, `DELETE FROM webauthn_ceremonies WHERE expires_at < $1`, p.now())
	if err != nil {
		return 0, fmt.Errorf("auth: passkey: reap ceremonies: %w", err)
	}
	return tag.RowsAffected(), nil
}

type storedCredential struct {
	UserID            uuid.UUID
	UserHandle        []byte
	Credential        webauthn.Credential
	AttestationSHA256 []byte
}

func (p *Passkeys) credentialByID(ctx context.Context, q querier, credentialID []byte) (storedCredential, error) {
	var (
		sc         storedCredential
		signCount  int64
		aaguid     []byte
		transports *string
		be, bs     bool
	)
	err := q.QueryRow(ctx,
		`SELECT user_id, user_handle, public_key, sign_count, aaguid, transports, backup_eligible, backup_state
		   FROM webauthn_credentials WHERE credential_id = $1`, credentialID).
		Scan(&sc.UserID, &sc.UserHandle, &sc.Credential.PublicKey, &signCount, &aaguid, &transports, &be, &bs)
	if errors.Is(err, pgx.ErrNoRows) {
		return storedCredential{}, ErrCredentialUnknown
	}
	if err != nil {
		return storedCredential{}, fmt.Errorf("auth: passkey: load credential: %w", err)
	}
	sc.Credential.ID = credentialID
	sc.Credential.Authenticator = webauthn.Authenticator{
		AAGUID:    aaguid,
		SignCount: uint32(signCount),
	}
	sc.Credential.Flags = webauthn.CredentialFlags{BackupEligible: be, BackupState: bs}
	if transports != nil {
		for _, t := range strings.Split(*transports, ",") {
			if t = strings.TrimSpace(t); t != "" {
				sc.Credential.Transport = append(sc.Credential.Transport, protocol.AuthenticatorTransport(t))
			}
		}
	}
	return sc, nil
}

func (p *Passkeys) credentialsForUser(ctx context.Context, q dbtx, userID uuid.UUID) ([]webauthn.Credential, []byte, error) {
	var handle []byte
	if err := q.QueryRow(ctx, `SELECT user_handle FROM users WHERE id = $1`, userID).Scan(&handle); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, nil, nil
		}
		return nil, nil, fmt.Errorf("auth: passkey: read user handle: %w", err)
	}
	rows, err := q.Query(ctx,
		`SELECT credential_id FROM webauthn_credentials WHERE user_id = $1 ORDER BY created_at, credential_id`, userID)
	if err != nil {
		return nil, nil, fmt.Errorf("auth: passkey: list credentials: %w", err)
	}
	defer rows.Close()
	var creds []webauthn.Credential
	for rows.Next() {
		var id []byte
		if err := rows.Scan(&id); err != nil {
			return nil, nil, fmt.Errorf("auth: passkey: list credentials: %w", err)
		}
		creds = append(creds, webauthn.Credential{ID: id})
	}
	if err := rows.Err(); err != nil {
		return nil, nil, fmt.Errorf("auth: passkey: list credentials: %w", err)
	}
	return creds, handle, nil
}

type dbtx interface {
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
}

type execer interface {
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
}

func insertCredential(ctx context.Context, q execer, sc storedCredential, now time.Time) error {
	var transports any
	if ts := transportsString(sc.Credential.Transport); ts != "" {
		transports = ts
	}
	var aaguid any
	if len(sc.Credential.Authenticator.AAGUID) > 0 {
		aaguid = sc.Credential.Authenticator.AAGUID
	}
	_, err := q.Exec(ctx,
		`INSERT INTO webauthn_credentials
		   (credential_id, user_id, user_handle, public_key, sign_count, aaguid, transports,
		    backup_eligible, backup_state, attestation_sha256, created_at)
		 VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)`,
		sc.Credential.ID, sc.UserID, sc.UserHandle, sc.Credential.PublicKey,
		int64(sc.Credential.Authenticator.SignCount), aaguid, transports,
		sc.Credential.Flags.BackupEligible, sc.Credential.Flags.BackupState, sc.AttestationSHA256, now)
	if err != nil {
		return fmt.Errorf("auth: passkey: store credential: %w", err)
	}
	return nil
}

func transportsString(ts []protocol.AuthenticatorTransport) string {
	if len(ts) == 0 {
		return ""
	}
	out := make([]string, 0, len(ts))
	for _, t := range ts {
		if s := strings.TrimSpace(string(t)); s != "" {
			out = append(out, s)
		}
	}
	return strings.Join(out, ",")
}

func (p *Passkeys) touchCredential(ctx context.Context, q execer, credentialID []byte, signCount uint32, now time.Time) error {
	if _, err := q.Exec(ctx,
		`UPDATE webauthn_credentials
		    SET sign_count = GREATEST(sign_count, $2), last_used_at = $3
		  WHERE credential_id = $1`,
		credentialID, int64(signCount), now); err != nil {
		return fmt.Errorf("auth: passkey: update credential: %w", err)
	}
	return nil
}

func (p *Passkeys) userIDForHandle(ctx context.Context, q querier, handle []byte) (uuid.UUID, error) {
	var id uuid.UUID
	err := q.QueryRow(ctx,
		`SELECT id FROM users WHERE user_handle = $1`, handle).Scan(&id)
	if errors.Is(err, pgx.ErrNoRows) {
		return uuid.Nil, ErrCredentialUnknown
	}
	if err != nil {
		return uuid.Nil, fmt.Errorf("auth: passkey: resolve user handle: %w", err)
	}
	return id, nil
}
