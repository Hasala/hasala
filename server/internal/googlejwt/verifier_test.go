package googlejwt

import (
	"context"
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/hmac"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"
)

const (
	testIssuer      = "https://idp.test"
	testOtherIssuer = "https://other-idp.test"
	testAudience    = "test.ledger.app"
	testSubject     = "001234.abcdef0123456789.0001"
)

var bgctx = context.Background()

type testKey struct {
	kid string
	alg string
	use string
	rsa *rsa.PrivateKey
	ec  *ecdsa.PrivateKey
}

type keyBundle struct {
	rsa1 *testKey
	rsa2 *testKey
	ec1  *testKey
}

var testKeys = sync.OnceValue(func() *keyBundle {
	return &keyBundle{
		rsa1: mustRSAKey("rsa-1"),
		rsa2: mustRSAKey("rsa-2"),
		ec1:  mustECKey("ec-1"),
	}
})

func mustRSAKey(kid string) *testKey {
	k, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		panic(err)
	}
	return &testKey{kid: kid, alg: "RS256", use: "sig", rsa: k}
}

func mustECKey(kid string) *testKey {
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		panic(err)
	}
	return &testKey{kid: kid, alg: "ES256", use: "sig", ec: k}
}

func (k *testKey) withUse(use string) *testKey {
	c := *k
	c.use = use
	return &c
}

func (k *testKey) withKID(kid string) *testKey {
	c := *k
	c.kid = kid
	return &c
}

func b64(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

func (k *testKey) jwk() map[string]any {
	var out map[string]any
	if k.rsa != nil {
		out = map[string]any{
			"kty": "RSA",
			"alg": "RS256",
			"kid": k.kid,
			"n":   b64(k.rsa.PublicKey.N.Bytes()),
			"e":   b64(big.NewInt(int64(k.rsa.PublicKey.E)).Bytes()),
		}
	} else {
		out = map[string]any{
			"kty": "EC",
			"alg": "ES256",
			"crv": "P-256",
			"kid": k.kid,
			"x":   b64(pad32(k.ec.PublicKey.X)),
			"y":   b64(pad32(k.ec.PublicKey.Y)),
		}
	}
	if k.use != "" {
		out["use"] = k.use
	}
	return out
}

func pad32(i *big.Int) []byte {
	out := make([]byte, 32)
	i.FillBytes(out)
	return out
}

func (k *testKey) sign(t *testing.T, input []byte) []byte {
	t.Helper()
	sum := sha256.Sum256(input)
	if k.rsa != nil {
		sig, err := rsa.SignPKCS1v15(rand.Reader, k.rsa, crypto.SHA256, sum[:])
		if err != nil {
			t.Fatal(err)
		}
		return sig
	}
	r, s, err := ecdsa.Sign(rand.Reader, k.ec, sum[:])
	if err != nil {
		t.Fatal(err)
	}
	return append(pad32(r), pad32(s)...)
}

type jwksServer struct {
	srv     *httptest.Server
	mu      sync.Mutex
	keys    []*testKey
	hits    int
	failing bool
	entered chan struct{}
	release chan struct{}
}

func newJWKS(t *testing.T, keys ...*testKey) *jwksServer {
	t.Helper()
	j := &jwksServer{keys: keys}
	j.srv = httptest.NewServer(http.HandlerFunc(j.serve))
	t.Cleanup(j.srv.Close)
	return j
}

func (j *jwksServer) serve(w http.ResponseWriter, _ *http.Request) {
	j.mu.Lock()
	j.hits++
	entered, release := j.entered, j.release
	j.entered, j.release = nil, nil
	failing := j.failing
	out := make([]map[string]any, 0, len(j.keys))
	for _, k := range j.keys {
		out = append(out, k.jwk())
	}
	j.mu.Unlock()
	if entered != nil {
		close(entered)
		<-release
	}
	if failing {
		http.Error(w, "unavailable", http.StatusServiceUnavailable)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"keys": out})
}

func (j *jwksServer) url() string { return j.srv.URL }

func (j *jwksServer) gate() (entered <-chan struct{}, release chan<- struct{}) {
	e, r := make(chan struct{}), make(chan struct{})
	j.mu.Lock()
	j.entered, j.release = e, r
	j.mu.Unlock()
	return e, r
}

func (j *jwksServer) fail(v bool) {
	j.mu.Lock()
	j.failing = v
	j.mu.Unlock()
}

func (j *jwksServer) rotate(keys ...*testKey) {
	j.mu.Lock()
	j.keys = keys
	j.mu.Unlock()
}

func (j *jwksServer) hitCount() int {
	j.mu.Lock()
	defer j.mu.Unlock()
	return j.hits
}

type clock struct {
	mu sync.Mutex
	t  time.Time
}

func newClock() *clock {
	return &clock{t: time.Date(2026, 8, 1, 12, 0, 0, 0, time.UTC)}
}

func (c *clock) now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.t
}

func (c *clock) advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.t = c.t.Add(d)
}

func goodClaims(now time.Time, over map[string]any) map[string]any {
	c := map[string]any{
		"iss": testIssuer,
		"sub": testSubject,
		"aud": testAudience,
		"iat": now.Unix(),
		"exp": now.Add(time.Hour).Unix(),
	}
	for k, v := range over {
		if v == nil {
			delete(c, k)
			continue
		}
		c[k] = v
	}
	return c
}

func seg(t *testing.T, v any) string {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return b64(b)
}

func mintRaw(t *testing.T, hdr, claims map[string]any, sign func([]byte) []byte) string {
	t.Helper()
	input := seg(t, hdr) + "." + seg(t, claims)
	var sig []byte
	if sign != nil {
		sig = sign([]byte(input))
	}
	return input + "." + b64(sig)
}

func mint(t *testing.T, k *testKey, hdrOver, claims map[string]any) string {
	t.Helper()
	hdr := map[string]any{"alg": k.alg, "typ": "JWT", "kid": k.kid}
	for key, v := range hdrOver {
		if v == nil {
			delete(hdr, key)
			continue
		}
		hdr[key] = v
	}
	return mintRaw(t, hdr, claims, func(in []byte) []byte { return k.sign(t, in) })
}

func verifierOn(j *jwksServer, c *clock) *Verifier {
	return &Verifier{Issuers: []string{testIssuer}, Audience: testAudience, JWKSURL: j.url(), Now: c.now}
}

func mustReject(t *testing.T, v *Verifier, token string, want error) {
	t.Helper()
	got, err := v.Verify(bgctx, token)
	if err == nil {
		t.Fatalf("token was ACCEPTED as %+v; want rejection with %v", got, want)
	}
	if !errors.Is(err, want) {
		t.Fatalf("rejected with %v; want an error matching %v", err, want)
	}
	if !errors.Is(err, ErrTokenRejected) {
		t.Fatalf("rejection %v does not wrap ErrTokenRejected", err)
	}
	if !reflect.DeepEqual(got, Claims{}) {
		t.Fatalf("a rejected token still yielded claims %+v", got)
	}
}

func TestVerifierAcceptsAGoodRS256Token(t *testing.T) {
	k := testKeys()
	j := newJWKS(t, k.rsa1)
	c := newClock()
	v := verifierOn(j, c)

	id, err := v.Verify(bgctx, mint(t, k.rsa1, nil, goodClaims(c.now(), nil)))
	if err != nil {
		t.Fatalf("verify: %v", err)
	}
	if id.Sub != testSubject || id.Iss != testIssuer || len(id.Aud) != 1 || id.Aud[0] != testAudience {
		t.Fatalf("claims = %+v, want sub %s from %s for %s", id, testSubject, testIssuer, testAudience)
	}
	if !id.Iat.Equal(c.now()) || !id.Exp.Equal(c.now().Add(time.Hour)) {
		t.Fatalf("iat/exp = %s/%s", id.Iat, id.Exp)
	}
}

func TestVerifierReturnsTheLinkClaimsFromTheVerifiedPayload(t *testing.T) {
	k := testKeys()
	j := newJWKS(t, k.rsa1)
	c := newClock()
	v := verifierOn(j, c)
	for _, tc := range []struct {
		raw  any
		want bool
	}{{true, true}, {"true", true}, {false, false}, {"false", false}, {"yes", false}, {nil, false}} {
		claims := goodClaims(c.now(), map[string]any{"azp": "ios.client", "email": "someone@example.com", "nonce": "n-1"})
		if tc.raw != nil {
			claims["email_verified"] = tc.raw
		}
		id, err := v.Verify(bgctx, mint(t, k.rsa1, nil, claims))
		if err != nil {
			t.Fatalf("email_verified=%v: %v", tc.raw, err)
		}
		if id.Azp != "ios.client" || id.Email != "someone@example.com" || id.Nonce != "n-1" || id.EmailVerified != tc.want {
			t.Fatalf("email_verified=%v: claims = %+v, want verified %v", tc.raw, id, tc.want)
		}
	}
}

func TestVerifierRefusesES256(t *testing.T) {
	k := testKeys()
	j := newJWKS(t, k.ec1)
	c := newClock()
	v := verifierOn(j, c)

	mustReject(t, v, mint(t, k.ec1, nil, goodClaims(c.now(), nil)), ErrAlgorithm)
	if j.hitCount() != 0 {
		t.Fatalf("an ES256 token caused %d JWKS fetches", j.hitCount())
	}
}

func TestVerifierAcceptsAnAudienceArrayContainingOurs(t *testing.T) {
	k := testKeys()
	j := newJWKS(t, k.rsa1)
	c := newClock()
	v := verifierOn(j, c)

	tok := mint(t, k.rsa1, nil, goodClaims(c.now(), map[string]any{
		"aud": []string{"someone.elses.app", testAudience},
	}))
	if _, err := v.Verify(bgctx, tok); err != nil {
		t.Fatalf("multi-audience token rejected: %v", err)
	}
}

func TestVerifierRejectsAlgNone(t *testing.T) {
	k := testKeys()
	j := newJWKS(t, k.rsa1)
	c := newClock()
	v := verifierOn(j, c)

	tok := mintRaw(t,
		map[string]any{"alg": "none", "typ": "JWT"},
		goodClaims(c.now(), nil), nil)
	mustReject(t, v, tok, ErrAlgorithm)

	if _, err := v.inner.Verify(bgctx, tok); err == nil {
		t.Fatal("go-oidc accepted an alg:none token")
	}
}

func TestVerifierRejectsHS256SignedWithTheJWKSModulus(t *testing.T) {
	k := testKeys()
	j := newJWKS(t, k.rsa1)
	c := newClock()
	v := verifierOn(j, c)

	secret := k.rsa1.rsa.PublicKey.N.Bytes()
	tok := mintRaw(t,
		map[string]any{"alg": "HS256", "typ": "JWT", "kid": k.rsa1.kid},
		goodClaims(c.now(), map[string]any{"sub": "attacker"}),
		func(in []byte) []byte {
			mac := hmac.New(sha256.New, secret)
			mac.Write(in)
			return mac.Sum(nil)
		})
	mustReject(t, v, tok, ErrAlgorithm)

	if _, err := v.inner.Verify(bgctx, tok); err == nil {
		t.Fatal("go-oidc accepted an HS256 token")
	}
}

func TestVerifierRejectsAnEmbeddedJWKHeader(t *testing.T) {
	k := testKeys()
	j := newJWKS(t, k.rsa1)
	c := newClock()
	v := verifierOn(j, c)

	claims := goodClaims(c.now(), map[string]any{"sub": "attacker"})
	tok := mint(t, k.rsa2, map[string]any{"jwk": k.rsa2.jwk()}, claims)
	mustReject(t, v, tok, ErrUntrustedHeader)

	mustReject(t, v, mint(t, k.rsa2, nil, claims), ErrSignature)

	rest := map[string]any{
		"jku":  "https://evil.test/keys",
		"x5u":  "https://evil.test/chain.pem",
		"x5c":  []string{"MIIB..."},
		"crit": []string{"exp"},
	}
	if len(rest)+1 != len(forbiddenHeaders) {
		t.Fatalf("forbiddenHeaders has %d entries but this test covers %d", len(forbiddenHeaders), len(rest)+1)
	}
	for hdr, val := range rest {
		t.Run(hdr, func(t *testing.T) {
			mustReject(t, v, mint(t, k.rsa1, map[string]any{hdr: val}, claims), ErrUntrustedHeader)
		})
	}
}

func TestVerifierRejectsAKeyNotInTheJWKS(t *testing.T) {
	k := testKeys()
	j := newJWKS(t, k.rsa1)
	c := newClock()
	v := verifierOn(j, c)

	mustReject(t, v, mint(t, k.rsa2, nil, goodClaims(c.now(), nil)), ErrSignature)
}

func TestVerifierRejectsAMismatchedKid(t *testing.T) {
	k := testKeys()
	j := newJWKS(t, k.rsa1, k.ec1)
	c := newClock()
	v := verifierOn(j, c)

	t.Run("unknown kid", func(t *testing.T) {
		tok := mint(t, k.rsa1, map[string]any{"kid": "no-such-key"}, goodClaims(c.now(), nil))
		mustReject(t, v, tok, ErrSignature)
	})
	t.Run("kid of another enrolled key", func(t *testing.T) {
		tok := mint(t, k.rsa1, map[string]any{"kid": k.ec1.kid}, goodClaims(c.now(), nil))
		mustReject(t, v, tok, ErrSignature)
	})
}

func TestGoogleVerifierAcceptsBothDocumentedIssuerForms(t *testing.T) {
	k := testKeys()
	j := newJWKS(t, k.rsa1)
	c := newClock()
	v := &Verifier{Audience: testAudience, JWKSURL: j.url(), Now: c.now}

	for _, iss := range []string{GoogleIssuer, GoogleIssuerNoScheme} {
		t.Run(iss, func(t *testing.T) {
			tok := mint(t, k.rsa1, nil, goodClaims(c.now(), map[string]any{"iss": iss}))
			id, err := v.Verify(bgctx, tok)
			if err != nil {
				t.Fatalf("google issuer %q rejected: %v", iss, err)
			}
			if id.Iss != iss {
				t.Fatalf("iss = %q", id.Iss)
			}
		})
	}
	mustReject(t, v, mint(t, k.rsa1, nil, goodClaims(c.now(), map[string]any{"iss": "https://accounts.google.com.evil.test"})), ErrIssuer)
}

func TestVerifierRejectsWrongIssuer(t *testing.T) {
	k := testKeys()
	j := newJWKS(t, k.rsa1)
	c := newClock()
	v := verifierOn(j, c)

	tok := mint(t, k.rsa1, nil, goodClaims(c.now(), map[string]any{"iss": "https://evil.test"}))
	mustReject(t, v, tok, ErrIssuer)

	if j.hitCount() != 0 {
		t.Fatalf("wrong-issuer rejection fetched the JWKS %d time(s)", j.hitCount())
	}
}

func TestVerifierRejectsWrongAudience(t *testing.T) {
	k := testKeys()
	j := newJWKS(t, k.rsa1)
	c := newClock()
	v := verifierOn(j, c)

	t.Run("bare string", func(t *testing.T) {
		tok := mint(t, k.rsa1, nil, goodClaims(c.now(), map[string]any{"aud": "someone.elses.app"}))
		mustReject(t, v, tok, ErrAudience)
	})
	t.Run("array with no member of ours", func(t *testing.T) {
		tok := mint(t, k.rsa1, nil, goodClaims(c.now(),
			map[string]any{"aud": []string{"a.app", "b.app"}}))
		mustReject(t, v, tok, ErrAudience)
	})
	t.Run("absent", func(t *testing.T) {
		tok := mint(t, k.rsa1, nil, goodClaims(c.now(), map[string]any{"aud": nil}))
		mustReject(t, v, tok, ErrAudience)
	})
	t.Run("empty string", func(t *testing.T) {
		tok := mint(t, k.rsa1, nil, goodClaims(c.now(), map[string]any{"aud": ""}))
		mustReject(t, v, tok, ErrAudience)
	})
}

func TestVerifierRejectsExpiredAndNotYetValid(t *testing.T) {
	k := testKeys()
	j := newJWKS(t, k.rsa1)
	c := newClock()
	v := verifierOn(j, c)

	t.Run("expired", func(t *testing.T) {
		tok := mint(t, k.rsa1, nil, goodClaims(c.now(),
			map[string]any{"exp": c.now().Add(-time.Second).Unix()}))
		mustReject(t, v, tok, ErrExpired)
	})
	t.Run("expires while held", func(t *testing.T) {
		tok := mint(t, k.rsa1, nil, goodClaims(c.now(), nil))
		if _, err := v.Verify(bgctx, tok); err != nil {
			t.Fatalf("token should be good now: %v", err)
		}
		c.advance(2 * time.Hour)
		defer c.advance(-2 * time.Hour)
		mustReject(t, v, tok, ErrExpired)
	})
	t.Run("no exp claim at all", func(t *testing.T) {
		tok := mint(t, k.rsa1, nil, goodClaims(c.now(), map[string]any{"exp": nil}))
		mustReject(t, v, tok, ErrExpired)
	})
	t.Run("not yet valid", func(t *testing.T) {
		tok := mint(t, k.rsa1, nil, goodClaims(c.now(),
			map[string]any{"nbf": c.now().Add(30 * time.Minute).Unix()}))
		mustReject(t, v, tok, ErrNotYetValid)
	})
	t.Run("nbf inside the skew leeway is accepted", func(t *testing.T) {
		tok := mint(t, k.rsa1, nil, goodClaims(c.now(),
			map[string]any{"nbf": c.now().Add(time.Minute).Unix()}))
		if _, err := v.Verify(bgctx, tok); err != nil {
			t.Fatalf("nbf 1m ahead should be tolerated as clock skew: %v", err)
		}
	})
}

func TestVerifierRejectsAMissingSubject(t *testing.T) {
	k := testKeys()
	j := newJWKS(t, k.rsa1)
	c := newClock()
	v := verifierOn(j, c)

	for _, sub := range []any{nil, ""} {
		tok := mint(t, k.rsa1, nil, goodClaims(c.now(), map[string]any{"sub": sub}))
		mustReject(t, v, tok, ErrNoSubject)
	}
}

func TestVerifierRejectsMalformedTokens(t *testing.T) {
	k := testKeys()
	j := newJWKS(t, k.rsa1)
	c := newClock()
	v := verifierOn(j, c)
	good := mint(t, k.rsa1, nil, goodClaims(c.now(), nil))
	parts := strings.Split(good, ".")

	cases := map[string]string{
		"empty":             "",
		"not a jwt":         "hello",
		"two segments":      parts[0] + "." + parts[1],
		"four segments":     good + "." + parts[2],
		"bad base64 header": "!!!." + parts[1] + "." + parts[2],
		"bad base64 body":   parts[0] + ".!!!." + parts[2],
		"header not json":   b64([]byte("nope")) + "." + parts[1] + "." + parts[2],
		"body not json":     parts[0] + "." + b64([]byte("nope")) + "." + parts[2],
	}
	oversized := mint(t, k.rsa1, nil, goodClaims(c.now(), map[string]any{
		"padding": strings.Repeat("x", maxTokenBytes),
	}))
	if len(oversized) <= maxTokenBytes {
		t.Fatalf("fixture is %d bytes, which does not exceed the %d cap", len(oversized), maxTokenBytes)
	}
	cases["oversized"] = oversized

	for name, tok := range cases {
		t.Run(name, func(t *testing.T) { mustReject(t, v, tok, ErrMalformed) })
	}

	big := mint(t, k.rsa1, nil, goodClaims(c.now(), map[string]any{
		"padding": strings.Repeat("x", 2048),
	}))
	if len(big) >= maxTokenBytes {
		t.Fatalf("a %d-byte token is not under the %d cap; the cap is too tight", len(big), maxTokenBytes)
	}
	if _, err := v.Verify(bgctx, big); err != nil {
		t.Fatalf("a large but legitimate token was rejected: %v", err)
	}
}

func TestVerifierChecksTheTypHeader(t *testing.T) {
	k := testKeys()
	j := newJWKS(t, k.rsa1)
	c := newClock()
	v := verifierOn(j, c)
	claims := goodClaims(c.now(), nil)

	t.Run("accepted", func(t *testing.T) {
		for _, typ := range []any{nil, "JWT", "jwt", "application/jwt"} {
			tok := mint(t, k.rsa1, map[string]any{"typ": typ}, claims)
			if _, err := v.Verify(bgctx, tok); err != nil {
				t.Fatalf("typ %v rejected: %v", typ, err)
			}
		}
	})
	t.Run("rejected", func(t *testing.T) {
		for _, typ := range []string{"at+jwt", "JWE", "secevent+jwt"} {
			tok := mint(t, k.rsa1, map[string]any{"typ": typ}, claims)
			mustReject(t, v, tok, ErrUntrustedHeader)
		}
	})
}

func TestVerifierRejectsDistributedClaims(t *testing.T) {
	k := testKeys()
	j := newJWKS(t, k.rsa1)
	c := newClock()
	v := verifierOn(j, c)

	tok := mint(t, k.rsa1, nil, goodClaims(c.now(), map[string]any{
		"_claim_names":   map[string]any{"email": "src1"},
		"_claim_sources": map[string]any{"src1": map[string]any{"endpoint": "https://evil.test/claims"}},
	}))
	mustReject(t, v, tok, ErrMalformed)

	if j.hitCount() != 0 {
		t.Fatalf("distributed-claims token caused %d JWKS fetches", j.hitCount())
	}
}

func TestVerifierRefetchesJWKSAfterRotation(t *testing.T) {
	k := testKeys()
	j := newJWKS(t, k.rsa1)
	c := newClock()
	v := verifierOn(j, c)

	if _, err := v.Verify(bgctx, mint(t, k.rsa1, nil, goodClaims(c.now(), nil))); err != nil {
		t.Fatalf("pre-rotation verify: %v", err)
	}

	j.rotate(k.rsa2)

	mustReject(t, v, mint(t, k.rsa2, nil, goodClaims(c.now(), nil)), ErrSignature)

	c.advance(jwksRefresh + time.Second)
	before := j.hitCount()
	id, err := v.Verify(bgctx, mint(t, k.rsa2, nil, goodClaims(c.now(), nil)))
	if err != nil {
		t.Fatalf("post-rotation verify (new kid must trigger a refetch): %v", err)
	}
	if id.Sub != testSubject {
		t.Fatalf("subject = %q", id.Sub)
	}
	if j.hitCount() <= before {
		t.Fatal("the new kid did not cause a JWKS refetch")
	}
}

func TestVerifierRejectsATokenSignedByARotatedOutKey(t *testing.T) {
	k := testKeys()
	j := newJWKS(t, k.rsa1)
	c := newClock()
	v := verifierOn(j, c)

	if _, err := v.Verify(bgctx, mint(t, k.rsa1, nil, goodClaims(c.now(), nil))); err != nil {
		t.Fatalf("pre-rotation verify: %v", err)
	}

	j.rotate(k.rsa2)

	c.advance(jwksRefresh / 2)
	if _, err := v.Verify(bgctx, mint(t, k.rsa1, nil, goodClaims(c.now(), nil))); err != nil {
		t.Fatalf("inside the refresh window the retired key should still verify: %v", err)
	}

	c.advance(jwksRefresh)
	mustReject(t, v, mint(t, k.rsa1, nil, goodClaims(c.now(), nil)), ErrSignature)

	if _, err := v.Verify(bgctx, mint(t, k.rsa2, nil, goodClaims(c.now(), nil))); err != nil {
		t.Fatalf("current key rejected after refresh: %v", err)
	}
}

func TestVerifierRejectsAKeyReplacedUnderTheSameKid(t *testing.T) {
	k := testKeys()
	j := newJWKS(t, k.rsa1)
	c := newClock()
	v := verifierOn(j, c)

	if _, err := v.Verify(bgctx, mint(t, k.rsa1, nil, goodClaims(c.now(), nil))); err != nil {
		t.Fatalf("pre-rotation verify: %v", err)
	}

	imposter := k.rsa2.withKID(k.rsa1.kid)
	j.rotate(imposter)

	c.advance(jwksRefresh / 2)
	if _, err := v.Verify(bgctx, mint(t, k.rsa1, nil, goodClaims(c.now(), nil))); err != nil {
		t.Fatalf("inside the refresh window the cached key should still verify: %v", err)
	}

	c.advance(jwksRefresh)
	mustReject(t, v, mint(t, k.rsa1, nil, goodClaims(c.now(), nil)), ErrSignature)

	if _, err := v.Verify(bgctx, mint(t, imposter, nil, goodClaims(c.now(), nil))); err != nil {
		t.Fatalf("replacement key rejected: %v", err)
	}
}

func TestForgedTokensCannotAmplifyIntoJWKSFetches(t *testing.T) {
	k := testKeys()

	forgeries := map[string]func(i int) map[string]any{
		"unknown kid": func(i int) map[string]any {
			return map[string]any{"kid": fmt.Sprintf("forged-%d", i)}
		},
		"live kid, forged signature": func(int) map[string]any {
			return map[string]any{"kid": k.rsa1.kid}
		},
		"no kid": func(int) map[string]any {
			return map[string]any{"kid": nil}
		},
	}
	for name, hdr := range forgeries {
		t.Run(name, func(t *testing.T) {
			j := newJWKS(t, k.rsa1)
			c := newClock()
			v := verifierOn(j, c)
			for i := 0; i < 20; i++ {
				tok := mint(t, k.rsa2, hdr(i), goodClaims(c.now(), map[string]any{"sub": fmt.Sprint(i)}))
				mustReject(t, v, tok, ErrSignature)
			}
			if got := j.hitCount(); got != 1 {
				t.Fatalf("20 forged tokens caused %d JWKS fetches; want exactly 1 (the initial load)", got)
			}
		})
	}
}

func TestJWKSIsFetchedOnAClockNotOnFailure(t *testing.T) {
	k := testKeys()
	j := newJWKS(t, k.rsa1)
	c := newClock()
	v := verifierOn(j, c)

	good := func() string { return mint(t, k.rsa1, nil, goodClaims(c.now(), nil)) }
	if _, err := v.Verify(bgctx, good()); err != nil {
		t.Fatal(err)
	}
	if j.hitCount() != 1 {
		t.Fatalf("first verify caused %d fetches, want 1", j.hitCount())
	}
	for i := 0; i < 100; i++ {
		if _, err := v.Verify(bgctx, good()); err != nil {
			t.Fatal(err)
		}
	}
	if j.hitCount() != 1 {
		t.Fatalf("100 good verifies caused %d fetches, want 1", j.hitCount())
	}
	c.advance(jwksRefresh + time.Second)
	if _, err := v.Verify(bgctx, good()); err != nil {
		t.Fatal(err)
	}
	if j.hitCount() != 2 {
		t.Fatalf("after one refresh interval there were %d fetches, want 2", j.hitCount())
	}
}

func TestAForgedSignatureUnderALiveKidDoesNotLockOutRealTokens(t *testing.T) {
	k := testKeys()
	j := newJWKS(t, k.rsa1)
	c := newClock()
	v := verifierOn(j, c)

	forged := mint(t, k.rsa2, map[string]any{"kid": k.rsa1.kid}, goodClaims(c.now(), nil))
	for i := 0; i < 5; i++ {
		mustReject(t, v, forged, ErrSignature)
	}
	if _, err := v.Verify(bgctx, mint(t, k.rsa1, nil, goodClaims(c.now(), nil))); err != nil {
		t.Fatalf("a forgery under the live kid locked out genuine tokens: %v", err)
	}
}

func TestJWKSOutageServesStaleKeysButOnlyUpToTheLimit(t *testing.T) {
	k := testKeys()
	j := newJWKS(t, k.rsa1)
	c := newClock()
	v := verifierOn(j, c)

	if _, err := v.Verify(bgctx, mint(t, k.rsa1, nil, goodClaims(c.now(), nil))); err != nil {
		t.Fatal(err)
	}
	j.fail(true)

	c.advance(jwksRefresh + time.Second)
	if _, err := v.Verify(bgctx, mint(t, k.rsa1, nil, goodClaims(c.now(), nil))); err != nil {
		t.Fatalf("a JWKS blip must not be a sign-in outage: %v", err)
	}

	before := j.hitCount()
	for i := 0; i < 20; i++ {
		_, _ = v.Verify(bgctx, mint(t, k.rsa1, nil, goodClaims(c.now(), nil)))
	}
	if got := j.hitCount() - before; got != 0 {
		t.Fatalf("20 verifies during an outage made %d further fetch attempts, want 0 inside the window", got)
	}

	c.advance(jwksStaleMax)
	_, err := v.Verify(bgctx, mint(t, k.rsa1, nil, goodClaims(c.now(), nil)))
	if !errors.Is(err, ErrKeySetUnavailable) {
		t.Fatalf("past the stale limit: %v, want ErrKeySetUnavailable", err)
	}
	if errors.Is(err, ErrTokenRejected) {
		t.Fatal("an expired-stale key set must not be reported as a rejected token")
	}

	j.fail(false)
	c.advance(jwksRefresh + time.Second)
	if _, err := v.Verify(bgctx, mint(t, k.rsa1, nil, goodClaims(c.now(), nil))); err != nil {
		t.Fatalf("after the provider recovered: %v", err)
	}
}

func TestVerifierAcceptsAKidLessTokenThatVerifies(t *testing.T) {
	k := testKeys()
	j := newJWKS(t, k.rsa1)
	c := newClock()
	v := verifierOn(j, c)

	tok := mint(t, k.rsa1, map[string]any{"kid": nil}, goodClaims(c.now(), nil))
	id, err := v.Verify(bgctx, tok)
	if err != nil {
		t.Fatalf("kid-less token that verifies against a published key: %v", err)
	}
	if id.Sub != testSubject {
		t.Fatalf("subject = %q", id.Sub)
	}
}

func TestVerifierIgnoresKeysNotPublishedForSigning(t *testing.T) {
	k := testKeys()
	c := newClock()

	t.Run("use=enc is not a signing key", func(t *testing.T) {
		j := newJWKS(t, k.rsa1.withUse("enc"))
		v := verifierOn(j, c)
		mustReject(t, v, mint(t, k.rsa1, nil, goodClaims(c.now(), nil)), ErrSignature)
	})
	t.Run("absent use is still usable", func(t *testing.T) {
		j := newJWKS(t, k.rsa1.withUse(""))
		v := verifierOn(j, c)
		if _, err := v.Verify(bgctx, mint(t, k.rsa1, nil, goodClaims(c.now(), nil))); err != nil {
			t.Fatalf("a key with no declared use should still verify: %v", err)
		}
	})
}

func TestAnAbortedRequestCannotPoisonTheKeySet(t *testing.T) {
	k := testKeys()
	j := newJWKS(t, k.rsa1)
	c := newClock()
	v := verifierOn(j, c)

	entered, release := j.gate()

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		_, _ = v.Verify(ctx, mint(t, k.rsa2, nil, goodClaims(c.now(), nil)))
	}()

	<-entered
	cancel()
	close(release)
	<-done

	if _, err := v.Verify(bgctx, mint(t, k.rsa1, nil, goodClaims(c.now(), nil))); err != nil {
		t.Fatalf("an aborted request poisoned the key set: %v", err)
	}

	if got := j.hitCount(); got != 1 {
		t.Fatalf("the sequence made %d JWKS fetches, want 1 (the aborted caller's fetch, completed anyway)", got)
	}
}

func TestASlowFetchHonoursTheCallersDeadlineWithoutAbortingTheFetch(t *testing.T) {
	k := testKeys()
	j := newJWKS(t, k.rsa1)
	c := newClock()
	v := verifierOn(j, c)

	entered, release := j.gate()

	firstDone := make(chan struct{})
	go func() {
		defer close(firstDone)
		_, _ = v.Verify(bgctx, mint(t, k.rsa1, nil, goodClaims(c.now(), nil)))
	}()
	<-entered

	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	start := time.Now()
	_, err := v.Verify(ctx, mint(t, k.rsa1, nil, goodClaims(c.now(), nil)))
	waited := time.Since(start)
	if err == nil {
		t.Fatal("caller B should not have succeeded while the fetch was blocked")
	}
	if waited > 400*time.Millisecond {
		t.Fatalf("caller B waited %s despite a 50ms deadline", waited)
	}

	close(release)
	<-firstDone
	if _, err := v.Verify(bgctx, mint(t, k.rsa1, nil, goodClaims(c.now(), nil))); err != nil {
		t.Fatalf("the shared fetch did not complete: %v", err)
	}
}

func TestConcurrentCallersShareOneJWKSFetch(t *testing.T) {
	k := testKeys()
	j := newJWKS(t, k.rsa1)
	c := newClock()
	v := verifierOn(j, c)

	var wg sync.WaitGroup
	for i := 0; i < 16; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := v.Verify(bgctx, mint(t, k.rsa1, nil, goodClaims(c.now(), nil))); err != nil {
				t.Errorf("verify: %v", err)
			}
		}()
	}
	wg.Wait()
	if got := j.hitCount(); got != 1 {
		t.Fatalf("16 concurrent cold-cache verifies made %d fetches, want 1", got)
	}
}

func TestAnUnavailableKeySetIsNotReportedAsAForgedToken(t *testing.T) {
	k := testKeys()
	j := newJWKS(t, k.rsa1)
	c := newClock()
	v := verifierOn(j, c)
	j.fail(true)

	good := mint(t, k.rsa1, nil, goodClaims(c.now(), nil))
	_, err := v.Verify(bgctx, good)
	if err == nil {
		t.Fatal("verify succeeded with no keys available")
	}
	if !errors.Is(err, ErrKeySetUnavailable) {
		t.Fatalf("err = %v, want ErrKeySetUnavailable", err)
	}
	if errors.Is(err, ErrTokenRejected) {
		t.Fatal("a provider outage must not be reported as a rejected token")
	}

	j.fail(false)
	c.advance(jwksRefresh + time.Second)
	mustReject(t, v, mint(t, k.rsa2, nil, goodClaims(c.now(), nil)), ErrSignature)
}

func TestConstructionPerformsNoNetworkIO(t *testing.T) {
	k := testKeys()
	j := newJWKS(t, k.rsa1)
	c := newClock()

	_ = verifierOn(j, c)
	if j.hitCount() != 0 {
		t.Fatalf("construction fetched the JWKS %d time(s)", j.hitCount())
	}
}

func TestMisconfiguredVerifierRejectsEverything(t *testing.T) {
	k := testKeys()
	j := newJWKS(t, k.rsa1)
	c := newClock()
	good := goodClaims(c.now(), nil)

	cases := map[string]*Verifier{
		"no audience":    {Issuers: []string{testIssuer}, JWKSURL: j.url(), Now: c.now},
		"blank audience": {Issuers: []string{testIssuer}, Audience: "  ", JWKSURL: j.url(), Now: c.now},
		"blank issuers":  {Issuers: []string{" "}, Audience: testAudience, JWKSURL: j.url(), Now: c.now},
	}
	for name, v := range cases {
		t.Run(name, func(t *testing.T) {
			mustReject(t, v, mint(t, k.rsa1, nil, good), ErrNotConfigured)
		})
	}
}
