package api

import (
	"crypto/rand"
	"encoding/base64"
	"net/http"
	"testing"

	"github.com/google/uuid"
)

func randomBody(t *testing.T, n int) []byte {
	t.Helper()
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		t.Fatal(err)
	}
	return b
}

func (h *harness) suspend(u uuid.UUID) {
	h.t.Helper()
	if _, err := h.pool.Exec(bg, `UPDATE users SET status = 'suspended', suspended_at = now() WHERE id = $1`, u); err != nil {
		h.t.Fatalf("suspend %s: %v", u, err)
	}
}

func (h *harness) resume(u uuid.UUID) {
	h.t.Helper()
	if _, err := h.pool.Exec(bg, `UPDATE users SET status = 'active', suspended_at = NULL WHERE id = $1`, u); err != nil {
		h.t.Fatalf("resume %s: %v", u, err)
	}
}

func TestASuspendedAccountIsRefusedOnEveryWriteMethod(t *testing.T) {
	t.Parallel()
	h := newHarness(t)
	u := h.user("suspended-writes")
	tok := h.session(u)
	h.suspend(u)

	for _, tc := range []struct {
		method, path string
		body         any
	}{
		{http.MethodPost, "/api/v1/sync", UploadRequest{WriterID: "ios-00000000-0000-4000-8000-000000000207", Stream: "hot"}},
		{http.MethodPost, "/api/v1/writers/challenge", nil},
		{http.MethodPost, "/api/v1/account/bootstrap", map[string]any{}},
		{http.MethodDelete, "/api/v1/keys/wraps", map[string]any{}},
	} {
		w := h.req(tc.method, tc.path, tok, tc.body)
		if w.Code != http.StatusForbidden {
			t.Errorf("%s %s: %d, want 403 (body %s)", tc.method, tc.path, w.Code, w.Body)
			continue
		}
		if got := decodeJSON[errorBody](t, w).Error; got != "account_suspended" {
			t.Errorf("%s %s: error = %q, want account_suspended", tc.method, tc.path, got)
		}
	}
}

func TestASuspendedAccountCanStillRead(t *testing.T) {
	t.Parallel()
	h := newHarness(t)
	u := h.user("suspended-reads")
	tok := h.session(u)
	h.seed(u, 2)
	h.suspend(u)

	for _, p := range []string{
		"/api/v1/sync?stream=hot",
		"/api/v1/sync/hashes?stream=hot",
		"/api/v1/writers",
	} {
		if w := h.req(http.MethodGet, p, tok, nil); w.Code != http.StatusOK {
			t.Errorf("GET %s while suspended: %d, want 200 (body %s)", p, w.Code, w.Body)
		}
	}
	pull := decodeJSON[PullResponse](t, h.req(http.MethodGet, "/api/v1/sync?stream=hot", tok, nil))
	if len(pull.Rows) == 0 {
		t.Fatal("a suspended account pulled zero rows; its own history must stay readable")
	}
}

func TestASuspendedAccountCanStillSignIn(t *testing.T) {
	t.Parallel()
	h := newHarness(t).passkeys()
	a, registered := h.register(h.invite(""))
	u := uuid.MustParse(registered.UserID)
	h.suspend(u)

	id, opts := h.beginAssert("/api/v1/auth/passkey/login/begin", "")
	w := h.req(http.MethodPost, "/api/v1/auth/passkey/login/finish", "", PasskeyFinishRequest{
		CeremonyID: id, Credential: a.Assert(t, opts, 5),
	})
	if w.Code != http.StatusOK {
		t.Fatalf("passkey login for a suspended account: %d %s", w.Code, w.Body)
	}
	res := decodeJSON[SessionResponse](t, w)
	if res.SessionToken == "" {
		t.Fatal("login returned no session token")
	}
	if res.UserID != u.String() {
		t.Fatalf("login resolved %s, want %s", res.UserID, u)
	}
	if w := h.req(http.MethodGet, "/api/v1/writers", res.SessionToken, nil); w.Code != http.StatusOK {
		t.Fatalf("the new session cannot read: %d %s", w.Code, w.Body)
	}
	if w := h.req(http.MethodPost, "/api/v1/writers/challenge", res.SessionToken, nil); w.Code != http.StatusForbidden {
		t.Fatalf("the new session could write: %d %s", w.Code, w.Body)
	}
}

func TestASuspendedAccountCanStillSignOut(t *testing.T) {
	t.Parallel()
	h := newHarness(t)
	u := h.user("suspended-signout")
	tok := h.session(u)
	h.suspend(u)
	wantStatus(t, h.req(http.MethodPost, "/api/v1/auth/logout", tok, nil), http.StatusNoContent)
	wantStatus(t, h.req(http.MethodGet, "/api/v1/writers", tok, nil), http.StatusUnauthorized)
}

func TestResumingRestoresWriteAccess(t *testing.T) {
	t.Parallel()
	h := newHarness(t)
	u := h.user("resume-restores")
	tok := h.session(u)

	h.suspend(u)
	if w := h.req(http.MethodPost, "/api/v1/writers/challenge", tok, nil); w.Code != http.StatusForbidden {
		t.Fatalf("suspended: %d %s, want 403", w.Code, w.Body)
	}
	h.resume(u)
	if w := h.req(http.MethodPost, "/api/v1/writers/challenge", tok, nil); w.Code != http.StatusOK {
		t.Fatalf("resumed: %d %s, want 200", w.Code, w.Body)
	}
}

func TestAnActiveAccountWrites(t *testing.T) {
	t.Parallel()
	h := newHarness(t)
	u := h.user("active-writes")
	tok := h.session(u)
	if w := h.req(http.MethodPost, "/api/v1/writers/challenge", tok, nil); w.Code != http.StatusOK {
		t.Fatalf("an active account was refused: %d %s", w.Code, w.Body)
	}
}

type fakeFuse struct{ tripped bool }

func (f *fakeFuse) Tripped() bool { return f.tripped }

func TestTheHeadroomFuseRefusesWritesAndPermitsReads(t *testing.T) {
	t.Parallel()
	h := newHarness(t)
	fuse := &fakeFuse{}
	h.srv.Headroom = fuse
	h.h = h.srv.Handler()

	u := h.user("headroom")
	tok := h.session(u)
	h.seed(u, 1)

	if w := h.req(http.MethodPost, "/api/v1/writers/challenge", tok, nil); w.Code != http.StatusOK {
		t.Fatalf("untripped write: %d %s", w.Code, w.Body)
	}

	fuse.tripped = true

	for _, tc := range []struct {
		method, path string
		token        string
		body         any
	}{
		{http.MethodPost, "/api/v1/sync", tok, UploadRequest{WriterID: "ios-00000000-0000-4000-8000-000000000207", Stream: "hot"}},
		{http.MethodPost, "/api/v1/writers/challenge", tok, nil},
		{http.MethodPost, "/api/v1/auth/logout", "", nil},
	} {
		w := h.req(tc.method, tc.path, tc.token, tc.body)
		if w.Code != http.StatusServiceUnavailable {
			t.Errorf("%s %s while tripped: %d, want 503 (body %s)", tc.method, tc.path, w.Code, w.Body)
			continue
		}
		if got := decodeJSON[errorBody](t, w).Error; got != "no_headroom" {
			t.Errorf("%s %s: error = %q, want no_headroom", tc.method, tc.path, got)
		}
		if got := w.Header().Get("Retry-After"); got == "" {
			t.Errorf("%s %s: no Retry-After on a temporary refusal", tc.method, tc.path)
		}
	}

	for _, p := range []string{"/api/v1/sync?stream=hot", "/api/v1/writers", "/api/v1/healthz"} {
		if w := h.req(http.MethodGet, p, tok, nil); w.Code != http.StatusOK {
			t.Errorf("GET %s while tripped: %d, want 200 (body %s)", p, w.Code, w.Body)
		}
	}

	fuse.tripped = false
	if w := h.req(http.MethodPost, "/api/v1/writers/challenge", tok, nil); w.Code != http.StatusOK {
		t.Fatalf("cleared fuse: %d %s, want 200", w.Code, w.Body)
	}
}

func TestNoFuseMeansNoGate(t *testing.T) {
	t.Parallel()
	h := newHarness(t)
	if h.srv.Headroom != nil {
		t.Fatal("the default server has a fuse; it must be opt-in")
	}
	u := h.user("no-fuse")
	if w := h.req(http.MethodPost, "/api/v1/writers/challenge", h.session(u), nil); w.Code != http.StatusOK {
		t.Fatalf("write with no fuse: %d %s", w.Code, w.Body)
	}
}

func TestTheUploadLimiterChargesBytesNotRequests(t *testing.T) {
	t.Parallel()
	const budget = 40 << 10

	h := newHarness(t)
	h.srv.SyncPerUser = NewLimiter(0, 1000, 16, h.srv.now)
	h.srv.SyncUploadBytes = NewLimiter(0, budget, 16, h.srv.now)
	h.h = h.srv.Handler()
	u := h.user("bytes-small")
	tok := h.session(u)
	h.writer(u, "ios-00000000-0000-4000-8000-000000000203")

	var prev [32]byte
	small := 0
	for i := int64(1); i <= 20; i++ {
		blobs, next := uploadChain(t, u, "ios-00000000-0000-4000-8000-000000000203", i, prev, 1)
		w := h.req(http.MethodPost, "/api/v1/sync", tok, UploadRequest{
			WriterID: "ios-00000000-0000-4000-8000-000000000203", Stream: "hot", Blobs: blobs,
		})
		if w.Code != http.StatusOK {
			t.Fatalf("small upload %d refused: %d %s", i, w.Code, w.Body)
		}
		prev = next
		small++
	}
	if small != 20 {
		t.Fatalf("only %d small uploads landed", small)
	}

	h2 := newHarness(t)
	h2.srv.SyncPerUser = NewLimiter(0, 1000, 16, h2.srv.now)
	h2.srv.SyncUploadBytes = NewLimiter(0, budget, 16, h2.srv.now)
	h2.h = h2.srv.Handler()
	u2 := h2.user("bytes-large")
	tok2 := h2.session(u2)
	h2.writer(u2, "ios-00000000-0000-4000-8000-000000000204")

	big, _ := sealUpload(t, u2, "ios-00000000-0000-4000-8000-000000000204", 1, [32]byte{}, string(randomBody(t, budget+1<<10)))
	w := h2.req(http.MethodPost, "/api/v1/sync", tok2, UploadRequest{
		WriterID: "ios-00000000-0000-4000-8000-000000000204", Stream: "hot", Blobs: []UploadBlob{big},
	})
	if w.Code != http.StatusTooManyRequests {
		t.Fatalf("one oversized upload: %d %s, want 429 on the BYTE budget", w.Code, w.Body)
	}
	if got := decodeJSON[errorBody](t, w).Error; got != "upload_bytes" {
		t.Fatalf("error = %q, want upload_bytes", got)
	}
	if got := w.Header().Get("Retry-After"); got == "" {
		t.Error("no Retry-After on a byte-budget refusal")
	}
	if n := countRows(t, h2.pool, u2); n != 0 {
		t.Fatalf("%d rows stored by a refused upload", n)
	}
}

func TestTheUploadRequestLimiterIsSeparateFromTheByteBudget(t *testing.T) {
	t.Parallel()
	h := newHarness(t)
	h.srv.SyncPerUser = NewLimiter(0, 2, 16, h.srv.now)
	h.srv.SyncUploadBytes = NewLimiter(0, 1<<30, 16, h.srv.now)
	h.h = h.srv.Handler()
	u := h.user("request-budget")
	tok := h.session(u)
	h.writer(u, "ios-00000000-0000-4000-8000-000000000201")

	var prev [32]byte
	for i := int64(1); i <= 2; i++ {
		blobs, next := uploadChain(t, u, "ios-00000000-0000-4000-8000-000000000201", i, prev, 1)
		if w := h.req(http.MethodPost, "/api/v1/sync", tok, UploadRequest{
			WriterID: "ios-00000000-0000-4000-8000-000000000201", Stream: "hot", Blobs: blobs,
		}); w.Code != http.StatusOK {
			t.Fatalf("upload %d: %d %s", i, w.Code, w.Body)
		}
		prev = next
	}
	blobs, _ := uploadChain(t, u, "ios-00000000-0000-4000-8000-000000000201", 3, prev, 1)
	w := h.req(http.MethodPost, "/api/v1/sync", tok, UploadRequest{
		WriterID: "ios-00000000-0000-4000-8000-000000000201", Stream: "hot", Blobs: blobs,
	})
	if w.Code != http.StatusTooManyRequests {
		t.Fatalf("third upload: %d %s, want 429", w.Code, w.Body)
	}
	if got := decodeJSON[errorBody](t, w).Error; got != "rate_limited" {
		t.Fatalf("error = %q, want rate_limited (the REQUEST budget, not the byte one)", got)
	}
}

func TestARejectedUploadCostsNoByteBudget(t *testing.T) {
	t.Parallel()
	const budget = 128 << 10
	h := newHarness(t)
	h.srv.SyncPerUser = NewLimiter(0, 1000, 16, h.srv.now)
	h.srv.SyncUploadBytes = NewLimiter(0, budget, 16, h.srv.now)
	h.h = h.srv.Handler()
	u := h.user("garbage")
	tok := h.session(u)
	h.writer(u, "ios-00000000-0000-4000-8000-000000000202")

	junk := UploadBlob{
		WriterCounter: "1",
		PrevHash:      "00",
		BlobHash:      "00",
		TypeFlag:      "edit",
		Blob:          base64.StdEncoding.EncodeToString(randomBody(t, 8<<10)),
	}
	for i := 0; i < 20; i++ {
		if w := h.req(http.MethodPost, "/api/v1/sync", tok, UploadRequest{
			WriterID: "ios-00000000-0000-4000-8000-000000000202", Stream: "hot", Blobs: []UploadBlob{junk},
		}); w.Code == http.StatusOK {
			t.Fatalf("a malformed batch was accepted")
		}
	}

	big, _ := sealUpload(t, u, "ios-00000000-0000-4000-8000-000000000202", 1, [32]byte{}, string(randomBody(t, 32<<10)))
	if w := h.req(http.MethodPost, "/api/v1/sync", tok, UploadRequest{
		WriterID: "ios-00000000-0000-4000-8000-000000000202", Stream: "hot", Blobs: []UploadBlob{big},
	}); w.Code != http.StatusOK {
		t.Fatalf("a large valid upload after twenty rejected ones: %d %s", w.Code, w.Body)
	}
}

func TestTheUploadByteBudgetIsSizedAgainstTheLargestUpload(t *testing.T) {
	t.Parallel()
	const maxDurablePerUpload = maxUploadBlobs * (1 << 20)
	if syncByteBurst <= maxDurablePerUpload {
		t.Fatalf("the byte burst (%d) is not larger than one maximal upload (%d): "+
			"such a request could never be admitted", syncByteBurst, maxDurablePerUpload)
	}
	if perDay := syncByteRate * 86400; perDay != 256<<20 {
		t.Fatalf("the sustained budget is %.0f bytes/day, want 256 MiB", perDay)
	}
}
