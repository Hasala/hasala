package authtest

import (
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"testing"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/cryptoref"
	"github.com/salehtl/hasala/server/internal/keyproto"
)

type Device struct {
	WriterID string
	DWK      ed25519.PrivateKey
	DAK      *ecdsa.PrivateKey
}

func NewDevice(t testing.TB) *Device {
	t.Helper()
	_, dwk, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	dak, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return &Device{WriterID: "ios-" + uuid.New().String(), DWK: dwk, DAK: dak}
}

func (d *Device) DWKPub() []byte { return d.DWK.Public().(ed25519.PublicKey) }

func (d *Device) DAKPub() []byte {
	out := []byte{4}
	out = append(out, d.DAK.X.FillBytes(make([]byte, 32))...)
	return append(out, d.DAK.Y.FillBytes(make([]byte, 32))...)
}

func (d *Device) SignDAK(t testing.TB, m []byte) []byte {
	t.Helper()
	h := sha256.Sum256(m)
	r, s, err := ecdsa.Sign(rand.Reader, d.DAK, h[:])
	if err != nil {
		t.Fatal(err)
	}
	return append(r.FillBytes(make([]byte, 32)), s.FillBytes(make([]byte, 32))...)
}

type Account struct {
	User    uuid.UUID
	E       []byte
	AMK     []byte
	AAKSeed []byte
}

func NewAccount(t testing.TB, user uuid.UUID) *Account {
	t.Helper()
	return &Account{User: user, E: RandBytesTB(t, 16), AMK: RandBytesTB(t, 32), AAKSeed: RandBytesTB(t, 32)}
}

func RandBytesTB(t testing.TB, n int) []byte {
	t.Helper()
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		t.Fatal(err)
	}
	return b
}

func (a *Account) AAK() ed25519.PrivateKey { return ed25519.NewKeyFromSeed(a.AAKSeed) }

func (a *Account) AAKPub() []byte { return cryptoref.AAKPub(a.AAKSeed) }

func (a *Account) Registration(t testing.TB, d *Device, nonce []byte) []byte {
	t.Helper()
	m, err := keyproto.RegistrationMessage(nonce, d.WriterID, d.DWKPub(), d.DAKPub())
	if err != nil {
		t.Fatal(err)
	}
	return ed25519.Sign(a.AAK(), m)
}

type Bootstrap struct {
	Payload         keyproto.BootstrapPayload
	Nonce           []byte
	AuthoritySig    []byte
	RegistrationSig []byte
}

func (a *Account) BuildBootstrap(t testing.TB, d *Device, emailNorm string, nonce []byte, authKind byte, authHash, prfCredential, prfSecret []byte) Bootstrap {
	t.Helper()
	body := cryptoref.Body(a.AMK, a.AAKSeed)
	rk := cryptoref.RKPub(a.E)
	eh := keyproto.EmailHash(emailNorm)
	p := keyproto.BootstrapPayload{
		UserID: a.User, AMKCommitment: cryptoref.AMKCommit(a.AMK, a.User), AuthorityPubkey: a.AAKPub(),
		RecoveryPubkey: rk,
		RecoveryWrap:   cryptoref.SealRecoveryWrap(a.E, RandBytesTB(t, 32), RandBytesTB(t, 12), body, a.User),
		PhraseBox:      cryptoref.SealPhraseBox(a.AMK, a.User, rk, RandBytesTB(t, 12), a.E),
		EmailHash:      eh[:], AuthKind: authKind, AuthHash: authHash,
		WriterPubkey: d.DWKPub(), WriterDAK: d.DAKPub(), WriterID: d.WriterID,
	}
	if prfCredential != nil {
		p.CredentialID = prfCredential
		p.PRFWrap = cryptoref.SealPRFWrap(prfSecret, RandBytesTB(t, 32), RandBytesTB(t, 12), body, a.User, prfCredential)
	}
	payload, err := p.Bytes()
	if err != nil {
		t.Fatal(err)
	}
	bm, err := keyproto.BootstrapMessage(nonce, payload)
	if err != nil {
		t.Fatal(err)
	}
	return Bootstrap{Payload: p, Nonce: nonce, AuthoritySig: ed25519.Sign(a.AAK(), bm), RegistrationSig: a.Registration(t, d, nonce)}
}

func AuthorityPub(t testing.TB) []byte {
	t.Helper()
	pub, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return pub
}
