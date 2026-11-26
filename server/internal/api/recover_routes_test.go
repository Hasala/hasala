package api

import (
	"crypto/ed25519"
	"encoding/base64"
	"net/http"
	"strings"
	"testing"

	"github.com/salehtl/hasala/server/internal/authtest"
	"github.com/salehtl/hasala/server/internal/cryptoref"
	"github.com/salehtl/hasala/server/internal/keyproto"
)

func TestPasswordRecoveryOverHTTPAnswersTheAddressAtVerifyNotAtBegin(t *testing.T) {
	t.Parallel()
	h := newHarness(t)
	keys, fake, _ := h.accounts()
	a := h.passwordSignup(keys, fake, "maya@example.com")

	w := h.req("POST", "/api/v1/auth/recover/begin", "", RecoverBeginRequest{RecoveryPubkey: b64(cryptoref.RKPub(a.acct.E))})
	wantStatus(t, w, http.StatusOK)
	if strings.Contains(w.Body.String(), a.addr) || strings.Contains(w.Body.String(), "email_norm") {
		t.Fatalf("recover/begin answered the address: %s", w.Body.String())
	}
	begun := decodeJSON[RecoverBeginResponse](t, w)
	if begun.EmailHint != "m•••@e•••.com" {
		t.Fatalf("hint %q", begun.EmailHint)
	}

	w = h.req("POST", "/api/v1/auth/recover/verify", "", RecoverVerifyRequest{CeremonyID: begun.CeremonyID,
		Code: lastCodeTo(t, fake, a.addr), Kind: "password"})
	wantStatus(t, w, http.StatusOK)
	v := decodeJSON[RecoverVerifyResponse](t, w)
	if v.EmailNorm != a.addr || v.Salt != b64(keys.PasswordSalt(a.addr)) || v.Options != nil || v.UserID != a.user {
		t.Fatalf("recover/verify answered %+v", v)
	}

	salt, _ := base64.StdEncoding.DecodeString(v.Salt)
	nonce, _ := base64.StdEncoding.DecodeString(v.Nonce)
	newS := authtest.Stretch("a new password after recovery", salt, v.EmailNorm)
	d := authtest.NewDevice(t)
	msg, err := keyproto.RecoverySigninPassword(nonce, newS)
	if err != nil {
		t.Fatal(err)
	}
	w = h.req("POST", "/api/v1/auth/recover/finish", "", RecoverFinishRequest{CeremonyID: begun.CeremonyID, Kind: "password",
		Verifier: b64(newS), RKSig: b64(ed25519.Sign(cryptoref.RK(a.acct.E), msg)),
		Writer: RecoverWriterWire{WriterID: d.WriterID, Alg: "ed25519", PubKey: b64(d.DWKPub()), DAKPubkey: b64(d.DAKPub()),
			RegistrationSig: b64(a.acct.Registration(t, d, nonce))}})
	wantStatus(t, w, http.StatusCreated)
	if out := decodeJSON[WriterSessionResponse](t, w); out.WriterID != d.WriterID || out.UserID != a.user {
		t.Fatalf("recover/finish answered %+v", out)
	}
	wantStatus(t, h.req("GET", "/api/v1/account", a.token, nil), http.StatusUnauthorized)
	wantStatus(t, h.passwordLogin(a, newS), http.StatusOK)
	if w := h.passwordLogin(a, a.s); w.Code == http.StatusOK {
		t.Fatal("the old password still signs in after the recovery")
	}
}
