package auth

import (
	"bytes"
	"encoding/base64"
	"errors"
	"testing"
	"time"

	"github.com/go-webauthn/webauthn/protocol"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/authtest"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

func newPasskeys(t *testing.T, pool *pgxpool.Pool) *Passkeys {
	t.Helper()
	p, err := NewPasskeys(pool, authtest.RPID, authtest.RPDisplayName, []string{authtest.RPOrigin})
	if err != nil {
		t.Fatal(err)
	}
	return p
}

func enroll(t *testing.T, p *Passkeys, code string) (uuid.UUID, *authtest.Authenticator) {
	t.Helper()
	id, opts, _, err := p.BeginRegistration(bgctx, code, authtest.AuthorityPub(t))
	if err != nil {
		t.Fatalf("BeginRegistration: %v", err)
	}
	a := authtest.New(t)
	userID, _, err := p.FinishRegistration(bgctx, id, a.Create(t, opts))
	if err != nil {
		t.Fatalf("FinishRegistration: %v", err)
	}
	return userID, a
}

func countCeremonies(t *testing.T, pool *pgxpool.Pool) int {
	t.Helper()
	var n int
	if err := pool.QueryRow(bgctx, `SELECT count(*) FROM webauthn_ceremonies`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

func TestPasskeyRegistrationWithAValidInviteCreatesOnePasskeyUserAndSpendsTheCode(t *testing.T) {
	pool := pgtest.New(t)
	p := newPasskeys(t, pool)
	code := mustMint(t, pool, "the passkey beta tester")

	userID, a := enroll(t, p, code)

	if n := countUsers(t, pool); n != 1 {
		t.Fatalf("users = %d, want exactly 1", n)
	}
	var (
		handle   []byte
		redeemed *time.Time
		by       *uuid.UUID
	)
	if err := pool.QueryRow(bgctx, `SELECT user_handle FROM users WHERE id = $1`, userID).Scan(&handle); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(handle, a.Handle) {
		t.Fatal("users.user_handle is not the handle the authenticator was given")
	}

	if err := pool.QueryRow(bgctx, `SELECT redeemed_at, redeemed_by FROM invite_codes`).
		Scan(&redeemed, &by); err != nil {
		t.Fatal(err)
	}
	if redeemed == nil || by == nil || *by != userID {
		t.Fatalf("invite was not redeemed by the account it created: redeemed_at=%v by=%v", redeemed, by)
	}

	var (
		storedUser   uuid.UUID
		storedHandle []byte
		signCount    int64
		backupElig   bool
	)
	if err := pool.QueryRow(bgctx,
		`SELECT user_id, user_handle, sign_count, backup_eligible FROM webauthn_credentials WHERE credential_id = $1`,
		a.CredID).Scan(&storedUser, &storedHandle, &signCount, &backupElig); err != nil {
		t.Fatal(err)
	}
	if storedUser != userID {
		t.Fatal("the credential does not belong to the account the registration created")
	}
	if !bytes.Equal(storedHandle, a.Handle) {
		t.Fatal("the stored user handle is not the one the authenticator was given")
	}
	if signCount != 1 || !backupElig {
		t.Fatalf("sign_count = %d, backup_eligible = %v; want the authenticator's own values", signCount, backupElig)
	}
	if n := countCeremonies(t, pool); n != 0 {
		t.Fatalf("ceremonies left after finish = %d, want 0 (single use)", n)
	}
}

func TestPasskeyRegistrationWithASpentCodeIsRefusedAndCreatesNothing(t *testing.T) {
	pool := pgtest.New(t)
	p := newPasskeys(t, pool)
	code := mustMint(t, pool, "spent once")
	first, _ := enroll(t, p, code)

	id, opts, _, err := p.BeginRegistration(bgctx, code, authtest.AuthorityPub(t))
	if err != nil {
		if !errors.Is(err, ErrCodeRejected) {
			t.Fatalf("BeginRegistration with a claimed signup: %v, want ErrCodeRejected", err)
		}
	} else {
		a := authtest.New(t)
		if _, _, err := p.FinishRegistration(bgctx, id, a.Create(t, opts)); !errors.Is(err, ErrCodeRejected) {
			t.Fatalf("FinishRegistration with a claimed signup: %v, want ErrCodeRejected", err)
		}
	}

	if n := countUsers(t, pool); n != 1 {
		t.Fatalf("users = %d, want 1 — the refused registration created an account", n)
	}
	var n int
	if err := pool.QueryRow(bgctx, `SELECT count(*) FROM webauthn_credentials`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("credentials = %d, want 1 — the refused registration stored one", n)
	}
	var by uuid.UUID
	if err := pool.QueryRow(bgctx, `SELECT redeemed_by FROM invite_codes`).Scan(&by); err != nil {
		t.Fatal(err)
	}
	if by != first {
		t.Fatal("the code changed hands")
	}
}

func TestTwoRegistrationsBegunAgainstOneLiveCodeYieldOneAccount(t *testing.T) {
	pool := pgtest.New(t)
	p := newPasskeys(t, pool)
	code := mustMint(t, pool, "one code, two tabs")

	idA, optsA, _, err := p.BeginRegistration(bgctx, code, authtest.AuthorityPub(t))
	if err != nil {
		t.Fatal(err)
	}
	idB, optsB, _, err := p.BeginRegistration(bgctx, code, authtest.AuthorityPub(t))
	if err != nil {
		t.Fatal(err)
	}
	a, b := authtest.New(t), authtest.New(t)
	if _, _, err := p.FinishRegistration(bgctx, idA, a.Create(t, optsA)); err != nil {
		t.Fatalf("first FinishRegistration: %v", err)
	}
	if _, _, err := p.FinishRegistration(bgctx, idB, b.Create(t, optsB)); !errors.Is(err, ErrCodeRejected) {
		t.Fatalf("second FinishRegistration: %v, want ErrCodeRejected", err)
	}
	if n := countUsers(t, pool); n != 1 {
		t.Fatalf("users = %d, want 1", n)
	}
	var n int
	if err := pool.QueryRow(bgctx, `SELECT count(*) FROM webauthn_credentials`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("credentials = %d, want 1 — the refused registration stored one anyway", n)
	}
}

func TestARegistrationThatFailsAfterTheUpsertDoesNotBurnTheInvite(t *testing.T) {
	pool := pgtest.New(t)
	p := newPasskeys(t, pool)
	_, first := enroll(t, p, mustMint(t, pool, "the first account"))

	code := mustMint(t, pool, "sameera's code")
	id, opts, _, err := p.BeginRegistration(bgctx, code, authtest.AuthorityPub(t))
	if err != nil {
		t.Fatal(err)
	}
	clash := authtest.New(t)
	clash.CredID = first.CredID

	if _, _, err := p.FinishRegistration(bgctx, id, clash.Create(t, opts)); err == nil {
		t.Fatal("a duplicate credential id was accepted")
	}

	if n := countUsers(t, pool); n != 1 {
		t.Fatalf("users = %d, want 1", n)
	}
	var (
		redeemed *time.Time
		by       *uuid.UUID
		note     string
	)
	if err := pool.QueryRow(bgctx,
		`SELECT redeemed_at, redeemed_by, coalesce(note, '') FROM invite_codes WHERE redeemed_at IS NULL`).
		Scan(&redeemed, &by, &note); err != nil {
		t.Fatalf("the failed registration left no unredeemed code behind: %v", err)
	}
	if redeemed != nil || by != nil {
		t.Fatalf("code is redeemed_at=%v by=%v after a failed registration", redeemed, by)
	}
	if note != "sameera's code" {
		t.Fatalf("note = %q, want the operator's words: a burned code nobody can identify "+
			"is the half of this defect that cannot be repaired by hand", note)
	}

	if _, _, err := enrollErr(t, p, code); err != nil {
		t.Fatalf("the code did not survive as spendable: %v", err)
	}
	if n := countUsers(t, pool); n != 2 {
		t.Fatalf("users = %d, want 2 after the retry succeeded", n)
	}
}

func enrollErr(t *testing.T, p *Passkeys, code string) (uuid.UUID, *authtest.Authenticator, error) {
	t.Helper()
	id, opts, _, err := p.BeginRegistration(bgctx, code, authtest.AuthorityPub(t))
	if err != nil {
		return uuid.Nil, nil, err
	}
	a := authtest.New(t)
	userID, _, err := p.FinishRegistration(bgctx, id, a.Create(t, opts))
	return userID, a, err
}

func TestPasskeyLoginReturnsTheSameUserTheRegistrationCreated(t *testing.T) {
	pool := pgtest.New(t)
	p := newPasskeys(t, pool)
	registered, a := enroll(t, p, mustMint(t, pool, "returning user"))

	id, opts, err := p.BeginLogin(bgctx)
	if err != nil {
		t.Fatalf("BeginLogin: %v", err)
	}
	if len(opts.Response.AllowedCredentials) != 0 {
		t.Fatal("the login options list credentials; that is not a discoverable login")
	}
	loggedIn, credID, err := p.FinishLogin(bgctx, id, a.Assert(t, opts, a.Counter+1))
	if err != nil {
		t.Fatalf("FinishLogin: %v", err)
	}
	if loggedIn != registered {
		t.Fatalf("login resolved to %s, registration created %s", loggedIn, registered)
	}
	if !bytes.Equal(credID, a.CredID) {
		t.Fatal("login named a different credential")
	}

	var signCount int64
	var lastUsed *time.Time
	if err := pool.QueryRow(bgctx,
		`SELECT sign_count, last_used_at FROM webauthn_credentials WHERE credential_id = $1`,
		a.CredID).Scan(&signCount, &lastUsed); err != nil {
		t.Fatal(err)
	}
	if signCount != int64(a.Counter)+1 {
		t.Fatalf("sign_count = %d, want the counter the assertion carried (%d)", signCount, a.Counter+1)
	}
	if lastUsed == nil {
		t.Fatal("last_used_at was not recorded")
	}
	if n := countUsers(t, pool); n != 1 {
		t.Fatalf("users = %d, want 1 — signing in created a second account", n)
	}
}

func TestPasskeyUserNameIsTheRPNameAloneRegardlessOfHandle(t *testing.T) {
	a := passkeyUser{handle: []byte{1, 2, 3}, rpName: "Ledger by Example Co"}
	b := passkeyUser{handle: []byte{9, 9, 9, 9, 9, 9}, rpName: "Ledger by Example Co"}

	if a.WebAuthnName() != "Ledger by Example Co" {
		t.Fatalf("WebAuthnName = %q, want the bare RP name", a.WebAuthnName())
	}
	if a.WebAuthnDisplayName() != "Ledger by Example Co" {
		t.Fatalf("WebAuthnDisplayName = %q, want the bare RP name", a.WebAuthnDisplayName())
	}
	if a.WebAuthnName() != b.WebAuthnName() {
		t.Fatalf("WebAuthnName differs across handles (%q vs %q); it must be handle-independent",
			a.WebAuthnName(), b.WebAuthnName())
	}
}

func TestTwoAccountsWithIdenticalPasskeyNamesStillLoginToDistinctAccounts(t *testing.T) {
	pool := pgtest.New(t)
	p := newPasskeys(t, pool)
	first, aAuth := enroll(t, p, mustMint(t, pool, "account one"))
	second, bAuth := enroll(t, p, mustMint(t, pool, "account two"))
	if first == second {
		t.Fatal("fixture bug: enroll produced the same account twice")
	}

	id1, opts1, err := p.BeginLogin(bgctx)
	if err != nil {
		t.Fatalf("BeginLogin (a): %v", err)
	}
	got1, _, err := p.FinishLogin(bgctx, id1, aAuth.Assert(t, opts1, aAuth.Counter+1))
	if err != nil {
		t.Fatalf("FinishLogin (a): %v", err)
	}
	if got1 != first {
		t.Fatalf("authenticator a logged in as %s, want %s", got1, first)
	}

	id2, opts2, err := p.BeginLogin(bgctx)
	if err != nil {
		t.Fatalf("BeginLogin (b): %v", err)
	}
	got2, _, err := p.FinishLogin(bgctx, id2, bAuth.Assert(t, opts2, bAuth.Counter+1))
	if err != nil {
		t.Fatalf("FinishLogin (b): %v", err)
	}
	if got2 != second {
		t.Fatalf("authenticator b logged in as %s, want %s", got2, second)
	}
}

func TestPasskeyLoginWithAnUnknownCredentialIsRefused(t *testing.T) {
	pool := pgtest.New(t)
	p := newPasskeys(t, pool)
	_, enrolled := enroll(t, p, mustMint(t, pool, "the real one"))

	stranger := authtest.New(t)
	stranger.Handle = enrolled.Handle

	id, opts, err := p.BeginLogin(bgctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := p.FinishLogin(bgctx, id, stranger.Assert(t, opts, 2)); err == nil {
		t.Fatal("an unenrolled credential was accepted")
	} else if !errors.Is(err, ErrPasskeyRejected) {
		t.Fatalf("FinishLogin with an unknown credential: %v, want ErrPasskeyRejected", err)
	}
}

func TestPasskeyCeremonyIsSingleUse(t *testing.T) {
	pool := pgtest.New(t)
	p := newPasskeys(t, pool)
	_, a := enroll(t, p, mustMint(t, pool, "replayer"))

	id, opts, err := p.BeginLogin(bgctx)
	if err != nil {
		t.Fatal(err)
	}
	body := a.Assert(t, opts, 2)
	if _, _, err := p.FinishLogin(bgctx, id, body); err != nil {
		t.Fatalf("first FinishLogin: %v", err)
	}
	if _, _, err := p.FinishLogin(bgctx, id, body); !errors.Is(err, ErrCeremonyUnknown) {
		t.Fatalf("replayed ceremony: %v, want ErrCeremonyUnknown", err)
	}
	if n := countCeremonies(t, pool); n != 0 {
		t.Fatalf("ceremonies = %d after a spent login, want 0", n)
	}
}

func TestExpiredPasskeyCeremonyIsRefused(t *testing.T) {
	pool := pgtest.New(t)
	p := newPasskeys(t, pool)
	_, a := enroll(t, p, mustMint(t, pool, "slow"))

	now := time.Now().UTC()
	p.Now = func() time.Time { return now }

	id, opts, err := p.BeginLogin(bgctx)
	if err != nil {
		t.Fatal(err)
	}
	body := a.Assert(t, opts, 2)

	now = now.Add(CeremonyTTL + time.Second)
	if _, _, err := p.FinishLogin(bgctx, id, body); !errors.Is(err, ErrCeremonyUnknown) {
		t.Fatalf("expired ceremony: %v, want ErrCeremonyUnknown", err)
	}
}

func TestPasskeySignCountGoingBackwardsIsRefusedAsCloneEvidence(t *testing.T) {
	pool := pgtest.New(t)
	p := newPasskeys(t, pool)
	_, a := enroll(t, p, mustMint(t, pool, "cloned"))

	id, opts, err := p.BeginLogin(bgctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := p.FinishLogin(bgctx, id, a.Assert(t, opts, 9)); err != nil {
		t.Fatalf("FinishLogin at counter 9: %v", err)
	}

	id, opts, err = p.BeginLogin(bgctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := p.FinishLogin(bgctx, id, a.Assert(t, opts, 4)); !errors.Is(err, ErrClonedAuthenticator) {
		t.Fatalf("a counter that went backwards: %v, want ErrClonedAuthenticator", err)
	}

	var signCount int64
	if err := pool.QueryRow(bgctx,
		`SELECT sign_count FROM webauthn_credentials WHERE credential_id = $1`, a.CredID).
		Scan(&signCount); err != nil {
		t.Fatal(err)
	}
	if signCount != 9 {
		t.Fatalf("sign_count = %d, want 9 — the refused assertion moved it", signCount)
	}
}

func TestAPermanentZeroCounterSignsInRepeatedlyAndStillRecordsLastUsed(t *testing.T) {
	pool := pgtest.New(t)
	p := newPasskeys(t, pool)

	code := mustMint(t, pool, "icloud keychain")
	id, opts, _, err := p.BeginRegistration(bgctx, code, authtest.AuthorityPub(t))
	if err != nil {
		t.Fatal(err)
	}
	a := authtest.New(t)
	a.Counter = 0
	userID, _, err := p.FinishRegistration(bgctx, id, a.Create(t, opts))
	if err != nil {
		t.Fatalf("FinishRegistration at counter 0: %v", err)
	}

	for i := range 3 {
		lid, lopts, err := p.BeginLogin(bgctx)
		if err != nil {
			t.Fatal(err)
		}
		got, _, err := p.FinishLogin(bgctx, lid, a.Assert(t, lopts, 0))
		if err != nil {
			t.Fatalf("login %d at counter 0: %v — a synced passkey was bricked", i+1, err)
		}
		if got != userID {
			t.Fatalf("login %d resolved to %s, want %s", i+1, got, userID)
		}
		var (
			signCount int64
			lastUsed  *time.Time
		)
		if err := pool.QueryRow(bgctx,
			`SELECT sign_count, last_used_at FROM webauthn_credentials WHERE credential_id = $1`,
			a.CredID).Scan(&signCount, &lastUsed); err != nil {
			t.Fatal(err)
		}
		if signCount != 0 {
			t.Fatalf("sign_count = %d, want it left at 0", signCount)
		}
		if lastUsed == nil {
			t.Fatalf("login %d did not record last_used_at for a zero-counter authenticator", i+1)
		}
	}
}

func TestAddingASecondPasskeyKeepsOneAccountAndOneHandle(t *testing.T) {
	pool := pgtest.New(t)
	p := newPasskeys(t, pool)
	userID, first := enroll(t, p, mustMint(t, pool, "two devices"))

	id, opts, err := p.testBeginAdd(t, userID)
	if err != nil {
		t.Fatalf("testBeginAdd: %v", err)
	}
	second := authtest.New(t)
	credID, err := p.testFinishAdd(bgctx, id, userID, second.Create(t, opts))
	if err != nil {
		t.Fatalf("FinishAdd: %v", err)
	}
	if !bytes.Equal(credID, second.CredID) {
		t.Fatal("FinishAdd named a different credential")
	}
	if !bytes.Equal(second.Handle, first.Handle) {
		t.Fatal("the add ceremony minted a new user handle instead of reusing the account's")
	}
	if n := countUsers(t, pool); n != 1 {
		t.Fatalf("users = %d, want 1", n)
	}

	lid, lopts, err := p.BeginLogin(bgctx)
	if err != nil {
		t.Fatal(err)
	}
	got, _, err := p.FinishLogin(bgctx, lid, second.Assert(t, lopts, 7))
	if err != nil {
		t.Fatalf("FinishLogin with the added credential: %v", err)
	}
	if got != userID {
		t.Fatalf("the added credential signed in as %s, want %s", got, userID)
	}
}

func TestAddCeremonyIsBoundToTheSessionThatStartedIt(t *testing.T) {
	pool := pgtest.New(t)
	p := newPasskeys(t, pool)
	victim, _ := enroll(t, p, mustMint(t, pool, "victim"))
	attacker, _ := enroll(t, p, mustMint(t, pool, "attacker"))

	id, opts, err := p.testBeginAdd(t, victim)
	if err != nil {
		t.Fatal(err)
	}
	a := authtest.New(t)
	if _, err := p.testFinishAdd(bgctx, id, attacker, a.Create(t, opts)); err == nil {
		t.Fatal("a ceremony begun for one account was finished by another")
	} else if !errors.Is(err, ErrPasskeyRejected) {
		t.Fatalf("cross-account FinishAdd: %v, want ErrPasskeyRejected", err)
	}
}

func TestAddUsesTheAccountsHandleEvenWithNoPasskeyYet(t *testing.T) {
	pool := pgtest.New(t)
	p := newPasskeys(t, pool)
	u := newTestUser(t, pool)
	var handle []byte
	if err := pool.QueryRow(bgctx, `SELECT user_handle FROM users WHERE id = $1`, u).Scan(&handle); err != nil {
		t.Fatal(err)
	}
	_, opts, err := p.testBeginAdd(t, u)
	if err != nil {
		t.Fatalf("begin add on a password-only account: %v", err)
	}
	if id, ok := opts.Response.User.ID.(protocol.URLEncodedBase64); !ok || !bytes.Equal(id, handle) {
		t.Fatal("the add ceremony does not name the account's handle")
	}
}

func TestExpiredCeremoniesAreSwept(t *testing.T) {
	pool := pgtest.New(t)
	p := newPasskeys(t, pool)
	now := time.Now().UTC()
	p.Now = func() time.Time { return now }

	if _, _, err := p.BeginLogin(bgctx); err != nil {
		t.Fatal(err)
	}
	if n := countCeremonies(t, pool); n != 1 {
		t.Fatalf("ceremonies = %d, want 1", n)
	}
	now = now.Add(CeremonyTTL + time.Minute)
	n, err := p.ReapExpiredCeremonies(bgctx)
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("reaped %d, want 1", n)
	}
	if got := countCeremonies(t, pool); got != 0 {
		t.Fatalf("ceremonies = %d after the sweep, want 0", got)
	}
}

func TestPasskeyCeremonyOptionsRequireADiscoverableCredential(t *testing.T) {
	pool := pgtest.New(t)
	p := newPasskeys(t, pool)
	_, opts, _, err := p.BeginRegistration(bgctx, mustMint(t, pool, "opts"), authtest.AuthorityPub(t))
	if err != nil {
		t.Fatal(err)
	}
	sel := opts.Response.AuthenticatorSelection
	if sel.ResidentKey != protocol.ResidentKeyRequirementRequired {
		t.Fatalf("residentKey = %q, want %q — username-less login needs a discoverable credential",
			sel.ResidentKey, protocol.ResidentKeyRequirementRequired)
	}
	if sel.UserVerification != protocol.VerificationRequired {
		t.Fatalf("userVerification = %q, want %q", sel.UserVerification, protocol.VerificationRequired)
	}
	if opts.Response.RelyingParty.ID != authtest.RPID {
		t.Fatalf("rp.id = %q, want %q", opts.Response.RelyingParty.ID, authtest.RPID)
	}
}

func TestPasskeyCeremonyIDIsNotGuessable(t *testing.T) {
	pool := pgtest.New(t)
	p := newPasskeys(t, pool)
	seen := map[string]bool{}
	for range 32 {
		id, _, err := p.BeginLogin(bgctx)
		if err != nil {
			t.Fatal(err)
		}
		raw, err := base64.RawURLEncoding.DecodeString(id)
		if err != nil {
			t.Fatalf("ceremony id %q is not base64url: %v", id, err)
		}
		if len(raw) < 32 {
			t.Fatalf("ceremony id carries %d bytes, want at least 32", len(raw))
		}
		if seen[id] {
			t.Fatal("a ceremony id repeated")
		}
		seen[id] = true
	}
}

func TestPasskeysRefusesAConfigWithNoOrigin(t *testing.T) {
	pool := pgtest.New(t)
	if _, err := NewPasskeys(pool, authtest.RPID, authtest.RPDisplayName, nil); err == nil {
		t.Fatal("a relying party with no origins was accepted; every ceremony would be unverifiable")
	}
}
