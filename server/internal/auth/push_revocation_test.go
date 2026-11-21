package auth

import (
	"crypto/sha256"
	"encoding/hex"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/authtest"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

func registerPushToken(t *testing.T, pool *pgxpool.Pool, u uuid.UUID, writerID, sessionToken, token string) {
	t.Helper()
	sum := sha256.Sum256([]byte(token))
	if _, err := pool.Exec(bgctx,
		`INSERT INTO apns_tokens (user_id, writer_id, session_hash, token_hex, environment, created_at, updated_at)
		 VALUES ($1, $2, $3, $4, 'production', now(), now())`,
		u, writerID, SessionHash(sessionToken), hex.EncodeToString(sum[:])); err != nil {
		t.Fatal(err)
	}
}

func pushTokenCount(t *testing.T, pool *pgxpool.Pool, u uuid.UUID) int {
	t.Helper()
	return countRows(t, pool, `SELECT count(*) FROM apns_tokens WHERE user_id = $1`, u)
}

func plantWriter(t *testing.T, pool *pgxpool.Pool, u uuid.UUID) string {
	t.Helper()
	d := authtest.NewDevice(t)
	if _, err := pool.Exec(bgctx,
		`INSERT INTO writers (user_id, writer_id, alg, pubkey, dak_pubkey, registered_at) VALUES ($1, $2, 'ed25519', $3, $4, now())`,
		u, d.WriterID, d.DWKPub(), d.DAKPub()); err != nil {
		t.Fatal(err)
	}
	return d.WriterID
}

func TestRevokingASessionStopsThatDevicesNotifications(t *testing.T) {
	pool := pgtest.New(t)
	c := newClock()
	sessions := newSessions(pool, time.Hour, c)
	u := newTestUser(t, pool)

	phone, tablet := plantWriter(t, pool, u), plantWriter(t, pool, u)

	phoneSess, err := sessions.Issue(bgctx, u)
	if err != nil {
		t.Fatal(err)
	}
	tabletSess, err := sessions.Issue(bgctx, u)
	if err != nil {
		t.Fatal(err)
	}
	registerPushToken(t, pool, u, phone, phoneSess, "ExponentPushToken[phone000phone000phon]")
	registerPushToken(t, pool, u, tablet, tabletSess, "ExponentPushToken[tablet00tablet00tabl]")

	if err := sessions.Revoke(bgctx, phoneSess); err != nil {
		t.Fatal(err)
	}
	if got := countRows(t, pool,
		`SELECT count(*) FROM apns_tokens WHERE user_id = $1 AND writer_id = $2`, u, phone); got != 0 {
		t.Fatalf("the signed-out device still has %d push token(s)", got)
	}
	if got := countRows(t, pool,
		`SELECT count(*) FROM apns_tokens WHERE user_id = $1 AND writer_id = $2`, u, tablet); got != 1 {
		t.Fatalf("signing out one device stopped another's notifications (%d left)", got)
	}
	if err := sessions.Revoke(bgctx, phoneSess); err != nil {
		t.Fatalf("re-revoking: %v", err)
	}
}

func TestSignOutEverywhereStopsEveryDevicesNotifications(t *testing.T) {
	pool := pgtest.New(t)
	c := newClock()
	sessions := newSessions(pool, time.Hour, c)

	a := newTestUser(t, pool)
	b := newTestUser(t, pool)

	for _, u := range []uuid.UUID{a, b} {
		d := plantWriter(t, pool, u)
		sess, err := sessions.Issue(bgctx, u)
		if err != nil {
			t.Fatal(err)
		}
		registerPushToken(t, pool, u, d, sess, "ExponentPushToken["+u.String()[:20]+"]")
	}

	if err := sessions.RevokeAllForUser(bgctx, a); err != nil {
		t.Fatal(err)
	}
	if got := pushTokenCount(t, pool, a); got != 0 {
		t.Fatalf("sign-out-everywhere left %d push token(s) receiving", got)
	}
	if got := pushTokenCount(t, pool, b); got != 1 {
		t.Fatalf("one user's sign-out-everywhere removed another user's push token (%d left)", got)
	}
}

func TestSessionHashIsTheStoredForm(t *testing.T) {
	const tok = "a-session-token"
	if got, want := SessionHash(tok), tokenHash(tok); string(got) != string(want) {
		t.Fatalf("SessionHash disagrees with the form Sessions persists")
	}
	if string(SessionHash(tok)) == tok {
		t.Fatal("SessionHash returned the token itself")
	}
}
