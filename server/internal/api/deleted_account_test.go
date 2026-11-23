package api

import (
	"net/http"
	"testing"
	"time"

	"github.com/salehtl/hasala/server/internal/purge"
)

func TestADeletedAccountAnswers410AndAnExpiredSessionStill401(t *testing.T) {
	t.Parallel()
	h := newHarness(t)
	u := h.user("sub-doomed")
	tok := h.session(u)
	wantStatus(t, h.req("GET", "/api/v1/writers", tok, nil), http.StatusOK)

	if _, err := purge.Purge(bg, h.pool, u); err != nil {
		t.Fatalf("purge: %v", err)
	}

	w := h.req("GET", "/api/v1/writers", tok, nil)
	wantStatus(t, w, http.StatusGone)
	if got := w.Body.String(); got != `{"error":"account_deleted"}` {
		t.Fatalf("body = %s, want the byte-identical account_deleted answer", got)
	}
	for _, path := range []string{"/api/v1/sync?stream=hot", "/api/v1/sync/hashes?stream=hot", "/api/v1/key-history"} {
		if code := h.req("GET", path, tok, nil).Code; code != http.StatusGone {
			t.Fatalf("%s answered %d, want 410", path, code)
		}
	}
}

func TestAnExpiredSessionIsStillA401(t *testing.T) {
	t.Parallel()
	h := newHarness(t)
	u := h.user("sub-expiring")
	tok := h.session(u)
	wantStatus(t, h.req("GET", "/api/v1/writers", tok, nil), http.StatusOK)

	if _, err := h.pool.Exec(bg,
		`UPDATE sessions SET created_at = $1, expires_at = $2 WHERE user_id = $3`,
		time.Now().Add(-2*time.Hour), time.Now().Add(-time.Hour), u); err != nil {
		t.Fatal(err)
	}
	w := h.req("GET", "/api/v1/writers", tok, nil)
	wantStatus(t, w, http.StatusUnauthorized)
	if got := w.Body.String(); got != `{"error":"unauthorized"}` {
		t.Fatalf("the 401 body changed to %q", got)
	}
}

func TestAnUnknownTokenIsA401(t *testing.T) {
	t.Parallel()
	h := newHarness(t)
	w := h.req("GET", "/api/v1/writers", "not-a-token-anyone-issued", nil)
	wantStatus(t, w, http.StatusUnauthorized)
}
