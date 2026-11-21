package auth

import (
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/salehtl/hasala/server/internal/authkeys"
	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/pgtx"
	"github.com/salehtl/hasala/server/internal/purgeledger"
	"github.com/salehtl/hasala/server/internal/pushv2"
)

const PasswordLoginTTL = 5 * time.Minute

var dummyBindKey = ed25519.NewKeyFromSeed(make([]byte, 32)).Public().(ed25519.PublicKey)

type DeviceBinding struct {
	WriterID string
	Sig      []byte
}

type SignedIn struct {
	Session    Minted
	UserID     uuid.UUID
	WriterID   string
	HasKeys    bool
	Restricted bool
	Wake       Wake
}

type PasswordLoginBegun struct {
	CeremonyID string
	Salt       []byte
	Nonce      []byte
}

func (a *Accounts) PasswordLoginBegin(ctx context.Context, email string) (PasswordLoginBegun, error) {
	addr, err := normEmail(email)
	if err != nil {
		return PasswordLoginBegun{}, err
	}
	id, err := newCeremonyIDN(32)
	if err != nil {
		return PasswordLoginBegun{}, err
	}
	nonce, err := randBytes(keyproto.NonceSize)
	if err != nil {
		return PasswordLoginBegun{}, err
	}
	now := a.now()
	if _, err := a.Pool.Exec(ctx,
		`INSERT INTO password_login_ceremonies (id, user_id, email_tag, nonce, created_at, expires_at)
		 VALUES ($1, (SELECT id FROM users WHERE email_norm = $2), $3, $4, $5, $6)`,
		id, addr, a.Keys.EmailTag(addr), nonce, now, now.Add(PasswordLoginTTL)); err != nil {
		return PasswordLoginBegun{}, fmt.Errorf("auth: password login begin: %w", err)
	}
	return PasswordLoginBegun{CeremonyID: id, Salt: a.Keys.PasswordSalt(addr), Nonce: nonce}, nil
}

func checkBinding(ctx context.Context, q querier, userID *uuid.UUID, challenge []byte, d *DeviceBinding) error {
	key := []byte(dummyBindKey)
	live, known := false, false
	owner := uuid.Nil
	if userID != nil {
		owner = *userID
	}
	var pub []byte
	err := q.QueryRow(ctx, `SELECT pubkey, revoked_at IS NULL FROM writers WHERE user_id = $1 AND writer_id = $2`,
		owner, d.WriterID).Scan(&pub, &live)
	switch {
	case err == nil && userID != nil && keyproto.ValidWriterID(d.WriterID):
		key, known = pub, true
	case err != nil && !errors.Is(err, pgx.ErrNoRows):
		return fmt.Errorf("auth: read the binding writer: %w", err)
	}
	msg, err := keyproto.SessionBindMessage(challenge, d.WriterID)
	if err != nil {
		msg = make([]byte, keyproto.SessionBindSize)
	}
	ok := keyproto.VerifyEd25519(key, msg, d.Sig)
	switch {
	case !ok || !known || err != nil:
		return fmt.Errorf("%w: the session binding does not verify", ErrBadSignature)
	case !live:
		return ErrWriterRevoked
	}
	return nil
}

func (a *Accounts) signInTx(ctx context.Context, tx pgx.Tx, st accountState, mintedBy, method string, cred []byte, writer string) (SignedIn, error) {
	now := a.now()
	restricted := st.frozen()
	m, err := a.Sessions.IssueTx(ctx, tx, Mint{UserID: st.ID, MintedBy: mintedBy, CredentialID: cred,
		WriterID: writer, Restricted: restricted})
	if err != nil {
		return SignedIn{}, err
	}
	if writer == "" && !restricted {
		if err := recordEventTx(ctx, tx, a.Mail, st.ID, AuthEvent{Kind: EventSignInNew, Method: method, CredentialID: cred}, now); err != nil {
			return SignedIn{}, err
		}
	}
	return SignedIn{Session: m, UserID: st.ID, WriterID: writer, HasKeys: st.HasKeys, Restricted: restricted}, nil
}

func (a *Accounts) PasskeyLoginFinish(ctx context.Context, ceremonyID string, response []byte, device *DeviceBinding) (SignedIn, error) {
	r, err := a.Passkeys.FinishLoginResult(ctx, ceremonyID, response)
	if err != nil {
		return SignedIn{}, err
	}
	writer := ""
	if device != nil {
		var mine bool
		if err := a.Pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM writers WHERE user_id = $1 AND writer_id = $2)`,
			r.UserID, device.WriterID).Scan(&mine); err != nil {
			return SignedIn{}, fmt.Errorf("auth: read the binding writer: %w", err)
		}
		if !mine {
			return SignedIn{}, ErrDeviceOtherAccount
		}
		if err := checkBinding(ctx, a.Pool, &r.UserID, r.Challenge, device); err != nil {
			return SignedIn{}, err
		}
		writer = device.WriterID
	}
	tx, err := pgtx.BeginReadCommitted(ctx, a.Pool)
	if err != nil {
		return SignedIn{}, err
	}
	defer pgtx.Rollback(ctx, tx)
	st, err := readAccount(ctx, tx, r.UserID, true)
	if err != nil {
		return SignedIn{}, err
	}
	out, err := a.signInTx(ctx, tx, st, MintedLogin, MethodPasskey, r.CredentialID, writer)
	if err != nil {
		return SignedIn{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return SignedIn{}, err
	}
	a.Mail.Kick()
	return out, nil
}

func (a *Accounts) PasswordLoginFinish(ctx context.Context, ceremonyID string, verifier []byte, device *DeviceBinding) (SignedIn, error) {
	now := a.now()
	var (
		userID       *uuid.UUID
		tag, nonce   []byte
		expires      time.Time
		used         *time.Time
		cerOK        = true
		boundWriter  string
		passwordStep = func(st accountState, compare bool) (bool, error) {
			return passwordMatches(ctx, a.Keys, a.Gate, st, verifier, compare)
		}
	)
	err := a.Pool.QueryRow(ctx,
		`SELECT user_id, email_tag, nonce, expires_at, used_at FROM password_login_ceremonies WHERE id = $1`, ceremonyID).
		Scan(&userID, &tag, &nonce, &expires, &used)
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && (used != nil || !expires.After(now))) {
		cerOK = false
	} else if err != nil {
		return SignedIn{}, fmt.Errorf("auth: password login: %w", err)
	}
	if !cerOK {
		if _, err := passwordStep(accountState{}, false); err != nil {
			return SignedIn{}, err
		}
		return SignedIn{}, fmt.Errorf("%w: no usable ceremony", ErrPasswordRejected)
	}
	if device != nil {
		if err := checkBinding(ctx, a.Pool, userID, nonce, device); err != nil {
			if errors.Is(err, ErrBadSignature) {
				_, _ = a.Pool.Exec(ctx, `UPDATE password_login_ceremonies SET used_at = $2 WHERE id = $1 AND used_at IS NULL`, ceremonyID, now)
			}
			return SignedIn{}, err
		}
		boundWriter = device.WriterID
	}
	if boundWriter == "" {
		n, err := bumpCounter(ctx, a.Pool, "password-email", tag, passwordEmailWindow, now)
		if err != nil {
			return SignedIn{}, err
		}
		if n > passwordEmailLimit {
			return SignedIn{}, fmt.Errorf("%w: password attempts for this address", ErrRateLimited)
		}
	} else if err := writerPasswordAttempt(ctx, a.Pool, *userID, boundWriter, now); err != nil {
		return SignedIn{}, err
	}
	release, err := a.Gate.Acquire(ctx)
	if err != nil {
		var rerr error
		if boundWriter != "" {
			rerr = refundWriterPasswordAttempt(ctx, a.Pool, *userID, boundWriter, now)
		} else {
			rerr = refundEmailPasswordAttempt(ctx, a.Pool, tag, now)
		}
		if rerr != nil {
			return SignedIn{}, rerr
		}
		return SignedIn{}, gateErr(err)
	}
	defer release()
	tag2, err := a.Pool.Exec(ctx,
		`UPDATE password_login_ceremonies SET used_at = $2 WHERE id = $1 AND used_at IS NULL AND expires_at > $2`, ceremonyID, now)
	if err != nil {
		return SignedIn{}, err
	}
	var st accountState
	exists := false
	target := uuid.Nil
	if userID != nil && tag2.RowsAffected() == 1 {
		target = *userID
	}
	if st, err = readAccount(ctx, a.Pool, target, false); err == nil {
		exists = true
	} else if !errors.Is(err, ErrNoSuchAccount) {
		return SignedIn{}, err
	}
	paused := exists && st.PausedUntil != nil && st.PausedUntil.After(now) && boundWriter == ""
	compare := exists && st.hasPassword() && !paused
	ok, err := passwordMatches(ctx, a.Keys, nil, st, verifier, compare)
	release()
	if err != nil {
		return SignedIn{}, err
	}
	if !ok {
		if compare {
			if err := recordPasswordFailure(ctx, a.Pool, st.ID, now); err != nil {
				return SignedIn{}, err
			}
		} else if _, err := a.Pool.Exec(ctx,
			`UPDATE users SET password_failures = password_failures + 1 WHERE id = $1`, uuid.Nil); err != nil {
			return SignedIn{}, err
		}
		return SignedIn{}, fmt.Errorf("%w: wrong, absent or paused", ErrPasswordRejected)
	}
	tx, err := pgtx.BeginReadCommitted(ctx, a.Pool)
	if err != nil {
		return SignedIn{}, err
	}
	defer pgtx.Rollback(ctx, tx)
	if st, err = readAccount(ctx, tx, st.ID, true); err != nil {
		return SignedIn{}, err
	}
	if _, err := tx.Exec(ctx, `UPDATE users SET password_failures = 0, password_paused_until = NULL WHERE id = $1`, st.ID); err != nil {
		return SignedIn{}, err
	}
	if boundWriter != "" {
		if err := refundWriterPasswordAttempt(ctx, tx, st.ID, boundWriter, now); err != nil {
			return SignedIn{}, err
		}
	}
	out, err := a.signInTx(ctx, tx, st, MintedPasswordLogin, MethodPassword, nil, boundWriter)
	if err != nil {
		return SignedIn{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return SignedIn{}, err
	}
	a.Mail.Kick()
	return out, nil
}

type PasswordSignedUp struct {
	Session  Minted
	UserID   uuid.UUID
	WriterID string
}

func (a *Accounts) PasswordSignup(ctx context.Context, signupID string, verifier []byte, b Bootstrap) (PasswordSignedUp, error) {
	now := a.now()
	if len(verifier) != authkeys.VerifierSize {
		return PasswordSignedUp{}, fmt.Errorf("%w: verifier is not 32 bytes", ErrBadRequest)
	}
	s, err := readySignup(ctx, a.Pool, signupID, now)
	if err != nil {
		return PasswordSignedUp{}, err
	}
	spend := func(err error) (PasswordSignedUp, error) {
		if _, xerr := a.Pool.Exec(ctx, `UPDATE signup_ceremonies SET claimed_at = $2 WHERE id = $1 AND claimed_at IS NULL`,
			signupID, now); xerr != nil {
			return PasswordSignedUp{}, errors.Join(err, fmt.Errorf("auth: password signup: spend: %w", xerr))
		}
		return PasswordSignedUp{}, err
	}
	if err := addressFree(ctx, a.Pool, s); err != nil {
		if errors.Is(err, ErrEmailInUse) || errors.Is(err, ErrCodeRejected) {
			return spend(err)
		}
		return PasswordSignedUp{}, err
	}
	var unspent bool
	if err := a.Pool.QueryRow(ctx,
		`SELECT EXISTS (SELECT 1 FROM invite_codes WHERE code_hash = $1 AND state = 'active' AND expires_at > $2)`,
		s.InviteHash, now).Scan(&unspent); err != nil {
		return PasswordSignedUp{}, fmt.Errorf("auth: password signup: invite: %w", err)
	}
	if !unspent {
		return spend(fmt.Errorf("%w: the invite is spent", ErrCodeRejected))
	}
	if err := checkPasswordBootstrap(s, verifier, b); err != nil {
		return spend(err)
	}
	hash, salt, err := newPasswordHash(ctx, a.Keys, a.Gate, verifier)
	if err != nil {
		return PasswordSignedUp{}, err
	}
	handle, err := randBytes(userHandleBytes)
	if err != nil {
		return PasswordSignedUp{}, err
	}
	tx, err := pgtx.BeginReadCommitted(ctx, a.Pool)
	if err != nil {
		return PasswordSignedUp{}, err
	}
	defer pgtx.Rollback(ctx, tx)
	claimed, err := claimSignupTx(ctx, tx, signupID, now)
	if err != nil {
		return PasswordSignedUp{}, err
	}
	if claimed.UserID != s.UserID || claimed.EmailNorm != s.EmailNorm || !sameBytes(claimed.Nonce, s.Nonce) {
		return PasswordSignedUp{}, fmt.Errorf("%w: the signup changed", ErrCodeRejected)
	}
	s = claimed
	if err := createAccountTx(ctx, tx, s, handle, now); err != nil {
		if errors.Is(err, ErrNotInvited) {
			return PasswordSignedUp{}, fmt.Errorf("%w: the invite is spent", ErrCodeRejected)
		}
		return PasswordSignedUp{}, err
	}
	if err := setPasswordTx(ctx, tx, s.UserID, hash, salt, a.Keys.Current(), now); err != nil {
		return PasswordSignedUp{}, err
	}
	if _, err := tx.Exec(ctx,
		`INSERT INTO account_keys (user_id, format_version, amk_commitment, authority_pubkey, recovery_pubkey,
		   recovery_wrap, phrase_box, current_epoch, created_at, updated_at, phrase_seen_at)
		 VALUES ($1, 1, $2, $3, $4, $5, $6, 1, $7, $7, $7)`,
		s.UserID, b.AMKCommitment, b.AuthorityPubkey, b.RecoveryPubkey, b.RecoveryWrap, b.PhraseBox, now); err != nil {
		if uniqueViolation(err) != nil {
			return PasswordSignedUp{}, fmt.Errorf("%w: the authority or recovery key is already in use", ErrKeysMalformed)
		}
		return PasswordSignedUp{}, fmt.Errorf("auth: password signup: keys: %w", err)
	}
	if err := insertWriterTx(ctx, tx, s.UserID, b.Writer, now); err != nil {
		return PasswordSignedUp{}, err
	}
	if err := recordEventTx(ctx, tx, a.Mail, s.UserID, AuthEvent{Kind: EventDeviceAdded, WriterID: b.Writer.WriterID}, now); err != nil {
		return PasswordSignedUp{}, err
	}
	m, err := a.Sessions.IssueTx(ctx, tx, Mint{UserID: s.UserID, MintedBy: MintedPasswordSignup, WriterID: b.Writer.WriterID})
	if err != nil {
		return PasswordSignedUp{}, err
	}
	if err := tx.Commit(ctx); err != nil {
		return PasswordSignedUp{}, fmt.Errorf("auth: password signup: commit: %w", err)
	}
	return PasswordSignedUp{Session: m, UserID: s.UserID, WriterID: b.Writer.WriterID}, nil
}

func checkPasswordBootstrap(s signupRow, verifier []byte, b Bootstrap) error {
	sh := sha256.Sum256(verifier)
	switch {
	case b.FormatVersion != keyproto.BootstrapPayloadVersion:
		return fmt.Errorf("%w: format_version %d", ErrKeysMalformed, b.FormatVersion)
	case byte(b.AuthKind) != keyproto.AuthKindPassword || !sameBytes(b.AuthHash, sh[:]):
		return fmt.Errorf("%w: auth_kind 2 with auth_hash = SHA256(S)", ErrKeysMalformed)
	case !sameBytes(b.EmailHash, signupEmailHash(s)):
		return fmt.Errorf("%w: email_hash is not the signup's address", ErrKeysMalformed)
	case b.PRFCredentialID != nil:
		return fmt.Errorf("%w: a password signup carries no PRF wrap", ErrKeysMalformed)
	case !sameBytes(b.Writer.Nonce, s.Nonce):
		return fmt.Errorf("%w: the nonce is not the signup's", ErrBadSignature)
	case b.Writer.Alg != AlgEd25519:
		return fmt.Errorf("%w: writer.alg is not Ed25519", ErrKeysMalformed)
	case !keyproto.ValidWriterID(b.Writer.WriterID):
		return ErrBadWriterID
	}
	pl := keyproto.BootstrapPayload{
		UserID: s.UserID, AMKCommitment: b.AMKCommitment, AuthorityPubkey: b.AuthorityPubkey,
		RecoveryPubkey: b.RecoveryPubkey, RecoveryWrap: b.RecoveryWrap, PhraseBox: b.PhraseBox,
		EmailHash: b.EmailHash, AuthKind: keyproto.AuthKindPassword, AuthHash: b.AuthHash,
		WriterPubkey: b.Writer.PubKey, WriterDAK: b.Writer.DAKPubkey, WriterID: b.Writer.WriterID,
	}
	payload, err := pl.Bytes()
	if err != nil {
		return fmt.Errorf("%w: %v", ErrKeysMalformed, err)
	}
	if err := pl.CheckKeys(); err != nil {
		return fmt.Errorf("%w: %v", ErrKeysMalformed, err)
	}
	bm, err := keyproto.BootstrapMessage(s.Nonce, payload)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrKeysMalformed, err)
	}
	rm, err := keyproto.RegistrationMessage(s.Nonce, b.Writer.WriterID, b.Writer.PubKey, b.Writer.DAKPubkey)
	if err != nil {
		return fmt.Errorf("%w: %v", ErrKeysMalformed, err)
	}
	if !keyproto.VerifyEd25519(b.AuthorityPubkey, bm, b.AuthoritySig) || !keyproto.VerifyEd25519(b.AuthorityPubkey, rm, b.Writer.Sig) {
		return fmt.Errorf("%w: authority_sig or registration_sig", ErrBadSignature)
	}
	return nil
}

func (a *Accounts) PasswordSalt(email string) ([]byte, error) {
	addr, err := normEmail(email)
	if err != nil {
		return nil, err
	}
	return a.Keys.PasswordSalt(addr), nil
}

func (a *Accounts) passwordAction(ctx context.Context, session SessionInfo, action keyproto.Action, fields [][]byte,
	su *StepUpObject, do func(ctx context.Context, tx pgx.Tx, st accountState, p Proven, now time.Time) (string, error)) (Wake, error) {
	g, err := guardFor(session, action, su, fields...)
	if err != nil {
		return Wake{}, err
	}
	var (
		revoked []pushv2.Target
		held    purgeledger.Held
	)
	err = a.StepUp.Run(ctx, g, func(ctx context.Context, tx pgx.Tx, p Proven) error {
		now := a.now()
		st, err := readAccount(ctx, tx, session.UserID, true)
		if err != nil {
			return err
		}
		if st.frozen() {
			return ErrAccountFrozen
		}
		event, err := do(ctx, tx, st, p, now)
		if err != nil {
			return err
		}
		if event != EventPasswordSet {
			if held, err = a.Hold.Tx(ctx, tx, passwordEntry(session.UserID, now)); err != nil {
				return err
			}
		}
		if revoked, err = RevokeOtherSessionsTx(ctx, tx, session.UserID, [][]byte{session.Hash}, now); err != nil {
			return err
		}
		return recordEventTx(ctx, tx, a.Mail, session.UserID, AuthEvent{Kind: event, WriterID: session.WriterID, CredentialID: p.CredentialID}, now)
	})
	if err != nil {
		return Wake{}, err
	}
	held.Release(a.Record)
	a.Mail.Kick()
	return wakeFor(session.UserID, session.WriterID, revoked), nil
}

func verifierHash(v []byte) ([]byte, error) {
	if len(v) != authkeys.VerifierSize {
		return nil, fmt.Errorf("%w: verifier is not 32 bytes", ErrBadRequest)
	}
	h := sha256.Sum256(v)
	return h[:], nil
}

func (a *Accounts) SetPassword(ctx context.Context, session SessionInfo, verifier []byte, su *StepUpObject) (Wake, error) {
	vh, err := verifierHash(verifier)
	if err != nil {
		return Wake{}, err
	}
	if su == nil {
		return Wake{}, ErrStepUpRequired
	}
	hash, salt, err := newPasswordHash(ctx, a.Keys, a.Gate, verifier)
	if err != nil {
		return Wake{}, err
	}
	return a.passwordAction(ctx, session, keyproto.ActionPasswordSet, [][]byte{vh}, su,
		func(ctx context.Context, tx pgx.Tx, st accountState, _ Proven, now time.Time) (string, error) {
			if st.hasPassword() {
				return "", ErrConflict
			}
			return EventPasswordSet, setPasswordTx(ctx, tx, st.ID, hash, salt, a.Keys.Current(), now)
		})
}

func (a *Accounts) ChangePassword(ctx context.Context, session SessionInfo, verifier []byte, su *StepUpObject) (Wake, error) {
	vh, err := verifierHash(verifier)
	if err != nil {
		return Wake{}, err
	}
	if su == nil {
		return Wake{}, ErrStepUpRequired
	}
	hash, salt, err := newPasswordHash(ctx, a.Keys, a.Gate, verifier)
	if err != nil {
		return Wake{}, err
	}
	return a.passwordAction(ctx, session, keyproto.ActionPasswordChange, [][]byte{vh}, su,
		func(ctx context.Context, tx pgx.Tx, st accountState, _ Proven, now time.Time) (string, error) {
			if !st.hasPassword() {
				return "", fmt.Errorf("%w: the account has no password", ErrBadRequest)
			}
			return EventPasswordChanged, setPasswordTx(ctx, tx, st.ID, hash, salt, a.Keys.Current(), now)
		})
}

func (a *Accounts) RemovePassword(ctx context.Context, session SessionInfo, su *StepUpObject) (Wake, error) {
	return a.passwordAction(ctx, session, keyproto.ActionPasswordRemove, nil, su,
		func(ctx context.Context, tx pgx.Tx, st accountState, _ Proven, now time.Time) (string, error) {
			if !st.hasPassword() {
				return "", fmt.Errorf("%w: the account has no password", ErrBadRequest)
			}
			var passkeys int
			if err := tx.QueryRow(ctx, `SELECT count(*) FROM webauthn_credentials WHERE user_id = $1`, st.ID).Scan(&passkeys); err != nil {
				return "", err
			}
			if passkeys == 0 {
				return "", ErrLastAuthenticator
			}
			if err := clearPasswordTx(ctx, tx, st.ID); err != nil {
				return "", err
			}
			return EventPasswordRemoved, nil
		})
}

func (a *Accounts) ResetPasswordWithCode(ctx context.Context, session SessionInfo, verifier []byte, su *StepUpObject) (Wake, error) {
	vh, err := verifierHash(verifier)
	if err != nil {
		return Wake{}, err
	}
	if su == nil {
		return Wake{}, ErrStepUpRequired
	}
	hash, salt, err := newPasswordHash(ctx, a.Keys, a.Gate, verifier)
	if err != nil {
		return Wake{}, err
	}
	return a.passwordAction(ctx, session, keyproto.ActionPasswordReset, [][]byte{vh}, su,
		func(ctx context.Context, tx pgx.Tx, st accountState, _ Proven, now time.Time) (string, error) {
			if !st.hasPassword() {
				return "", fmt.Errorf("%w: the account has no password", ErrBadRequest)
			}
			return EventPasswordReset, setPasswordTx(ctx, tx, st.ID, hash, salt, a.Keys.Current(), now)
		})
}
