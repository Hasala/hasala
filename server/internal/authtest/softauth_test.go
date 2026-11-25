package authtest

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"math/big"
	"os"
	"testing"

	"github.com/go-webauthn/webauthn/protocol"
	"github.com/go-webauthn/webauthn/protocol/webauthncose"
	"github.com/go-webauthn/webauthn/webauthn"
)

const softPasskeyFixture = "../../../conformance/swift/soft-passkey.json"

type hexBytes []byte

func (h *hexBytes) UnmarshalJSON(raw []byte) error {
	var s string
	if err := json.Unmarshal(raw, &s); err != nil {
		return err
	}
	b, err := hex.DecodeString(s)
	if err != nil {
		return err
	}
	*h = b
	return nil
}

type softPasskeyCeremony struct {
	Challenge         hexBytes `json:"challenge_hex"`
	SignCount         uint32   `json:"sign_count"`
	ClientDataJSON    hexBytes `json:"client_data_json_hex"`
	AuthenticatorData hexBytes `json:"authenticator_data_hex"`
	AttestationObject hexBytes `json:"attestation_object_hex"`
	Signature         hexBytes `json:"signature_der_hex"`
}

type softPasskeyGolden struct {
	RPID          string              `json:"rp_id"`
	Origin        string              `json:"origin"`
	PrivateScalar hexBytes            `json:"private_scalar_hex"`
	PublicKey     hexBytes            `json:"public_key_x963_hex"`
	CredentialID  hexBytes            `json:"credential_id_hex"`
	AAGUID        hexBytes            `json:"aaguid_hex"`
	UserHandle    hexBytes            `json:"user_handle_hex"`
	PRFSecret     hexBytes            `json:"prf_secret_hex"`
	PRFSalt       hexBytes            `json:"prf_salt_hex"`
	PRFOutput     hexBytes            `json:"prf_output_hex"`
	Registration  softPasskeyCeremony `json:"registration"`
	Assertion     softPasskeyCeremony `json:"assertion"`
}

func loadSoftPasskeyGolden(t *testing.T) softPasskeyGolden {
	t.Helper()
	raw, err := os.ReadFile(softPasskeyFixture)
	if err != nil {
		t.Fatal(err)
	}
	var g softPasskeyGolden
	dec := json.NewDecoder(bytes.NewReader(raw))
	if err := dec.Decode(&g); err != nil {
		t.Fatalf("%s: %v", softPasskeyFixture, err)
	}
	for name, b := range map[string][]byte{
		"private_scalar_hex": g.PrivateScalar, "public_key_x963_hex": g.PublicKey, "credential_id_hex": g.CredentialID,
		"aaguid_hex": g.AAGUID, "user_handle_hex": g.UserHandle, "prf_secret_hex": g.PRFSecret,
		"prf_salt_hex": g.PRFSalt, "prf_output_hex": g.PRFOutput,
		"registration.challenge_hex": g.Registration.Challenge, "registration.client_data_json_hex": g.Registration.ClientDataJSON,
		"registration.authenticator_data_hex": g.Registration.AuthenticatorData,
		"registration.attestation_object_hex": g.Registration.AttestationObject,
		"assertion.challenge_hex":             g.Assertion.Challenge, "assertion.client_data_json_hex": g.Assertion.ClientDataJSON,
		"assertion.authenticator_data_hex": g.Assertion.AuthenticatorData, "assertion.signature_der_hex": g.Assertion.Signature,
	} {
		if len(b) == 0 {
			t.Fatalf("%s: %s is empty", softPasskeyFixture, name)
		}
	}
	return g
}

func (g softPasskeyGolden) authenticator(t *testing.T) *Authenticator {
	t.Helper()
	d := new(big.Int).SetBytes(g.PrivateScalar)
	x, y := elliptic.P256().ScalarBaseMult(g.PrivateScalar)
	key := &ecdsa.PrivateKey{PublicKey: ecdsa.PublicKey{Curve: elliptic.P256(), X: x, Y: y}, D: d}
	pub := append([]byte{4}, append(x.FillBytes(make([]byte, 32)), y.FillBytes(make([]byte, 32))...)...)
	if !bytes.Equal(pub, g.PublicKey) {
		t.Fatalf("public key of the fixed scalar\n got %x\nwant %x", pub, g.PublicKey)
	}
	return &Authenticator{
		Origin:  g.Origin,
		Key:     key,
		CredID:  g.CredentialID,
		AAGUID:  g.AAGUID,
		Counter: g.Registration.SignCount,
	}
}

func TestSoftPasskeyBytesMatchSwift(t *testing.T) {
	g := loadSoftPasskeyGolden(t)
	a := g.authenticator(t)

	a.Create(t, &protocol.CredentialCreation{Response: protocol.PublicKeyCredentialCreationOptions{
		Challenge:    protocol.URLEncodedBase64(g.Registration.Challenge),
		RelyingParty: protocol.RelyingPartyEntity{ID: g.RPID},
		User:         protocol.UserEntity{ID: protocol.URLEncodedBase64(g.UserHandle)},
	}})
	if !bytes.Equal(a.LastAttestationObject, g.Registration.AttestationObject) {
		t.Errorf("attestation object\n   go %x\nswift %x", a.LastAttestationObject, g.Registration.AttestationObject)
	}
	if got := a.authData(t, g.RPID, g.Registration.SignCount, true); !bytes.Equal(got, g.Registration.AuthenticatorData) {
		t.Errorf("registration authenticator data\n   go %x\nswift %x", got, g.Registration.AuthenticatorData)
	}
	if !bytes.HasSuffix(g.Registration.AttestationObject, g.Registration.AuthenticatorData) {
		t.Error("the attestation object of the fixture does not end with its authenticator data")
	}

	raw := a.AssertChallenge(t, g.RPID, g.Assertion.Challenge, g.Assertion.SignCount)
	parsed, err := protocol.ParseCredentialRequestResponseBytes(raw)
	if err != nil {
		t.Fatal(err)
	}
	if got := []byte(parsed.Raw.AssertionResponse.AuthenticatorData); !bytes.Equal(got, g.Assertion.AuthenticatorData) {
		t.Errorf("assertion authenticator data\n   go %x\nswift %x", got, g.Assertion.AuthenticatorData)
	}
	if !bytes.Equal(parsed.Raw.AssertionResponse.UserHandle, g.UserHandle) {
		t.Errorf("user handle\n   go %x\nswift %x", parsed.Raw.AssertionResponse.UserHandle, g.UserHandle)
	}

	if got := PRF(g.PRFSecret, g.PRFSalt); !bytes.Equal(got, g.PRFOutput) {
		t.Errorf("PRF output\n   go %x\nswift %x", got, g.PRFOutput)
	}
}

type goldenUser struct {
	handle      []byte
	credentials []webauthn.Credential
}

func (u goldenUser) WebAuthnID() []byte                         { return u.handle }
func (u goldenUser) WebAuthnName() string                       { return "golden" }
func (u goldenUser) WebAuthnDisplayName() string                { return "golden" }
func (u goldenUser) WebAuthnCredentials() []webauthn.Credential { return u.credentials }

func TestSoftPasskeyOfSwiftVerifiesWithGoWebAuthn(t *testing.T) {
	g := loadSoftPasskeyGolden(t)
	wa, err := webauthn.New(&webauthn.Config{
		RPID:          g.RPID,
		RPDisplayName: "Hasala",
		RPOrigins:     []string{g.Origin},
		AuthenticatorSelection: protocol.AuthenticatorSelection{
			ResidentKey:      protocol.ResidentKeyRequirementRequired,
			UserVerification: protocol.VerificationRequired,
		},
		AttestationPreference: protocol.PreferNoAttestation,
	})
	if err != nil {
		t.Fatal(err)
	}
	pkc := protocol.PublicKeyCredential{
		Credential: protocol.Credential{
			ID:   base64.RawURLEncoding.EncodeToString(g.CredentialID),
			Type: "public-key",
		},
		RawID:                   protocol.URLEncodedBase64(g.CredentialID),
		AuthenticatorAttachment: "platform",
	}

	creation, err := protocol.ParseCredentialCreationResponseBytes(mustJSON(t, protocol.CredentialCreationResponse{
		PublicKeyCredential: pkc,
		AttestationResponse: protocol.AuthenticatorAttestationResponse{
			AuthenticatorResponse: protocol.AuthenticatorResponse{ClientDataJSON: protocol.URLEncodedBase64(g.Registration.ClientDataJSON)},
			AttestationObject:     protocol.URLEncodedBase64(g.Registration.AttestationObject),
			Transports:            []string{"internal", "hybrid"},
			PublicKeyAlgorithm:    int64(webauthncose.AlgES256),
		},
	}))
	if err != nil {
		t.Fatalf("go-webauthn does not parse the Swift registration: %v", err)
	}
	user := goldenUser{handle: g.UserHandle}
	_, session, err := wa.BeginRegistration(user)
	if err != nil {
		t.Fatal(err)
	}
	session.Challenge = base64.RawURLEncoding.EncodeToString(g.Registration.Challenge)
	cred, err := wa.CreateCredential(user, *session, creation)
	if err != nil {
		t.Fatalf("go-webauthn refuses the Swift registration: %v", err)
	}
	if !bytes.Equal(cred.ID, g.CredentialID) {
		t.Errorf("credential id\n got %x\nwant %x", cred.ID, g.CredentialID)
	}
	if !bytes.Equal(cred.Authenticator.AAGUID, g.AAGUID) {
		t.Errorf("AAGUID\n got %x\nwant %x", cred.Authenticator.AAGUID, g.AAGUID)
	}
	if cred.Authenticator.SignCount != g.Registration.SignCount {
		t.Errorf("registration sign count = %d, want %d", cred.Authenticator.SignCount, g.Registration.SignCount)
	}
	if !cred.Flags.UserPresent || !cred.Flags.UserVerified || !cred.Flags.BackupEligible || !cred.Flags.BackupState {
		t.Errorf("flags = %+v, want UP, UV, BE and BS", cred.Flags)
	}

	assertion, err := protocol.ParseCredentialRequestResponseBytes(mustJSON(t, protocol.CredentialAssertionResponse{
		PublicKeyCredential: pkc,
		AssertionResponse: protocol.AuthenticatorAssertionResponse{
			AuthenticatorResponse: protocol.AuthenticatorResponse{ClientDataJSON: protocol.URLEncodedBase64(g.Assertion.ClientDataJSON)},
			AuthenticatorData:     protocol.URLEncodedBase64(g.Assertion.AuthenticatorData),
			Signature:             protocol.URLEncodedBase64(g.Assertion.Signature),
			UserHandle:            protocol.URLEncodedBase64(g.UserHandle),
		},
	}))
	if err != nil {
		t.Fatalf("go-webauthn does not parse the Swift assertion: %v", err)
	}
	user.credentials = []webauthn.Credential{*cred}
	after, err := wa.ValidateLogin(user, webauthn.SessionData{
		Challenge:            base64.RawURLEncoding.EncodeToString(g.Assertion.Challenge),
		RelyingPartyID:       g.RPID,
		UserID:               g.UserHandle,
		AllowedCredentialIDs: [][]byte{g.CredentialID},
		UserVerification:     protocol.VerificationRequired,
	}, assertion)
	if err != nil {
		t.Fatalf("go-webauthn refuses the Swift assertion: %v", err)
	}
	if after.Authenticator.CloneWarning {
		t.Error("the Swift assertion sets the clone warning")
	}
	if after.Authenticator.SignCount != g.Assertion.SignCount {
		t.Errorf("assertion sign count = %d, want %d", after.Authenticator.SignCount, g.Assertion.SignCount)
	}
	if !assertion.Response.AuthenticatorData.Flags.HasUserVerified() {
		t.Error("the Swift assertion does not set user verification")
	}
}
