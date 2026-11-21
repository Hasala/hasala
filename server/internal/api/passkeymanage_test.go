package api

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/authtest"
	"github.com/salehtl/hasala/server/internal/keyproto"
)

func (k *keyed) addFinish(token string, wrap []byte) (*authtest.Authenticator, *httptest.ResponseRecorder) {
	k.h.t.Helper()
	su := k.stepUp(token, keyproto.ActionPasskeyAdd)
	id, opts := k.h.beginCreate("/api/v1/auth/passkey/add/begin", token, PasskeyAddBeginRequest{StepUp: su})
	a := authtest.New(k.h.t)
	resp := a.Create(k.h.t, opts)
	nonce, _ := base64.RawURLEncoding.DecodeString(su.Nonce)
	m, err := keyproto.PasskeyAddMessage(nonce, a.LastClientDataJSON, a.LastAttestationObject, wrap)
	if err != nil {
		k.h.t.Fatal(err)
	}
	req := PasskeyAddFinishRequest{CeremonyID: id, Credential: resp, DWKSig: b64(ed25519.Sign(k.device.DWK, m))}
	if wrap != nil {
		req.PRFWrap = &BootstrapPRFWrap{CredentialID: b64url(a.CredID), Wrap: b64(wrap), WrapVersion: 1}
	}
	return a, k.h.req("POST", "/api/v1/auth/passkey/add/finish", token, req)
}

func (k *keyed) addPasskey(token string) *authtest.Authenticator {
	k.h.t.Helper()
	a, w := k.addFinish(token, nil)
	wantStatus(k.h.t, w, http.StatusCreated)
	return a
}

func (k *keyed) deletePasskey(token string, prover *authtest.Authenticator, credID []byte) *httptest.ResponseRecorder {
	k.h.t.Helper()
	su := k.stepUpWith(token, prover, keyproto.ActionPasskeyDelete, credID)
	return k.h.req("DELETE", passkeyPath(credID), token, DeletePasskeyRequest{StepUp: su})
}

func (h *harness) listPasskeys(token string) PasskeysResponse {
	h.t.Helper()
	w := h.req("GET", "/api/v1/auth/passkeys", token, nil)
	wantStatus(h.t, w, http.StatusOK)
	return decodeJSON[PasskeysResponse](h.t, w)
}

func passkeyPath(credID []byte) string {
	return "/api/v1/auth/passkeys/" + url.QueryEscape(base64.StdEncoding.EncodeToString(credID))
}

func TestPasskeyManagementRoutesAreNotMountedWithoutARelyingParty(t *testing.T) {
	h := newHarness(t)
	for method, path := range map[string]string{
		"GET":    "/api/v1/auth/passkeys",
		"DELETE": "/api/v1/auth/passkeys/" + url.QueryEscape(b64([]byte("cred-1"))),
	} {
		w := h.req(method, path, "", nil)
		wantStatus(t, w, http.StatusNotFound)
		if got := w.Body.String(); got != `{"error":"not_found","detail":"no such endpoint"}` {
			t.Fatalf("%s %s answered %s, want the API 404 rather than an HTML fallthrough", method, path, got)
		}
	}
}

func TestPasskeyManagementRequiresASession(t *testing.T) {
	h := newHarness(t).passkeys()
	for method, path := range map[string]string{
		"GET":    "/api/v1/auth/passkeys",
		"DELETE": "/api/v1/auth/passkeys/" + url.QueryEscape(b64([]byte("cred-1"))),
	} {
		w := h.req(method, path, "", nil)
		wantStatus(t, w, http.StatusUnauthorized)
		if got := w.Body.String(); got != `{"error":"unauthorized"}` {
			t.Fatalf("%s %s answered %s", method, path, got)
		}
	}
}

func TestListPasskeysCarriesFiveFieldsAndNoKeyMaterial(t *testing.T) {
	h := newHarness(t).passkeys()
	k := h.onboard(true)
	second := k.addPasskey(k.token)

	w := h.req("GET", "/api/v1/auth/passkeys", k.token, nil)
	wantStatus(t, w, http.StatusOK)
	body := w.Body.String()

	var raw struct {
		Passkeys []map[string]json.RawMessage `json:"passkeys"`
	}
	if err := json.Unmarshal([]byte(body), &raw); err != nil {
		t.Fatalf("decode %s: %v", body, err)
	}
	if len(raw.Passkeys) != 2 {
		t.Fatalf("%d passkeys, want 2 (%s)", len(raw.Passkeys), body)
	}
	want := map[string]bool{
		"credential_id": true, "created_at": true, "last_used_at": true,
		"authenticator": true, "current": true,
	}
	for i, row := range raw.Passkeys {
		if len(row) != len(want) {
			t.Fatalf("row %d has %d fields, want exactly %d: %v", i, len(row), len(want), row)
		}
		for k := range row {
			if !want[k] {
				t.Fatalf("row %d carries an unexpected field %q — the client reads five and no more", i, k)
			}
		}
	}

	rows, err := h.pool.Query(bg,
		`SELECT public_key FROM webauthn_credentials WHERE user_id = $1`, k.user)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	keys := 0
	for rows.Next() {
		var pk []byte
		if err := rows.Scan(&pk); err != nil {
			t.Fatal(err)
		}
		keys++
		for _, enc := range []string{
			base64.StdEncoding.EncodeToString(pk),
			base64.RawURLEncoding.EncodeToString(pk),
			hex.EncodeToString(pk),
		} {
			if strings.Contains(body, enc) {
				t.Fatalf("the listing contains a credential's public key material")
			}
		}
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	if keys != 2 {
		t.Fatalf("checked %d public keys, want 2 — the fixture did not enrol what the test assumes", keys)
	}

	out := decodeJSON[PasskeysResponse](t, w)
	if out.Passkeys[1].CredentialID != base64.StdEncoding.EncodeToString(second.CredID) {
		t.Fatalf("second credential id is %q", out.Passkeys[1].CredentialID)
	}
	for i, p := range out.Passkeys {
		if p.CreatedAt.IsZero() {
			t.Fatalf("row %d has no created_at", i)
		}
		if (p.LastUsedAt == nil) != (i == 1) {
			t.Fatalf("row %d last_used_at = %v", i, p.LastUsedAt)
		}
		if p.Authenticator != nil {
			t.Fatalf("row %d named an authenticator this server cannot resolve", i)
		}
	}
	if !out.Passkeys[0].Current {
		t.Fatal("the credential that registered this session is not marked current")
	}
	if out.Passkeys[1].Current {
		t.Fatal("a credential that authenticated nothing is marked current")
	}
}

func TestTheCurrentMarkerFollowsTheCredentialTheSessionWasMintedWith(t *testing.T) {
	h := newHarness(t).passkeys()
	k := h.onboard(true)
	second := k.addPasskey(k.token)

	id, opts := h.beginAssert("/api/v1/auth/passkey/login/begin", "")
	w := h.req("POST", "/api/v1/auth/passkey/login/finish", "", PasskeyFinishRequest{
		CeremonyID: id, Credential: second.Assert(h.t, opts, k.counter.Add(1)),
	})
	wantStatus(t, w, http.StatusOK)
	onSecond := decodeJSON[SessionResponse](t, w).SessionToken

	marked := func(token string) []bool {
		var out []bool
		for _, p := range h.listPasskeys(token).Passkeys {
			out = append(out, p.Current)
		}
		return out
	}
	if got := marked(k.token); len(got) != 2 || !got[0] || got[1] {
		t.Fatalf("the registration session marks %v, want [true false]", got)
	}
	if got := marked(onSecond); len(got) != 2 || got[0] || !got[1] {
		t.Fatalf("the session signed in on the second credential marks %v, want [false true]", got)
	}

	unattributed := h.session(k.user)
	for i, p := range h.listPasskeys(unattributed).Passkeys {
		if p.Current {
			t.Fatalf("row %d is marked current for a session that records no credential", i)
		}
	}
}

func TestListPasskeysOnlyEverShowsTheCallersOwnCredentials(t *testing.T) {
	h := newHarness(t).passkeys()
	_, mine := h.register(h.invite("mine"))
	_, theirs := h.register(h.invite("theirs"))

	got := h.listPasskeys(mine.SessionToken)
	if len(got.Passkeys) != 1 {
		t.Fatalf("%d passkeys for the first account, want 1", len(got.Passkeys))
	}
	other := h.listPasskeys(theirs.SessionToken)
	if len(other.Passkeys) != 1 {
		t.Fatalf("%d passkeys for the second account, want 1", len(other.Passkeys))
	}
	if got.Passkeys[0].CredentialID == other.Passkeys[0].CredentialID {
		t.Fatal("two accounts were shown the same credential")
	}
}

func TestDeletingTheLastPasskeyIsRefusedByTheServer(t *testing.T) {
	h := newHarness(t).passkeys()
	k := h.onboard(true)

	w := k.deletePasskey(k.token, k.authn, k.authn.CredID)
	wantStatus(t, w, http.StatusConflict)
	var e struct {
		Error string `json:"error"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &e); err != nil {
		t.Fatal(err)
	}
	if e.Error != "last_authenticator" {
		t.Fatalf(`error code is %q, want "last_authenticator" — the client keys its message on it`, e.Error)
	}
	if got := h.listPasskeys(k.token); len(got.Passkeys) != 1 {
		t.Fatalf("%d passkeys survive the refusal, want 1", len(got.Passkeys))
	}
}

func TestDeletingAPasskeyRemovesItAndThenRefusesTheRemainingOne(t *testing.T) {
	h := newHarness(t).passkeys()
	k := h.onboard(true)
	first := k.authn
	second := k.addPasskey(k.token)

	wantStatus(t, h.req("DELETE", passkeyPath(second.CredID), k.token, DeletePasskeyRequest{}), http.StatusForbidden)
	wrong := k.stepUp(k.token, keyproto.ActionPasskeyDelete, first.CredID)
	wantStatus(t, h.req("DELETE", passkeyPath(second.CredID), k.token, DeletePasskeyRequest{StepUp: wrong}),
		http.StatusForbidden)
	if got := h.listPasskeys(k.token); len(got.Passkeys) != 2 {
		t.Fatalf("%d passkeys after two refused removals, want 2", len(got.Passkeys))
	}

	w := k.deletePasskey(k.token, first, second.CredID)
	wantStatus(t, w, http.StatusNoContent)
	if w.Body.Len() != 0 {
		t.Fatalf("204 carried a body: %s", w.Body.String())
	}

	got := h.listPasskeys(k.token)
	if len(got.Passkeys) != 1 ||
		got.Passkeys[0].CredentialID != base64.StdEncoding.EncodeToString(first.CredID) {
		t.Fatalf("after the removal the listing is %+v", got.Passkeys)
	}
	wantStatus(t, k.deletePasskey(k.token, first, first.CredID), http.StatusConflict)
}

func TestDeletingAPasskeyTakesItsKeyWrapWithIt(t *testing.T) {
	h := newHarness(t).passkeys()
	k := h.onboard(true)
	first := k.authn
	second, aw := k.addFinish(k.token, prfWrap(3))
	wantStatus(t, aw, http.StatusCreated)
	userID := k.user
	if n := h.countWraps(userID); n != 2 {
		t.Fatalf("%d wraps before the removal, want 2", n)
	}

	wantStatus(t, k.deletePasskey(k.token, first, second.CredID), http.StatusNoContent)

	if n := h.countWraps(userID); n != 1 {
		t.Fatalf("%d wraps after the removal, want 1 — the ON DELETE CASCADE did not fire", n)
	}
	wraps := decodeJSON[KeyWrapsResponse](t, h.req("GET", "/api/v1/keys/wraps", k.token, nil))
	if len(wraps.Wraps) != 1 || wraps.Wraps[0].CredentialID != b64url(first.CredID) {
		t.Fatalf("the surviving wrap is %+v", wraps.Wraps)
	}
}

func TestDeletingAPasskeyEndsOnlyThatPasskeysSessions(t *testing.T) {
	h := newHarness(t).passkeys()
	h.srv.PasskeyPerIP = NewLimiter(passkeyPerIPRate, 64, passkeyMaxKeys, h.srv.now)
	k := h.onboard(true)
	lost, lostSession := k.authn, k.token
	second := k.addPasskey(lostSession)
	userID := k.user

	id, opts := h.beginAssert("/api/v1/auth/passkey/login/begin", "")
	w := h.req("POST", "/api/v1/auth/passkey/login/finish", "", PasskeyFinishRequest{
		CeremonyID: id, Credential: second.Assert(t, opts, k.counter.Add(1)),
	})
	wantStatus(t, w, http.StatusOK)
	caller := decodeJSON[SessionResponse](t, w).SessionToken

	unattributed := h.session(userID)
	_, bystander := h.register(h.invite("a bystander"))

	wantStatus(t, k.deletePasskey(caller, second, lost.CredID), http.StatusNoContent)

	if w := h.req("GET", "/api/v1/auth/passkeys", lostSession, nil); w.Code != http.StatusUnauthorized {
		t.Fatalf("the removed passkey's session still works (status %d) — the lost phone is still signed in", w.Code)
	}
	if w := h.req("GET", "/api/v1/auth/passkeys", unattributed, nil); w.Code != http.StatusUnauthorized {
		t.Fatalf("a session this server cannot attribute survived (status %d); it might have been the lost phone's", w.Code)
	}
	wantStatus(t, h.req("GET", "/api/v1/auth/passkeys", caller, nil), http.StatusOK)
	wantStatus(t, h.req("GET", "/api/v1/auth/passkeys", bystander.SessionToken, nil), http.StatusOK)
}

func TestDeletingAPasskeyLeavesTheAccountsOtherDevicesSignedIn(t *testing.T) {
	h := newHarness(t).passkeys()
	k := h.onboard(true)
	first, session := k.authn, k.token
	laptopCred := k.addPasskey(session)

	id, opts := h.beginAssert("/api/v1/auth/passkey/login/begin", "")
	w := h.req("POST", "/api/v1/auth/passkey/login/finish", "", PasskeyFinishRequest{
		CeremonyID: id, Credential: laptopCred.Assert(t, opts, k.counter.Add(1)),
	})
	wantStatus(t, w, http.StatusOK)
	laptop := decodeJSON[SessionResponse](t, w).SessionToken

	wantStatus(t, k.deletePasskey(session, first, first.CredID), http.StatusNoContent)

	if w := h.req("GET", "/api/v1/auth/passkeys", laptop, nil); w.Code != http.StatusOK {
		t.Fatalf("the laptop was signed out (status %d) by a removal that had nothing to do with it", w.Code)
	}
	if w := h.req("GET", "/api/v1/auth/passkeys", session, nil); w.Code != http.StatusUnauthorized {
		t.Fatalf("the caller removed the credential its own session was minted with and is still signed in (status %d)", w.Code)
	}
}

func TestDeletingAnotherAccountsPasskeyIsRefusedAndLeavesItAlone(t *testing.T) {
	h := newHarness(t).passkeys()
	attacker := h.onboard(true)
	attacker.addPasskey(attacker.token)
	victimCred, victim := h.register(h.invite("victim"))

	w := attacker.deletePasskey(attacker.token, attacker.authn, victimCred.CredID)
	wantStatus(t, w, http.StatusNotFound)

	got := h.listPasskeys(victim.SessionToken)
	if len(got.Passkeys) != 1 ||
		got.Passkeys[0].CredentialID != base64.StdEncoding.EncodeToString(victimCred.CredID) {
		t.Fatalf("the victim's credential did not survive: %+v", got.Passkeys)
	}
	wantStatus(t, attacker.deletePasskey(attacker.token, attacker.authn, []byte("no such credential")),
		http.StatusNotFound)
}

func TestDeletingAPasskeyWhoseIdNeedsEscapingWorks(t *testing.T) {
	h := newHarness(t).passkeys()
	k := h.onboard(true)
	u, token := k.user, k.token
	awkward := []byte{0xff, 0xff, 0xff, 0xfb, 0xef, 0xbe, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b}
	if enc := base64.StdEncoding.EncodeToString(awkward); !strings.ContainsAny(enc, "+/=") {
		t.Fatalf("the fixture id %q does not exercise the escaping this test exists for", enc)
	}
	h.credential(u, awkward)

	wantStatus(t, k.deletePasskey(token, k.authn, awkward), http.StatusNoContent)
	got := h.listPasskeys(token)
	if len(got.Passkeys) != 1 || got.Passkeys[0].CredentialID != b64(k.authn.CredID) {
		t.Fatalf("the wrong credential was removed: %+v", got.Passkeys)
	}
}

func TestDeletingAPasskeyWithAMalformedIdIsABadRequest(t *testing.T) {
	h := newHarness(t).passkeys()
	_, session := h.register(h.invite("malformed"))
	w := h.req("DELETE", "/api/v1/auth/passkeys/not!base64", session.SessionToken, nil)
	wantStatus(t, w, http.StatusBadRequest)
}

func TestPasskeyManagementIsRateLimited(t *testing.T) {
	h := newHarness(t).passkeys()
	_, session := h.register(h.invite("limits"))
	for _, route := range []struct{ method, path string }{
		{"GET", "/api/v1/auth/passkeys"},
		{"DELETE", "/api/v1/auth/passkeys/" + url.QueryEscape(b64([]byte("cred-1")))},
	} {
		method, path := route.method, route.path
		h.srv.PasskeyPerIP = NewLimiter(0, 1, 16, h.srv.now)
		if w := h.req(method, path, session.SessionToken, nil); w.Code == http.StatusTooManyRequests {
			t.Fatalf("%s %s was refused on its first request", method, path)
		}
		if w := h.req(method, path, session.SessionToken, nil); w.Code != http.StatusTooManyRequests {
			t.Fatalf("%s %s answered %d on a spent budget, want 429", method, path, w.Code)
		}
	}
}

func mustUUID(t *testing.T, s string) uuid.UUID {
	t.Helper()
	u, err := uuid.Parse(s)
	if err != nil {
		t.Fatalf("user id %q is not a uuid: %v", s, err)
	}
	return u
}
