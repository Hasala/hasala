package auth

import (
	"crypto/sha256"
	"encoding/base32"
	"go/ast"
	"go/parser"
	"go/token"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/authtest"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

func mintCode(t *testing.T, pool *pgxpool.Pool, note string) string {
	t.Helper()
	code, err := MintInvite(bgctx, pool, MintOptions{Note: note, Now: time.Now().UTC()})
	if err != nil {
		t.Fatal(err)
	}
	return code
}

func mustMint(t *testing.T, pool *pgxpool.Pool, note string) string {
	t.Helper()
	code := mintCode(t, pool, note)
	id := uuid.NewString()
	now := time.Now().UTC()
	if _, err := pool.Exec(bgctx,
		`INSERT INTO signup_ceremonies (id, user_id, invite_code_hash, email_norm, email_tag, display_name,
		   email_proven, signup_nonce, created_at, expires_at)
		 VALUES ($1, gen_random_uuid(), $2, $3, $4, 'Test User', true, $5, $6, $7)`,
		id, InviteCodeHash(code), "u-"+uuid.NewString()+"@example.test", authtest.RandBytesTB(t, 32),
		authtest.RandBytesTB(t, 32), now, now.Add(SignupTTL)); err != nil {
		t.Fatal(err)
	}
	return id
}

func countUsers(t *testing.T, pool *pgxpool.Pool) int {
	t.Helper()
	var n int
	if err := pool.QueryRow(bgctx, `SELECT count(*) FROM users`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

func TestMintedInviteIsNeverStoredInTheClear(t *testing.T) {
	t.Parallel()
	pool := pgtest.New(t)
	code := mintCode(t, pool, "for maya")
	var (
		hash  []byte
		state string
	)
	if err := pool.QueryRow(bgctx, `SELECT code_hash, state FROM invite_codes`).Scan(&hash, &state); err != nil {
		t.Fatal(err)
	}
	want := sha256.Sum256([]byte(code))
	if string(hash) != string(want[:]) || state != "active" {
		t.Fatalf("stored %x (%s), want SHA-256 of the code and active", hash, state)
	}
}

func TestInviteCodeNormalizationIsForgiving(t *testing.T) {
	t.Parallel()
	code := "ABCDEFGHIJKLMNOPQRSTUVWX"
	for _, in := range []string{"abcd-efgh-ijkl-mnop-qrst-uvwx", " ABCD EFGH\tIJKL\nMNOP_QRST-UVWX "} {
		if NormalizeInviteCode(in) != code {
			t.Fatalf("NormalizeInviteCode(%q) = %q", in, NormalizeInviteCode(in))
		}
	}
	if InviteCodeHash(" - ") != nil {
		t.Fatal("a code that normalizes to nothing hashes to something")
	}
}

func TestAReviewInviteCarriesNoAddress(t *testing.T) {
	t.Parallel()
	pool := pgtest.New(t)
	if _, err := MintInvite(bgctx, pool, MintOptions{Review: true}); err != nil {
		t.Fatal(err)
	}
	if _, err := MintInvite(bgctx, pool, MintOptions{Review: true, EmailTag: authtest.RandBytesTB(t, 32)}); err == nil {
		t.Fatal("an addressed review invite was accepted")
	}
}

func TestTheInviteCodeSourceIsCryptoRand(t *testing.T) {
	t.Parallel()
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, "../invites/invites.go", nil, 0)
	if err != nil {
		t.Fatal(err)
	}

	imports := map[string]bool{}
	for _, spec := range file.Imports {
		path, err := strconv.Unquote(spec.Path.Value)
		if err != nil {
			t.Fatal(err)
		}
		if spec.Name != nil && spec.Name.Name != "rand" && path == "crypto/rand" {
			t.Fatalf("crypto/rand is imported as %q; this test reads call sites by the name "+
				"`rand`, so rename it back or teach this test the alias", spec.Name.Name)
		}
		imports[path] = true
	}
	if !imports["crypto/rand"] {
		t.Fatal("invite.go does not import crypto/rand: an invite code minted from anything " +
			"else is reproducible by whoever knows the seed, and 403 not_invited tells them " +
			"when they have it right")
	}
	for _, bad := range []string{"math/rand", "math/rand/v2"} {
		if imports[bad] {
			t.Fatalf("invite.go imports %s", bad)
		}
	}

	var mint *ast.FuncDecl
	for _, d := range file.Decls {
		if fn, ok := d.(*ast.FuncDecl); ok && fn.Name.Name == "NewCode" {
			mint = fn
		}
	}
	if mint == nil {
		t.Fatal("invites.go declares no NewCode")
	}
	found := false
	ast.Inspect(mint.Body, func(n ast.Node) bool {
		call, ok := n.(*ast.CallExpr)
		if !ok {
			return true
		}
		sel, ok := call.Fun.(*ast.SelectorExpr)
		if !ok {
			return true
		}
		if pkg, ok := sel.X.(*ast.Ident); ok && pkg.Name == "rand" && sel.Sel.Name == "Read" {
			found = true
		}
		return true
	})
	if !found {
		t.Fatal("NewCode never calls rand.Read: crypto/rand is imported and unused for the " +
			"one value that has to be unpredictable")
	}
}

func TestMintedInviteCodesAreUnguessable(t *testing.T) {
	t.Parallel()
	pool := pgtest.New(t)

	const (
		sample    = 256
		wantChars = 24
		wantBytes = 15
		wantBits  = 120
	)

	codes := make([]string, 0, sample)
	decoded := make([][]byte, 0, sample)
	for i := 0; i < sample; i++ {
		codes = append(codes, mintCode(t, pool, ""))
	}

	const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
	for _, code := range codes {
		if len(code) != wantChars {
			t.Fatalf("code %q is %d characters, want %d: %d bits of entropy, not %d",
				code, len(code), wantChars, len(code)*5, wantBits)
		}
		for _, r := range code {
			if !strings.ContainsRune(alphabet, r) {
				t.Fatalf("code %q contains %q, which is not in the base32 alphabet %q "+
					"— the alphabet is narrower than it claims, or the encoding changed",
					code, r, alphabet)
			}
		}
		if NormalizeInviteCode(code) != code {
			t.Fatalf("NormalizeInviteCode(%q) = %q: a minted code is not in the form it is "+
				"redeemed in", code, NormalizeInviteCode(code))
		}
		raw, err := base32.StdEncoding.WithPadding(base32.NoPadding).DecodeString(code)
		if err != nil {
			t.Fatalf("minted code %q does not decode as base32: %v", code, err)
		}
		if len(raw)*8 != wantBits {
			t.Fatalf("code %q carries %d bits, want %d", code, len(raw)*8, wantBits)
		}
		decoded = append(decoded, raw)
	}

	for i := 0; i < wantBytes; i++ {
		seen := map[byte]bool{}
		for _, raw := range decoded {
			seen[raw[i]] = true
		}
		if len(seen) < 64 {
			t.Fatalf("byte %d of the code took only %d distinct values across %d mints: that "+
				"byte is not random, so the code is far short of %d bits",
				i, len(seen), sample, wantBits)
		}
	}
	for i := 0; i < wantChars; i++ {
		seen := map[byte]bool{}
		for _, code := range codes {
			seen[code[i]] = true
		}
		if len(seen) < 16 {
			t.Fatalf("character %d took only %d distinct values across %d mints; the alphabet "+
				"at that position is %d symbols wide, not 32", i, len(seen), sample, len(seen))
		}
	}

	const maxShared = 6
	for i := 0; i < len(decoded); i++ {
		for j := i + 1; j < len(decoded); j++ {
			shared := 0
			for k := 0; k < wantBytes; k++ {
				if decoded[i][k] == decoded[j][k] {
					shared++
				}
			}
			if shared > maxShared {
				t.Fatalf("codes %d and %d share %d of %d bytes (%q vs %q): these codes are "+
					"related to each other, which is what a counter or a seeded PRNG looks like",
					i, j, shared, wantBytes, codes[i], codes[j])
			}
		}
	}

	seen := map[string]bool{}
	for _, code := range codes {
		if seen[code] {
			t.Fatalf("minted %q twice in %d mints", code, sample)
		}
		seen[code] = true
	}
}
