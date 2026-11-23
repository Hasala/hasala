package auth

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"

	"github.com/go-webauthn/webauthn/protocol"
	"github.com/go-webauthn/webauthn/webauthn"
	"github.com/google/uuid"
)

func (p *Passkeys) VerifyAssertion(ctx context.Context, userID uuid.UUID, challenge, response []byte) error {
	_, err := p.VerifyAssertionCredential(ctx, userID, challenge, response)
	return err
}

func (p *Passkeys) VerifyAssertionCredential(ctx context.Context, userID uuid.UUID, challenge, response []byte) ([]byte, error) {
	if p == nil || p.Pool == nil {
		return nil, errors.New("auth: Passkeys is not configured")
	}
	return p.VerifyAssertionCredentialTx(ctx, p.Pool, userID, challenge, response)
}

func (p *Passkeys) VerifyAssertionCredentialTx(ctx context.Context, q dbtx, userID uuid.UUID, challenge, response []byte) ([]byte, error) {
	if p == nil || p.WA == nil || q == nil {
		return nil, errors.New("auth: Passkeys is not configured")
	}
	if userID == uuid.Nil {
		return nil, fmt.Errorf("%w: user id is zero", ErrPasskeyRejected)
	}
	if len(challenge) < 16 {
		return nil, fmt.Errorf("%w: challenge is %d bytes, too short to be one of ours", ErrPasskeyRejected, len(challenge))
	}
	if len(response) == 0 {
		return nil, fmt.Errorf("%w: no assertion presented", ErrPasskeyRejected)
	}
	parsed, err := protocol.ParseCredentialRequestResponseBytes(response)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrPasskeyRejected, err)
	}

	stored, err := p.credentialByID(ctx, q, parsed.RawID)
	if err != nil {
		return nil, err
	}
	if stored.UserID != userID {
		return nil, fmt.Errorf("%w: credential belongs to a different account", ErrPasskeyRejected)
	}
	byHandle, err := p.userIDForHandle(ctx, q, stored.UserHandle)
	if err != nil {
		return nil, err
	}
	if byHandle != stored.UserID {
		return nil, fmt.Errorf("%w: credential owner and user handle disagree", ErrPasskeyRejected)
	}

	session := webauthn.SessionData{
		Challenge:            base64.RawURLEncoding.EncodeToString(challenge),
		RelyingPartyID:       p.WA.Config.RPID,
		UserID:               stored.UserHandle,
		AllowedCredentialIDs: [][]byte{stored.Credential.ID},
		UserVerification:     p.WA.Config.AuthenticatorSelection.UserVerification,
	}
	user := passkeyUser{
		handle:      stored.UserHandle,
		credentials: []webauthn.Credential{stored.Credential},
		rpName:      p.WA.Config.RPDisplayName,
	}
	cred, err := p.WA.ValidateLogin(user, session, parsed)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrPasskeyRejected, err)
	}
	if cred.Authenticator.CloneWarning {
		return nil, ErrClonedAuthenticator
	}
	if !parsed.Response.AuthenticatorData.Flags.HasUserVerified() {
		return nil, fmt.Errorf("%w: user verification flag is clear", ErrPasskeyRejected)
	}
	if err := p.touchCredential(ctx, q, cred.ID, cred.Authenticator.SignCount, p.now().UTC()); err != nil {
		return nil, err
	}
	return cred.ID, nil
}
