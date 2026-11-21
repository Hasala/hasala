package api

import (
	"net/http"
	"testing"
)

func TestHealthzIsUnauthenticatedAndReportsTheDatabase(t *testing.T) {
	h := newHarness(t)

	w := h.req(http.MethodGet, "/api/v1/healthz", "", nil)
	wantStatus(t, w, http.StatusOK)

	got := decodeJSON[map[string]any](t, w)
	if got["status"] != "ok" {
		t.Fatalf(`status = %v, want "ok" (body %s)`, got["status"], w.Body.String())
	}
	if got["db"] != "ok" {
		t.Fatalf(`db = %v, want "ok" (body %s)`, got["db"], w.Body.String())
	}
	if ct := w.Header().Get("Content-Type"); ct != "application/json" {
		t.Fatalf("Content-Type = %q, want application/json", ct)
	}
	if cc := w.Header().Get("Cache-Control"); cc == "" {
		t.Fatal("no Cache-Control header")
	}
}

func TestHealthzLeaksNothingButTwoWords(t *testing.T) {
	h := newHarness(t)

	w := h.req(http.MethodGet, "/api/v1/healthz", "", nil)
	wantStatus(t, w, http.StatusOK)

	got := decodeJSON[map[string]any](t, w)
	if len(got) != 2 {
		t.Fatalf("healthz returned %d fields (%s), want exactly status and db", len(got), w.Body.String())
	}
}

func TestHealthzReports503WhenTheDatabaseIsGone(t *testing.T) {
	h := newHarness(t)
	h.pool.Close()

	w := h.req(http.MethodGet, "/api/v1/healthz", "", nil)
	wantStatus(t, w, http.StatusServiceUnavailable)

	got := decodeJSON[map[string]any](t, w)
	if got["status"] != "degraded" || got["db"] != "down" {
		t.Fatalf("body = %s, want status=degraded db=down", w.Body.String())
	}
}

func TestHealthzIsGETOnly(t *testing.T) {
	h := newHarness(t)

	w := h.req(http.MethodPost, "/api/v1/healthz", "", nil)
	if w.Code == http.StatusOK {
		t.Fatalf("POST /api/v1/healthz returned 200; it must not be a write surface")
	}
}
