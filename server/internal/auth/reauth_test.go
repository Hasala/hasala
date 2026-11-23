package auth

import (
	"crypto/rand"
	"errors"
	"testing"
	"time"

	"github.com/go-webauthn/webauthn/protocol"
	"github.com/google/uuid"

	"github.com/salehtl/hasala/server/internal/authtest"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

func challengeBytes(t *testing.T) []byte {
	t.Helper()
	return authtest.RandBytes(t, 32)
}

func assertOver(t *testing.T, a *authtest.Authenticator, challenge []byte, counter uint32) []byte {
	t.Helper()
	return a.Assert(t, &protocol.CredentialAssertion{
		Response: protocol.PublicKeyCredentialRequestOptions{
			Challenge:      protocol.URLEncodedBase64(challenge),
			RelyingPartyID: authtest.RPID,
		},
	}, counter)
}

func TestVerifyAssertionAcceptsAnEnrolledCredentialOverTheServersChallenge(t *testing.T) {
	t.Parallel()
	pool := pgtest.New(t)
	p := newPasskeys(t, pool)
	userID, a := enroll(t, p, mustMint(t, pool, "alice"))
	challenge := challengeBytes(t)

	if err := p.VerifyAssertion(bgctx, userID, challenge, assertOver(t, a, challenge, 2)); err != nil {
		t.Fatalf("VerifyAssertion: %v", err)
	}

	var (
		count int64
		used  *time.Time
	)
	if err := pool.QueryRow(bgctx,
		`SELECT sign_count, last_used_at FROM webauthn_credentials WHERE credential_id = $1`,
		a.CredID).Scan(&count, &used); err != nil {
		t.Fatal(err)
	}
	if count != 2 {
		t.Fatalf("sign_count = %d, want the counter the assertion carried", count)
	}
	if used == nil {
		t.Fatal("last_used_at is still NULL after a successful re-authentication")
	}
}

func TestVerifyAssertionRefusesAnAssertionOverADifferentChallenge(t *testing.T) {
	t.Parallel()
	pool := pgtest.New(t)
	p := newPasskeys(t, pool)
	userID, a := enroll(t, p, mustMint(t, pool, "alice"))

	signed := challengeBytes(t)
	expected := challengeBytes(t)
	err := p.VerifyAssertion(bgctx, userID, expected, assertOver(t, a, signed, 2))
	if !errors.Is(err, ErrPasskeyRejected) {
		t.Fatalf("err = %v, want ErrPasskeyRejected", err)
	}
}

func TestVerifyAssertionRefusesACredentialOfADifferentAccount(t *testing.T) {
	t.Parallel()
	pool := pgtest.New(t)
	p := newPasskeys(t, pool)
	alice, _ := enroll(t, p, mustMint(t, pool, "alice"))
	_, mallory := enroll(t, p, mustMint(t, pool, "mallory"))
	challenge := challengeBytes(t)

	err := p.VerifyAssertion(bgctx, alice, challenge, assertOver(t, mallory, challenge, 2))
	if !errors.Is(err, ErrPasskeyRejected) {
		t.Fatalf("err = %v, want ErrPasskeyRejected", err)
	}
}

func TestVerifyAssertionRefusesAnUnenrolledCredential(t *testing.T) {
	t.Parallel()
	pool := pgtest.New(t)
	p := newPasskeys(t, pool)
	userID, _ := enroll(t, p, mustMint(t, pool, "alice"))

	stranger := authtest.New(t)
	stranger.Handle = authtest.RandBytes(t, 32)
	challenge := challengeBytes(t)

	err := p.VerifyAssertion(bgctx, userID, challenge, assertOver(t, stranger, challenge, 2))
	if !errors.Is(err, ErrCredentialUnknown) {
		t.Fatalf("err = %v, want ErrCredentialUnknown", err)
	}
}

func TestVerifyAssertionRefusesACounterThatDidNotAdvance(t *testing.T) {
	t.Parallel()
	pool := pgtest.New(t)
	p := newPasskeys(t, pool)
	userID, a := enroll(t, p, mustMint(t, pool, "alice"))

	first := challengeBytes(t)
	if err := p.VerifyAssertion(bgctx, userID, first, assertOver(t, a, first, 5)); err != nil {
		t.Fatalf("first assertion: %v", err)
	}
	second := challengeBytes(t)
	err := p.VerifyAssertion(bgctx, userID, second, assertOver(t, a, second, 5))
	if !errors.Is(err, ErrClonedAuthenticator) {
		t.Fatalf("err = %v, want ErrClonedAuthenticator", err)
	}
}

func TestVerifyAssertionRefusesAnEmptyAssertion(t *testing.T) {
	t.Parallel()
	pool := pgtest.New(t)
	p := newPasskeys(t, pool)
	userID, _ := enroll(t, p, mustMint(t, pool, "alice"))

	err := p.VerifyAssertion(bgctx, userID, challengeBytes(t), nil)
	if !errors.Is(err, ErrPasskeyRejected) {
		t.Fatalf("err = %v, want ErrPasskeyRejected", err)
	}
}

func TestVerifyAssertionRefusesAChallengeTooShortToBeOneOfOurs(t *testing.T) {
	t.Parallel()
	pool := pgtest.New(t)
	p := newPasskeys(t, pool)
	userID, a := enroll(t, p, mustMint(t, pool, "alice"))

	short := make([]byte, 8)
	if _, err := rand.Read(short); err != nil {
		t.Fatal(err)
	}
	err := p.VerifyAssertion(bgctx, userID, short, assertOver(t, a, short, 2))
	if !errors.Is(err, ErrPasskeyRejected) {
		t.Fatalf("err = %v, want ErrPasskeyRejected", err)
	}
}

func TestVerifyAssertionRefusesAZeroUser(t *testing.T) {
	t.Parallel()
	pool := pgtest.New(t)
	p := newPasskeys(t, pool)
	_, a := enroll(t, p, mustMint(t, pool, "alice"))
	challenge := challengeBytes(t)

	err := p.VerifyAssertion(bgctx, uuid.Nil, challenge, assertOver(t, a, challenge, 2))
	if !errors.Is(err, ErrPasskeyRejected) {
		t.Fatalf("err = %v, want ErrPasskeyRejected", err)
	}
}
