package authtest

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"testing"

	"github.com/go-webauthn/webauthn/protocol"
	"github.com/go-webauthn/webauthn/protocol/webauthncbor"
	"github.com/go-webauthn/webauthn/protocol/webauthncose"
)

const (
	RPID          = "ledger.example"
	RPOrigin      = "https://ledger.example"
	RPDisplayName = "Ledger"
)

const (
	flagUserPresent    = 0x01
	flagUserVerified   = 0x04
	flagBackupEligible = 0x08
	flagBackupState    = 0x10
	flagAttestedData   = 0x40
)

type Authenticator struct {
	Origin string

	Key                   *ecdsa.PrivateKey
	CredID                []byte
	Handle                []byte
	AAGUID                []byte
	Counter               uint32
	NoUV                  bool
	LastAttestationObject []byte
	LastClientDataJSON    []byte
}

func New(t *testing.T) *Authenticator {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return &Authenticator{
		Origin:  RPOrigin,
		Key:     key,
		CredID:  RandBytes(t, 20),
		AAGUID:  RandBytes(t, 16),
		Counter: 1,
	}
}

func PRF(secret, salt []byte) []byte {
	input := sha256.Sum256(append(append([]byte("WebAuthn PRF"), 0), salt...))
	mac := hmac.New(sha256.New, secret)
	mac.Write(input[:])
	return mac.Sum(nil)
}

func RandBytes(t *testing.T, n int) []byte {
	t.Helper()
	return RandBytesTB(t, n)
}

func (a *Authenticator) coseKey(t *testing.T) []byte {
	t.Helper()
	pk := webauthncose.EC2PublicKeyData{
		PublicKeyData: webauthncose.PublicKeyData{
			KeyType:   2,
			Algorithm: int64(webauthncose.AlgES256),
		},
		Curve:  1,
		XCoord: a.Key.PublicKey.X.FillBytes(make([]byte, 32)),
		YCoord: a.Key.PublicKey.Y.FillBytes(make([]byte, 32)),
	}
	raw, err := webauthncbor.Marshal(pk)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func (a *Authenticator) authData(t *testing.T, rpID string, counter uint32, attested bool) []byte {
	t.Helper()
	h := sha256.Sum256([]byte(rpID))
	out := append([]byte{}, h[:]...)
	flags := byte(flagUserPresent | flagUserVerified | flagBackupEligible | flagBackupState)
	if a.NoUV {
		flags &^= flagUserVerified
	}
	if attested {
		flags |= flagAttestedData
	}
	out = append(out, flags)
	out = binary.BigEndian.AppendUint32(out, counter)
	if attested {
		out = append(out, a.AAGUID...)
		out = binary.BigEndian.AppendUint16(out, uint16(len(a.CredID)))
		out = append(out, a.CredID...)
		out = append(out, a.coseKey(t)...)
	}
	return out
}

func (a *Authenticator) clientData(t *testing.T, typ string, challenge protocol.URLEncodedBase64) []byte {
	t.Helper()
	raw, err := json.Marshal(map[string]any{
		"type":        typ,
		"challenge":   challenge.String(),
		"origin":      a.Origin,
		"crossOrigin": false,
	})
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func (a *Authenticator) Create(t *testing.T, opts *protocol.CredentialCreation) []byte {
	t.Helper()
	switch id := opts.Response.User.ID.(type) {
	case protocol.URLEncodedBase64:
		a.Handle = []byte(id)
	case []byte:
		a.Handle = id
	case string:
		raw, err := base64.RawURLEncoding.DecodeString(id)
		if err != nil {
			t.Fatalf("user id %q is not base64url: %v", id, err)
		}
		a.Handle = raw
	default:
		t.Fatalf("registration options carry a user id of type %T, want raw bytes", opts.Response.User.ID)
	}
	cd := a.clientData(t, "webauthn.create", opts.Response.Challenge)
	att := struct {
		AuthData []byte         `cbor:"authData"`
		Fmt      string         `cbor:"fmt"`
		AttStmt  map[string]any `cbor:"attStmt"`
	}{
		AuthData: a.authData(t, opts.Response.RelyingParty.ID, a.Counter, true),
		Fmt:      "none",
		AttStmt:  map[string]any{},
	}
	obj, err := webauthncbor.Marshal(att)
	if err != nil {
		t.Fatal(err)
	}
	a.LastAttestationObject = obj
	a.LastClientDataJSON = cd
	resp := protocol.CredentialCreationResponse{
		PublicKeyCredential: a.publicKeyCredential(),
		AttestationResponse: protocol.AuthenticatorAttestationResponse{
			AuthenticatorResponse: protocol.AuthenticatorResponse{ClientDataJSON: cd},
			AttestationObject:     obj,
			Transports:            []string{"internal", "hybrid"},
			PublicKeyAlgorithm:    int64(webauthncose.AlgES256),
		},
	}
	return mustJSON(t, resp)
}

func (a *Authenticator) Assert(t *testing.T, opts *protocol.CredentialAssertion, counter uint32) []byte {
	t.Helper()
	cd := a.clientData(t, "webauthn.get", opts.Response.Challenge)
	ad := a.authData(t, opts.Response.RelyingPartyID, counter, false)
	cdHash := sha256.Sum256(cd)
	digest := sha256.Sum256(append(append([]byte{}, ad...), cdHash[:]...))
	sig, err := ecdsa.SignASN1(rand.Reader, a.Key, digest[:])
	if err != nil {
		t.Fatal(err)
	}
	resp := protocol.CredentialAssertionResponse{
		PublicKeyCredential: a.publicKeyCredential(),
		AssertionResponse: protocol.AuthenticatorAssertionResponse{
			AuthenticatorResponse: protocol.AuthenticatorResponse{ClientDataJSON: cd},
			AuthenticatorData:     ad,
			Signature:             sig,
			UserHandle:            a.Handle,
		},
	}
	return mustJSON(t, resp)
}

func (a *Authenticator) AssertChallenge(t *testing.T, rpID string, challenge []byte, counter uint32) []byte {
	t.Helper()
	opts := &protocol.CredentialAssertion{Response: protocol.PublicKeyCredentialRequestOptions{
		Challenge: protocol.URLEncodedBase64(challenge), RelyingPartyID: rpID,
	}}
	return a.Assert(t, opts, counter)
}

func (a *Authenticator) publicKeyCredential() protocol.PublicKeyCredential {
	return protocol.PublicKeyCredential{
		Credential: protocol.Credential{
			ID:   base64.RawURLEncoding.EncodeToString(a.CredID),
			Type: "public-key",
		},
		RawID:                   a.CredID,
		AuthenticatorAttachment: "platform",
	}
}

func mustJSON(t *testing.T, v any) []byte {
	t.Helper()
	raw, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}
