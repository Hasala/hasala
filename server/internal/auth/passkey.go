package auth

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"time"

	"github.com/go-webauthn/webauthn/protocol"
	"github.com/go-webauthn/webauthn/webauthn"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/keyproto"
	"github.com/salehtl/hasala/server/internal/pgtx"
	"github.com/salehtl/hasala/server/internal/purgeledger"
)

const CeremonyTTL = 5 * time.Minute

const userHandleBytes = 32

const ceremonyIDBytes = 32

var (
	ErrPasskeyRejected = errors.New("auth: passkey ceremony rejected")

	ErrCeremonyUnknown = fmt.Errorf("%w: no such ceremony", ErrPasskeyRejected)

	ErrCredentialUnknown = fmt.Errorf("%w: unknown credential", ErrPasskeyRejected)

	ErrClonedAuthenticator = fmt.Errorf("%w: signature counter did not increase", ErrPasskeyRejected)

	ErrNoPasskeyIdentity = fmt.Errorf("%w: this account has no passkey identity", ErrPasskeyRejected)

	ErrBadAuthorityKey = errors.New("auth: passkey: authority_pubkey is not a usable Ed25519 key")
)

type Passkeys struct {
	Pool   *pgxpool.Pool
	WA     *webauthn.WebAuthn
	StepUp *StepUp
	Mail   *Mailer
	Now    func() time.Time
	Record func(purgeledger.Entry)
	Hold   purgeledger.HoldFunc
}

func (p *Passkeys) now() time.Time {
	if p.Now != nil {
		return p.Now()
	}
	return time.Now()
}

func (p *Passkeys) RPID() string {
	return p.WA.Config.RPID
}

func NewPasskeys(pool *pgxpool.Pool, rpID, rpDisplayName string, origins []string) (*Passkeys, error) {
	if pool == nil {
		return nil, errors.New("auth: NewPasskeys: pool is nil")
	}
	if rpID == "" {
		return nil, errors.New("auth: NewPasskeys: rp_id is empty")
	}
	var clean []string
	for _, o := range origins {
		if o != "" {
			clean = append(clean, o)
		}
	}
	if len(clean) == 0 {
		return nil, errors.New("auth: NewPasskeys: auth.rp_origins is empty; " +
			"a ceremony cannot be bound to an origin that is not configured")
	}
	if rpDisplayName == "" {
		rpDisplayName = rpID
	}
	wa, err := webauthn.New(&webauthn.Config{
		RPID:          rpID,
		RPDisplayName: rpDisplayName,
		RPOrigins:     clean,
		AuthenticatorSelection: protocol.AuthenticatorSelection{
			ResidentKey:      protocol.ResidentKeyRequirementRequired,
			UserVerification: protocol.VerificationRequired,
		},
		AttestationPreference: protocol.PreferNoAttestation,
	})
	if err != nil {
		return nil, fmt.Errorf("auth: NewPasskeys: %w", err)
	}
	return &Passkeys{Pool: pool, WA: wa}, nil
}

type passkeyUser struct {
	handle      []byte
	credentials []webauthn.Credential
	rpName      string
}

func (u passkeyUser) WebAuthnID() []byte { return u.handle }

func (u passkeyUser) WebAuthnName() string { return u.rpName }

func (u passkeyUser) WebAuthnDisplayName() string { return u.rpName }

func (u passkeyUser) WebAuthnCredentials() []webauthn.Credential { return u.credentials }

const passkeyUserName = "Hasala"

func (p *Passkeys) BeginRegistration(ctx context.Context, signupID string, authorityPub []byte) (string, *protocol.CredentialCreation, []byte, error) {
	if p.Pool == nil || p.WA == nil {
		return "", nil, nil, errors.New("auth: Passkeys is not configured")
	}
	if err := keyproto.CheckEd25519PublicKey(authorityPub); err != nil {
		return "", nil, nil, fmt.Errorf("%w: %v", ErrBadAuthorityKey, err)
	}
	s, err := readySignup(ctx, p.Pool, signupID, p.now())
	if err != nil {
		return "", nil, nil, err
	}
	if err := addressFree(ctx, p.Pool, s); err != nil {
		return "", nil, nil, err
	}
	handle, err := randBytes(userHandleBytes)
	if err != nil {
		return "", nil, nil, err
	}
	nonce, err := randBytes(keyproto.NonceSize)
	if err != nil {
		return "", nil, nil, err
	}
	creg, err := keyproto.RegisterChallenge(nonce, authorityPub)
	if err != nil {
		return "", nil, nil, err
	}
	user := passkeyUser{handle: handle, rpName: passkeyUserName}
	opts, session, err := p.WA.BeginRegistration(user, func(o *protocol.PublicKeyCredentialCreationOptions) {
		o.Challenge = protocol.URLEncodedBase64(creg[:])
	})
	if err != nil {
		return "", nil, nil, fmt.Errorf("auth: passkey: begin registration: %w", err)
	}
	id, err := newCeremonyIDN(ceremonyIDBytes)
	if err != nil {
		return "", nil, nil, err
	}
	if err := p.putCeremony(ctx, ceremony{
		ID: id, Kind: ceremonyRegister, UserHandle: handle, Session: *session, SignupID: signupID,
		AuthorityPubkey: authorityPub, RegisterNonce: nonce,
	}); err != nil {
		return "", nil, nil, err
	}
	return id, opts, nonce, nil
}

type Registered struct {
	UserID       uuid.UUID
	CredentialID []byte
	Session      Minted
}

func (p *Passkeys) FinishRegistration(ctx context.Context, ceremonyID string, response []byte) (uuid.UUID, []byte, error) {
	r, err := p.FinishRegistrationSession(ctx, ceremonyID, response, nil)
	return r.UserID, r.CredentialID, err
}

func (p *Passkeys) FinishRegistrationSession(ctx context.Context, ceremonyID string, response []byte, sessions *Sessions) (Registered, error) {
	if p.Pool == nil || p.WA == nil {
		return Registered{}, errors.New("auth: Passkeys is not configured")
	}
	c, err := p.claimCeremony(ctx, ceremonyID, ceremonyRegister)
	if err != nil {
		return Registered{}, err
	}
	user := passkeyUser{handle: c.UserHandle, rpName: passkeyUserName}
	made, err := p.createCredential(user, c, response)
	if err != nil {
		return Registered{}, err
	}
	now := p.now()
	tx, err := pgtx.BeginReadCommitted(ctx, p.Pool)
	if err != nil {
		return Registered{}, fmt.Errorf("auth: register: begin: %w", err)
	}
	defer pgtx.Rollback(ctx, tx)
	s, err := claimSignupTx(ctx, tx, c.SignupID, now)
	if err != nil {
		return Registered{}, err
	}
	if err := createAccountTx(ctx, tx, s, c.UserHandle, now); err != nil {
		return Registered{}, err
	}
	if err := insertCredential(ctx, tx, storedCredential{UserID: s.UserID, UserHandle: c.UserHandle,
		Credential: *made.Credential, AttestationSHA256: made.AttestationSHA256}, now); err != nil {
		return Registered{}, err
	}
	if _, err := tx.Exec(ctx, `UPDATE users SET authority_pubkey_pending = $2 WHERE id = $1`, s.UserID, c.AuthorityPubkey); err != nil {
		return Registered{}, fmt.Errorf("auth: register: record the pending authority key: %w", err)
	}
	out := Registered{UserID: s.UserID, CredentialID: made.Credential.ID}
	if sessions != nil {
		if out.Session, err = sessions.IssueTx(ctx, tx, Mint{UserID: s.UserID, MintedBy: MintedRegister,
			CredentialID: made.Credential.ID}); err != nil {
			return Registered{}, err
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return Registered{}, fmt.Errorf("auth: register: commit: %w", err)
	}
	return out, nil
}

func (p *Passkeys) BeginLogin(ctx context.Context) (string, *protocol.CredentialAssertion, error) {
	if p.Pool == nil || p.WA == nil {
		return "", nil, errors.New("auth: Passkeys is not configured")
	}
	opts, session, err := p.WA.BeginDiscoverableLogin()
	if err != nil {
		return "", nil, fmt.Errorf("auth: passkey: begin login: %w", err)
	}
	id, err := newCeremonyIDN(ceremonyIDBytes)
	if err != nil {
		return "", nil, err
	}
	if err := p.putCeremony(ctx, ceremony{ID: id, Kind: ceremonyLogin, Session: *session}); err != nil {
		return "", nil, err
	}
	return id, opts, nil
}

type LoginResult struct {
	UserID       uuid.UUID
	CredentialID []byte
	Challenge    []byte
}

func (p *Passkeys) FinishLogin(ctx context.Context, ceremonyID string, response []byte) (uuid.UUID, []byte, error) {
	r, err := p.FinishLoginResult(ctx, ceremonyID, response)
	return r.UserID, r.CredentialID, err
}

func (p *Passkeys) FinishLoginResult(ctx context.Context, ceremonyID string, response []byte) (LoginResult, error) {
	if p.Pool == nil || p.WA == nil {
		return LoginResult{}, errors.New("auth: Passkeys is not configured")
	}
	c, err := p.claimCeremony(ctx, ceremonyID, ceremonyLogin)
	if err != nil {
		return LoginResult{}, err
	}
	parsed, err := protocol.ParseCredentialRequestResponseBytes(response)
	if err != nil {
		return LoginResult{}, fmt.Errorf("%w: %v", ErrPasskeyRejected, err)
	}
	var stored storedCredential
	handler := func(rawID, userHandle []byte) (webauthn.User, error) {
		sc, err := p.credentialByID(ctx, p.Pool, rawID)
		if err != nil {
			return nil, err
		}
		stored = sc
		return passkeyUser{handle: sc.UserHandle, credentials: []webauthn.Credential{sc.Credential}, rpName: passkeyUserName}, nil
	}
	cred, err := p.WA.ValidateDiscoverableLogin(handler, c.Session, parsed)
	if err != nil {
		if errors.Is(err, ErrCredentialUnknown) {
			return LoginResult{}, ErrCredentialUnknown
		}
		return LoginResult{}, fmt.Errorf("%w: %v", ErrPasskeyRejected, err)
	}
	if !parsed.Response.AuthenticatorData.Flags.HasUserVerified() {
		return LoginResult{}, fmt.Errorf("%w: user verification flag is clear", ErrPasskeyRejected)
	}
	if cred.Authenticator.CloneWarning {
		return LoginResult{}, ErrClonedAuthenticator
	}
	byHandle, err := p.userIDForHandle(ctx, p.Pool, stored.UserHandle)
	if err != nil {
		return LoginResult{}, err
	}
	if byHandle != stored.UserID {
		return LoginResult{}, fmt.Errorf("%w: credential owner and user handle disagree", ErrPasskeyRejected)
	}
	if err := p.touchCredential(ctx, p.Pool, cred.ID, cred.Authenticator.SignCount, p.now().UTC()); err != nil {
		return LoginResult{}, err
	}
	challenge, err := base64.RawURLEncoding.DecodeString(c.Session.Challenge)
	if err != nil || len(challenge) != keyproto.NonceSize {
		return LoginResult{}, fmt.Errorf("auth: passkey: the login challenge is not 32 bytes")
	}
	return LoginResult{UserID: stored.UserID, CredentialID: cred.ID, Challenge: challenge}, nil
}

func (p *Passkeys) beginAdd(ctx context.Context, q dbtx, userID uuid.UUID, addNonce []byte) (string, *protocol.CredentialCreation, error) {
	if p.Pool == nil || p.WA == nil {
		return "", nil, errors.New("auth: Passkeys is not configured")
	}
	if userID == uuid.Nil {
		return "", nil, errors.New("auth: passkey: beginAdd: user id is zero")
	}
	if len(addNonce) != keyproto.NonceSize {
		return "", nil, errors.New("auth: passkey: beginAdd: the add nonce is not 32 bytes")
	}
	creds, handle, err := p.credentialsForUser(ctx, q, userID)
	if err != nil {
		return "", nil, err
	}
	if len(handle) == 0 {
		return "", nil, ErrNoPasskeyIdentity
	}
	user := passkeyUser{handle: handle, credentials: creds, rpName: passkeyUserName}
	opts, session, err := p.WA.BeginRegistration(user,
		webauthn.WithExclusions(webauthn.Credentials(creds).CredentialDescriptors()))
	if err != nil {
		return "", nil, fmt.Errorf("auth: passkey: begin add: %w", err)
	}
	id, err := newCeremonyIDN(ceremonyIDBytes)
	if err != nil {
		return "", nil, err
	}
	if err := p.putCeremonyOn(ctx, q, ceremony{
		ID: id, Kind: ceremonyAdd, UserID: &userID, UserHandle: handle, Session: *session, AddNonce: addNonce,
	}); err != nil {
		return "", nil, err
	}
	return id, opts, nil
}

func (p *Passkeys) verifyAdd(ctx context.Context, ceremonyID string, userID uuid.UUID, response []byte) (created, ceremony, error) {
	if p.Pool == nil || p.WA == nil {
		return created{}, ceremony{}, errors.New("auth: Passkeys is not configured")
	}
	c, err := p.claimCeremony(ctx, ceremonyID, ceremonyAdd)
	if err != nil {
		return created{}, ceremony{}, err
	}
	owner, err := p.userIDForHandle(ctx, p.Pool, c.UserHandle)
	if err != nil {
		return created{}, ceremony{}, err
	}
	if owner != userID || c.UserID == nil || *c.UserID != userID {
		return created{}, ceremony{}, fmt.Errorf("%w: this ceremony belongs to a different account", ErrPasskeyRejected)
	}
	user := passkeyUser{handle: c.UserHandle, rpName: passkeyUserName}
	made, err := p.createCredential(user, c, response)
	if err != nil {
		return created{}, ceremony{}, err
	}
	return made, c, nil
}

type created struct {
	Credential        *webauthn.Credential
	ClientDataJSON    []byte
	AttestationObject []byte
	AttestationSHA256 []byte
}

func (p *Passkeys) createCredential(user passkeyUser, c ceremony, response []byte) (created, error) {
	parsed, err := protocol.ParseCredentialCreationResponseBytes(response)
	if err != nil {
		return created{}, fmt.Errorf("%w: %v", ErrPasskeyRejected, err)
	}
	cred, err := p.WA.CreateCredential(user, c.Session, parsed)
	if err != nil {
		return created{}, fmt.Errorf("%w: %v", ErrPasskeyRejected, err)
	}
	if !parsed.Response.AttestationObject.AuthData.Flags.HasUserVerified() {
		return created{}, fmt.Errorf("%w: user verification flag is clear", ErrPasskeyRejected)
	}
	att := []byte(parsed.Raw.AttestationResponse.AttestationObject)
	return created{Credential: cred, ClientDataJSON: []byte(parsed.Raw.AttestationResponse.ClientDataJSON),
		AttestationObject: att, AttestationSHA256: AttestationHash(att)}, nil
}
