package auth

import (
	"bytes"
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/pgtx"
	"github.com/salehtl/hasala/server/internal/purgeledger"
)

var (
	ErrKeysExist     = errors.New("auth: the account already has keys")
	ErrKeysMalformed = errors.New("auth: key material is malformed")
	ErrNotYours      = errors.New("auth: no such credential on this account")
	ErrNoKeys        = errors.New("auth: the account has no keys")
	ErrPhraseUnseen  = errors.New("auth: the 12 words are not seen yet")
)

func checkSyncedPasskey(ctx context.Context, pool *pgxpool.Pool, userID uuid.UUID, credentialID []byte) error {
	var synced bool
	err := pool.QueryRow(ctx,
		`SELECT COALESCE(backup_eligible AND backup_state, false) FROM webauthn_credentials WHERE user_id = $1 AND credential_id = $2`,
		userID, credentialID).Scan(&synced)
	if errors.Is(err, pgx.ErrNoRows) {
		return fmt.Errorf("%w: phrase_unseen needs the creating passkey", ErrKeysMalformed)
	}
	if err != nil {
		return fmt.Errorf("auth: bootstrap: %w", err)
	}
	if !synced {
		return fmt.Errorf("%w: phrase_unseen needs a synced passkey", ErrKeysMalformed)
	}
	return nil
}

func refuseIfLastUnseenWrapTx(ctx context.Context, tx pgx.Tx, userID uuid.UUID, credentialID []byte) error {
	if _, err := tx.Exec(ctx, `SELECT 1 FROM account_keys WHERE user_id = $1 FOR UPDATE`, userID); err != nil {
		return err
	}
	var last bool
	if err := tx.QueryRow(ctx,
		`SELECT EXISTS (SELECT 1 FROM account_keys k WHERE k.user_id = $1 AND k.phrase_seen_at IS NULL)
		    AND EXISTS (SELECT 1 FROM account_key_wraps w WHERE w.user_id = $1 AND w.credential_id = $2)
		    AND NOT EXISTS (SELECT 1 FROM account_key_wraps w WHERE w.user_id = $1 AND w.credential_id <> $2)`,
		userID, credentialID).Scan(&last); err != nil {
		return fmt.Errorf("auth: words seen check: %w", err)
	}
	if last {
		return ErrPhraseUnseen
	}
	return nil
}

type AccountKeys struct {
	Pool   *pgxpool.Pool
	StepUp *StepUp
	Now    func() time.Time
	Record func(purgeledger.Entry)
	Hold   purgeledger.HoldFunc
}

func (k *AccountKeys) now() time.Time {
	if k.Now != nil {
		return k.Now()
	}
	return time.Now()
}

type Bootstrap struct {
	FormatVersion   int
	AMKCommitment   []byte
	AuthorityPubkey []byte
	RecoveryPubkey  []byte
	RecoveryWrap    []byte
	PhraseBox       []byte
	EmailHash       []byte
	AuthKind        int
	AuthHash        []byte
	PRFCredentialID []byte
	PRFWrap         []byte
	PRFWrapVersion  int
	Writer          Registration
	AuthoritySig    []byte
	StepUp          *StepUpObject
	PhraseUnseen    bool
}

type Bootstrapped struct {
	WriterID     string
	CurrentEpoch int
}

func (k *AccountKeys) Bootstrap(ctx context.Context, session SessionInfo, b Bootstrap) (Bootstrapped, error) {
	if k.Pool == nil {
		return Bootstrapped{}, errors.New("auth: AccountKeys.Pool is nil")
	}
	userID := session.UserID
	var exists bool
	if err := k.Pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM account_keys WHERE user_id = $1)`, userID).Scan(&exists); err != nil {
		return Bootstrapped{}, fmt.Errorf("auth: bootstrap: %w", err)
	}
	if exists {
		return Bootstrapped{}, ErrKeysExist
	}
	if b.FormatVersion != keyproto.BootstrapPayloadVersion {
		return Bootstrapped{}, fmt.Errorf("%w: format_version %d", ErrKeysMalformed, b.FormatVersion)
	}
	if !keyproto.ValidWriterID(b.Writer.WriterID) {
		return Bootstrapped{}, ErrBadWriterID
	}
	if b.Writer.Alg != AlgEd25519 {
		return Bootstrapped{}, fmt.Errorf("%w: writer.alg is not Ed25519", ErrKeysMalformed)
	}
	if b.AuthKind < 0 || b.AuthKind > int(keyproto.AuthKindPassword) {
		return Bootstrapped{}, fmt.Errorf("%w: auth_kind %d", ErrKeysMalformed, b.AuthKind)
	}
	if b.PRFCredentialID != nil && b.PRFWrapVersion != 1 {
		return Bootstrapped{}, fmt.Errorf("%w: prf_wrap.wrap_version %d", ErrKeysMalformed, b.PRFWrapVersion)
	}
	pl := keyproto.BootstrapPayload{
		UserID: userID, AMKCommitment: b.AMKCommitment, AuthorityPubkey: b.AuthorityPubkey,
		RecoveryPubkey: b.RecoveryPubkey, RecoveryWrap: b.RecoveryWrap, PhraseBox: b.PhraseBox,
		EmailHash: b.EmailHash, AuthKind: byte(b.AuthKind), AuthHash: b.AuthHash,
		WriterPubkey: b.Writer.PubKey, WriterDAK: b.Writer.DAKPubkey, WriterID: b.Writer.WriterID,
		CredentialID: b.PRFCredentialID, PRFWrap: b.PRFWrap,
	}
	payload, err := pl.Bytes()
	if err != nil {
		return Bootstrapped{}, fmt.Errorf("%w: %v", ErrKeysMalformed, err)
	}
	if err := pl.CheckKeys(); err != nil {
		return Bootstrapped{}, fmt.Errorf("%w: %v", ErrKeysMalformed, err)
	}
	if len(b.AuthoritySig) != keyproto.Ed25519SigSize || len(b.Writer.Sig) != keyproto.Ed25519SigSize {
		return Bootstrapped{}, fmt.Errorf("%w: a signature is not 64 bytes", ErrBadSignature)
	}
	var (
		emailNorm *string
		pending   []byte
		frozen    bool
	)
	if err := k.Pool.QueryRow(ctx, `SELECT email_norm, authority_pubkey_pending, frozen_at IS NOT NULL FROM users WHERE id = $1`, userID).
		Scan(&emailNorm, &pending, &frozen); err != nil {
		return Bootstrapped{}, fmt.Errorf("auth: bootstrap: read account: %w", err)
	}
	if frozen {
		return Bootstrapped{}, ErrAccountFrozen
	}
	if b.PRFCredentialID != nil {
		var mine bool
		if err := k.Pool.QueryRow(ctx,
			`SELECT EXISTS (SELECT 1 FROM webauthn_credentials WHERE user_id = $1 AND credential_id = $2)`,
			userID, b.PRFCredentialID).Scan(&mine); err != nil {
			return Bootstrapped{}, fmt.Errorf("auth: bootstrap: %w", err)
		}
		if !mine {
			return Bootstrapped{}, ErrNotYours
		}
	}
	if emailNorm == nil {
		return Bootstrapped{}, fmt.Errorf("%w: the account has no address to bind", ErrKeysMalformed)
	}
	if want := keyproto.EmailHash(*emailNorm); !bytes.Equal(want[:], b.EmailHash) {
		return Bootstrapped{}, fmt.Errorf("%w: email_hash is not the account's address", ErrKeysMalformed)
	}
	pendingPath := pending != nil && bytes.Equal(pending, b.AuthorityPubkey)
	switch {
	case byte(b.AuthKind) == keyproto.AuthKindPassword:
		return Bootstrapped{}, fmt.Errorf("%w: auth_kind 2 exists only inside the password signup", ErrKeysMalformed)
	case pendingPath:
		if byte(b.AuthKind) != keyproto.AuthKindPasskey {
			return Bootstrapped{}, fmt.Errorf("%w: the pending authority key bootstraps with auth_kind 1", ErrKeysMalformed)
		}
		var att []byte
		if err := k.Pool.QueryRow(ctx,
			`SELECT attestation_sha256 FROM webauthn_credentials WHERE user_id = $1 ORDER BY created_at, credential_id LIMIT 1`,
			userID).Scan(&att); err != nil || !bytes.Equal(att, b.AuthHash) {
			return Bootstrapped{}, fmt.Errorf("%w: auth_hash is not the creating credential's attestation", ErrKeysMalformed)
		}
	default:
		if byte(b.AuthKind) != keyproto.AuthKindNone || !bytes.Equal(b.AuthHash, make([]byte, 32)) {
			return Bootstrapped{}, fmt.Errorf("%w: a stepped-up bootstrap carries auth_kind 0 and a zero auth_hash", ErrKeysMalformed)
		}
		if b.StepUp == nil {
			return Bootstrapped{}, ErrStepUpRequired
		}
	}
	if b.PhraseUnseen {
		if !pendingPath || b.PRFCredentialID == nil {
			return Bootstrapped{}, fmt.Errorf("%w: phrase_unseen needs the creating passkey and its PRF wrap", ErrKeysMalformed)
		}
		if err := checkSyncedPasskey(ctx, k.Pool, userID, b.PRFCredentialID); err != nil {
			return Bootstrapped{}, err
		}
	}
	if err := consumeChallenge(ctx, k.Pool, k.now(), userID, b.Writer.Nonce); err != nil {
		return Bootstrapped{}, err
	}
	bm, err := keyproto.BootstrapMessage(b.Writer.Nonce, payload)
	if err != nil {
		return Bootstrapped{}, fmt.Errorf("%w: %v", ErrKeysMalformed, err)
	}
	rm, err := keyproto.RegistrationMessage(b.Writer.Nonce, b.Writer.WriterID, b.Writer.PubKey, b.Writer.DAKPubkey)
	if err != nil {
		return Bootstrapped{}, fmt.Errorf("%w: %v", ErrKeysMalformed, err)
	}
	if !keyproto.VerifyEd25519(b.AuthorityPubkey, bm, b.AuthoritySig) ||
		!keyproto.VerifyEd25519(b.AuthorityPubkey, rm, b.Writer.Sig) {
		return Bootstrapped{}, fmt.Errorf("%w: authority_sig or registration_sig", ErrBadSignature)
	}

	var viaPending []byte
	if pendingPath {
		viaPending = pending
	}
	write := func(ctx context.Context, tx pgx.Tx, _ Proven) error {
		return k.bootstrapTx(ctx, tx, session, b, viaPending)
	}
	if pendingPath {
		tx, err := pgtx.BeginReadCommitted(ctx, k.Pool)
		if err != nil {
			return Bootstrapped{}, fmt.Errorf("auth: bootstrap: begin: %w", err)
		}
		defer pgtx.Rollback(ctx, tx)
		if err := write(ctx, tx, Proven{}); err != nil {
			return Bootstrapped{}, err
		}
		if err := tx.Commit(ctx); err != nil {
			return Bootstrapped{}, fmt.Errorf("auth: bootstrap: commit: %w", err)
		}
	} else {
		if k.StepUp == nil {
			return Bootstrapped{}, errors.New("auth: AccountKeys.StepUp is nil")
		}
		g, err := guardFor(session, keyproto.ActionKeysBootstrap, b.StepUp, b.AuthorityPubkey)
		if err != nil {
			return Bootstrapped{}, err
		}
		if err := k.StepUp.Run(ctx, g, write); err != nil {
			return Bootstrapped{}, err
		}
	}
	return Bootstrapped{WriterID: b.Writer.WriterID, CurrentEpoch: 1}, nil
}

func (k *AccountKeys) bootstrapTx(ctx context.Context, tx pgx.Tx, session SessionInfo, b Bootstrap, viaPending []byte) error {
	userID := session.UserID
	if err := lockUser(ctx, tx, userID); err != nil {
		return err
	}
	now := k.now()
	if _, err := tx.Exec(ctx,
		`INSERT INTO account_keys (user_id, format_version, amk_commitment, authority_pubkey, recovery_pubkey,
		   recovery_wrap, phrase_box, current_epoch, created_at, updated_at, phrase_seen_at)
		 VALUES ($1, 1, $2, $3, $4, $5, $6, 1, $7, $7, CASE WHEN $8::boolean THEN NULL ELSE $7::timestamptz END)`,
		userID, b.AMKCommitment, b.AuthorityPubkey, b.RecoveryPubkey, b.RecoveryWrap, b.PhraseBox, now, b.PhraseUnseen); err != nil {
		if pg := uniqueViolation(err); pg != nil {
			if pg.ConstraintName == "account_keys_pkey" {
				return ErrKeysExist
			}
			return fmt.Errorf("%w: the authority or recovery key is already in use", ErrKeysMalformed)
		}
		return fmt.Errorf("auth: bootstrap: insert account_keys: %w", err)
	}
	if b.PRFCredentialID != nil {
		if _, err := tx.Exec(ctx,
			`INSERT INTO account_key_wraps (user_id, credential_id, wrap, wrap_version, created_at) VALUES ($1,$2,$3,1,$4)`,
			userID, b.PRFCredentialID, b.PRFWrap, now); err != nil {
			return fmt.Errorf("auth: bootstrap: insert the PRF wrap: %w", err)
		}
	}
	if err := insertWriterTx(ctx, tx, userID, b.Writer, now); err != nil {
		return err
	}
	if err := recordEventTx(ctx, tx, nil, userID, AuthEvent{Kind: EventDeviceAdded, WriterID: b.Writer.WriterID}, now); err != nil {
		return err
	}
	if viaPending != nil {
		tag, err := tx.Exec(ctx,
			`UPDATE users SET authority_pubkey_pending = NULL WHERE id = $1 AND authority_pubkey_pending = $2`, userID, viaPending)
		if err != nil {
			return fmt.Errorf("auth: bootstrap: clear the pending authority key: %w", err)
		}
		if tag.RowsAffected() != 1 {
			return fmt.Errorf("%w: the pending authority key changed during the bootstrap", ErrKeysMalformed)
		}
	} else if _, err := tx.Exec(ctx,
		`UPDATE users SET authority_pubkey_pending = NULL WHERE id = $1 AND authority_pubkey_pending IS NOT NULL`, userID); err != nil {
		return fmt.Errorf("auth: bootstrap: clear the pending authority key: %w", err)
	}
	if _, err := tx.Exec(ctx,
		`INSERT INTO account_usage (user_id, resource, amount) VALUES ($1, 'oplog_hot_bytes', 0) ON CONFLICT DO NOTHING`, userID); err != nil {
		return fmt.Errorf("auth: bootstrap: account_usage: %w", err)
	}
	return bindSessionTx(ctx, tx, session.Hash, userID, b.Writer.WriterID)
}

type Keys struct {
	FormatVersion   int
	AMKCommitment   []byte
	AuthorityPubkey []byte
	RecoveryPubkey  []byte
	RecoveryWrap    []byte
	CurrentEpoch    int
	CreatedAt       time.Time
	UpdatedAt       time.Time
}

func (k *AccountKeys) Read(ctx context.Context, userID uuid.UUID) (Keys, error) {
	var out Keys
	err := k.Pool.QueryRow(ctx,
		`SELECT format_version, amk_commitment, authority_pubkey, recovery_pubkey, recovery_wrap, current_epoch, created_at, updated_at
		   FROM account_keys WHERE user_id = $1`, userID).
		Scan(&out.FormatVersion, &out.AMKCommitment, &out.AuthorityPubkey, &out.RecoveryPubkey, &out.RecoveryWrap,
			&out.CurrentEpoch, &out.CreatedAt, &out.UpdatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return Keys{}, ErrNoKeys
	}
	if err != nil {
		return Keys{}, fmt.Errorf("auth: read keys: %w", err)
	}
	return out, nil
}

type Wrap struct {
	CredentialID []byte
	Wrap         []byte
	WrapVersion  int
	CreatedAt    time.Time
}

func (k *AccountKeys) Wraps(ctx context.Context, userID uuid.UUID) ([]Wrap, error) {
	rows, err := k.Pool.Query(ctx,
		`SELECT credential_id, wrap, wrap_version, created_at FROM account_key_wraps WHERE user_id = $1 ORDER BY created_at, credential_id`,
		userID)
	if err != nil {
		return nil, fmt.Errorf("auth: read wraps: %w", err)
	}
	defer rows.Close()
	out := []Wrap{}
	for rows.Next() {
		var w Wrap
		if err := rows.Scan(&w.CredentialID, &w.Wrap, &w.WrapVersion, &w.CreatedAt); err != nil {
			return nil, err
		}
		out = append(out, w)
	}
	return out, rows.Err()
}

type WrapPut struct {
	CredentialID []byte
	Wrap         []byte
	WrapVersion  int
	DWKSig       []byte
	StepUp       *StepUpObject
}

func (k *AccountKeys) PutWrap(ctx context.Context, session SessionInfo, p WrapPut) error {
	if err := keyproto.CheckCredentialID(p.CredentialID); err != nil {
		return fmt.Errorf("%w: %v", ErrKeysMalformed, err)
	}
	if err := keyproto.CheckPRFWrap(p.Wrap); err != nil {
		return fmt.Errorf("%w: %v", ErrKeysMalformed, err)
	}
	if p.WrapVersion != 1 {
		return fmt.Errorf("%w: wrap_version %d", ErrKeysMalformed, p.WrapVersion)
	}
	if len(p.DWKSig) != keyproto.Ed25519SigSize {
		return fmt.Errorf("%w: dwk_sig is %d bytes", ErrBadSignature, len(p.DWKSig))
	}
	if p.StepUp == nil {
		return ErrStepUpRequired
	}
	g, err := guardFor(session, keyproto.ActionKeysWrapPut, p.StepUp, p.CredentialID)
	if err != nil {
		return err
	}
	return k.StepUp.Run(ctx, g, func(ctx context.Context, tx pgx.Tx, proven Proven) error {
		if !bytes.Equal(proven.CredentialID, p.CredentialID) {
			return fmt.Errorf("%w: the asserting credential is not the wrap's", ErrStepUpFailed)
		}
		var mine bool
		if err := tx.QueryRow(ctx,
			`SELECT EXISTS (SELECT 1 FROM webauthn_credentials WHERE user_id = $1 AND credential_id = $2)`,
			session.UserID, p.CredentialID).Scan(&mine); err != nil {
			return err
		}
		if !mine {
			return ErrNotYours
		}
		var (
			dwk  []byte
			live bool
		)
		if err := tx.QueryRow(ctx, `SELECT pubkey, revoked_at IS NULL FROM writers WHERE user_id = $1 AND writer_id = $2`,
			session.UserID, session.WriterID).Scan(&dwk, &live); err != nil || !live {
			return ErrWriterUnbound
		}
		msg, err := keyproto.WrapPutMessage(proven.Nonce, p.CredentialID, p.Wrap)
		if err != nil || !keyproto.VerifyEd25519(dwk, msg, p.DWKSig) {
			return fmt.Errorf("%w: dwk_sig over WrapPutMessage", ErrBadSignature)
		}
		_, err = tx.Exec(ctx,
			`INSERT INTO account_key_wraps (user_id, credential_id, wrap, wrap_version, created_at)
			 VALUES ($1, $2, $3, 1, $4)
			 ON CONFLICT (user_id, credential_id)
			 DO UPDATE SET wrap = EXCLUDED.wrap, wrap_version = EXCLUDED.wrap_version, created_at = EXCLUDED.created_at`,
			session.UserID, p.CredentialID, p.Wrap, k.now())
		if err != nil {
			return fmt.Errorf("auth: store wrap: %w", err)
		}
		return nil
	})
}

func (k *AccountKeys) DeleteWrap(ctx context.Context, session SessionInfo, credentialID []byte, su *StepUpObject) error {
	if err := keyproto.CheckCredentialID(credentialID); err != nil {
		return fmt.Errorf("%w: %v", ErrKeysMalformed, err)
	}
	if su == nil {
		return ErrStepUpRequired
	}
	g, err := guardFor(session, keyproto.ActionKeysWrapDelete, su, credentialID)
	if err != nil {
		return err
	}
	var held purgeledger.Held
	err = k.StepUp.Run(ctx, g, func(ctx context.Context, tx pgx.Tx, _ Proven) error {
		if err := refuseIfLastUnseenWrapTx(ctx, tx, session.UserID, credentialID); err != nil {
			return err
		}
		tag, err := tx.Exec(ctx, `DELETE FROM account_key_wraps WHERE user_id = $1 AND credential_id = $2`, session.UserID, credentialID)
		if err != nil || tag.RowsAffected() == 0 {
			return err
		}
		held, err = k.Hold.Tx(ctx, tx, wrapDeletionEntry(session.UserID, credentialID, k.now()))
		return err
	})
	if err != nil {
		return err
	}
	held.Release(k.Record)
	return nil
}

func AttestationHash(attestationObject []byte) []byte {
	h := sha256.Sum256(attestationObject)
	return h[:]
}
