package auth

import (
	"errors"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/pgtest"
)

func TestASessionOfADeletedAccountIsDistinguishableFromAnExpiredOne(t *testing.T) {
	t.Parallel()
	pool := pgtest.New(t)
	u := newTestUser(t, pool)
	c := newClock()
	s := newSessions(pool, time.Hour, c)

	tok, err := s.Issue(bgctx, u)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Resolve(bgctx, tok); err != nil {
		t.Fatalf("a fresh session did not resolve: %v", err)
	}

	if _, err := pool.Exec(bgctx, `DELETE FROM users WHERE id = $1`, u); err != nil {
		t.Fatal(err)
	}
	var sessions int
	if err := pool.QueryRow(bgctx, `SELECT count(*) FROM sessions`).Scan(&sessions); err != nil {
		t.Fatal(err)
	}
	if sessions != 0 {
		t.Fatalf("%d session rows survived the account: the cascade this test is about did not happen", sessions)
	}

	if _, err := s.Resolve(bgctx, tok); !errors.Is(err, ErrSessionAccountDeleted) {
		t.Fatalf("err = %v, want ErrSessionAccountDeleted", err)
	}
	if _, err := s.Resolve(bgctx, tok); !errors.Is(err, ErrSessionInvalid) {
		t.Fatal("ErrSessionAccountDeleted does not wrap ErrSessionInvalid")
	}
}

func TestAnExpiredSessionIsNotReportedAsADeletedAccount(t *testing.T) {
	t.Parallel()
	pool := pgtest.New(t)
	u := newTestUser(t, pool)
	c := newClock()
	s := newSessions(pool, time.Hour, c)

	tok, err := s.Issue(bgctx, u)
	if err != nil {
		t.Fatal(err)
	}
	c.advance(2 * time.Hour)
	if _, err := s.Resolve(bgctx, tok); !errors.Is(err, ErrSessionExpired) {
		t.Fatalf("err = %v, want ErrSessionExpired", err)
	}
}

func TestAnUnknownTokenIsNotReportedAsADeletedAccount(t *testing.T) {
	t.Parallel()
	pool := pgtest.New(t)
	c := newClock()
	s := newSessions(pool, time.Hour, c)
	if _, err := s.Resolve(bgctx, "not-a-token-anyone-ever-issued"); !errors.Is(err, ErrSessionUnknown) {
		t.Fatalf("err = %v, want ErrSessionUnknown", err)
	}
}

func TestTheTombstoneStopsAnsweringOnceTheSessionWouldHaveExpired(t *testing.T) {
	t.Parallel()
	pool := pgtest.New(t)
	u := newTestUser(t, pool)
	c := newClock()
	s := newSessions(pool, time.Hour, c)

	tok, err := s.Issue(bgctx, u)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(bgctx, `DELETE FROM users WHERE id = $1`, u); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Resolve(bgctx, tok); !errors.Is(err, ErrSessionAccountDeleted) {
		t.Fatalf("err = %v, want ErrSessionAccountDeleted while the session is live", err)
	}
	c.advance(2 * time.Hour)
	if _, err := s.Resolve(bgctx, tok); !errors.Is(err, ErrSessionUnknown) {
		t.Fatalf("err = %v, want ErrSessionUnknown once the session's own expiry passed", err)
	}
}

func TestTombstoneExpiryIsDecidedByTheSessionsClock(t *testing.T) {
	t.Parallel()
	pool := pgtest.New(t)
	u := newTestUser(t, pool)
	c := newSkewedClock(-2 * time.Hour)
	s := newSessions(pool, time.Hour, c)

	tok, err := s.Issue(bgctx, u)
	if err != nil {
		t.Fatal(err)
	}
	var dbSaysExpired bool
	if err := pool.QueryRow(bgctx,
		`SELECT bool_and(expires_at < now()) FROM sessions WHERE user_id = $1`, u).Scan(&dbSaysExpired); err != nil {
		t.Fatal(err)
	}
	if !dbSaysExpired {
		t.Fatal("Postgres does not consider this session expired: the two clocks agree, " +
			"so this run cannot see the defect it exists to catch")
	}
	if _, err := pool.Exec(bgctx, `DELETE FROM users WHERE id = $1`, u); err != nil {
		t.Fatal(err)
	}

	var rows int
	if err := pool.QueryRow(bgctx, `SELECT count(*) FROM deleted_account_sessions`).Scan(&rows); err != nil {
		t.Fatal(err)
	}
	if rows != 1 {
		t.Fatalf("%d tombstones, want 1: the trigger judged expiry by Postgres's clock", rows)
	}
	if _, err := s.Resolve(bgctx, tok); !errors.Is(err, ErrSessionAccountDeleted) {
		t.Fatalf("err = %v, want ErrSessionAccountDeleted: the session is live by the clock that decides", err)
	}
}

func newSkewedClock(skew time.Duration) *clock {
	return &clock{t: time.Now().UTC().Add(skew)}
}

func TestATombstoneOutlivesADisagreementBetweenTheGoAndPostgresClocks(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name string
		skew time.Duration
	}{
		{"ledgerd 31 days behind postgres", -31 * 24 * time.Hour},
		{"ledgerd 90 days behind postgres", -90 * 24 * time.Hour},
		{"ledgerd 90 days ahead of postgres", 90 * 24 * time.Hour},
	} {
		t.Run(tc.name, func(t *testing.T) {
			pool := pgtest.New(t)
			u := newTestUser(t, pool)
			c := newSkewedClock(tc.skew)
			s := newSessions(pool, time.Hour, c)

			tok, err := s.Issue(bgctx, u)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := pool.Exec(bgctx, `DELETE FROM users WHERE id = $1`, u); err != nil {
				t.Fatal(err)
			}

			var rows int
			if err := pool.QueryRow(bgctx, `SELECT count(*) FROM deleted_account_sessions`).Scan(&rows); err != nil {
				t.Fatal(err)
			}
			if rows != 1 {
				t.Fatalf("%d tombstones, want 1: a second clock decided this row's fate", rows)
			}
			if _, err := s.Resolve(bgctx, tok); !errors.Is(err, ErrSessionAccountDeleted) {
				t.Fatalf("err = %v, want ErrSessionAccountDeleted: the session is live by the clock that decides", err)
			}
		})
	}
}

func TestDeletingOneAccountDoesNotReapAnotherAccountsTombstone(t *testing.T) {
	t.Parallel()
	pool := pgtest.New(t)
	c := newSkewedClock(-90 * 24 * time.Hour)
	s := newSessions(pool, time.Hour, c)

	first := newTestUser(t, pool)
	firstTok, err := s.Issue(bgctx, first)
	if err != nil {
		t.Fatal(err)
	}
	second := newTestUser(t, pool)
	if _, err := s.Issue(bgctx, second); err != nil {
		t.Fatal(err)
	}

	if _, err := pool.Exec(bgctx, `DELETE FROM users WHERE id = $1`, first); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(bgctx, `DELETE FROM users WHERE id = $1`, second); err != nil {
		t.Fatal(err)
	}

	var rows int
	if err := pool.QueryRow(bgctx, `SELECT count(*) FROM deleted_account_sessions`).Scan(&rows); err != nil {
		t.Fatal(err)
	}
	if rows != 2 {
		t.Fatalf("%d tombstones, want 2: deleting one account reaped another's", rows)
	}
	if _, err := s.Resolve(bgctx, firstTok); !errors.Is(err, ErrSessionAccountDeleted) {
		t.Fatalf("err = %v, want ErrSessionAccountDeleted for the FIRST account's device", err)
	}
}

func TestTheTombstoneCarriesNoIdentity(t *testing.T) {
	t.Parallel()
	pool := pgtest.New(t)
	u := newTestUser(t, pool)
	c := newClock()
	s := newSessions(pool, time.Hour, c)
	if _, err := s.Issue(bgctx, u); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(bgctx, `DELETE FROM users WHERE id = $1`, u); err != nil {
		t.Fatal(err)
	}

	rows, err := pool.Query(bgctx,
		`SELECT column_name FROM information_schema.columns
		  WHERE table_schema = 'public' AND table_name = 'deleted_account_sessions'
		  ORDER BY column_name`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var cols []string
	for rows.Next() {
		var c string
		if err := rows.Scan(&c); err != nil {
			t.Fatal(err)
		}
		cols = append(cols, c)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	want := map[string]bool{"token_hash": true, "deleted_at": true, "expires_at": true}
	for _, c := range cols {
		if !want[c] {
			t.Fatalf("deleted_account_sessions has column %q: the tombstone must outlive an account "+
				"without describing one", c)
		}
	}
	if len(cols) != len(want) {
		t.Fatalf("columns = %v, want exactly %v", cols, want)
	}
}

func TestReapingTombstonesUsesTheSessionsClockAndSparesRowsInsideTheGrace(t *testing.T) {
	t.Parallel()
	pool := pgtest.New(t)
	c := newSkewedClock(90 * 24 * time.Hour)
	s := newSessions(pool, time.Hour, c)

	uA := newTestUser(t, pool)
	tokA, err := s.Issue(bgctx, uA)
	if err != nil {
		t.Fatal(err)
	}

	c.advance(tombstoneGrace + 2*time.Hour)
	uB := newTestUser(t, pool)
	tokB, err := s.Issue(bgctx, uB)
	if err != nil {
		t.Fatal(err)
	}

	c.advance(2 * time.Hour)
	uC := newTestUser(t, pool)
	tokC, err := s.Issue(bgctx, uC)
	if err != nil {
		t.Fatal(err)
	}

	for _, u := range []uuid.UUID{uA, uB, uC} {
		if _, err := pool.Exec(bgctx, `DELETE FROM users WHERE id = $1`, u); err != nil {
			t.Fatal(err)
		}
	}
	if got := countTombstones(t, pool); got != 3 {
		t.Fatalf("%d tombstones before the sweep, want 3", got)
	}

	var postgresWouldReap int
	if err := pool.QueryRow(bgctx,
		`SELECT count(*) FROM deleted_account_sessions WHERE expires_at < now() - interval '30 days'`,
	).Scan(&postgresWouldReap); err != nil {
		t.Fatal(err)
	}
	if postgresWouldReap != 0 {
		t.Fatalf("a Postgres-clock sweep would reap %d of these rows; this run cannot tell the "+
			"two clocks apart", postgresWouldReap)
	}

	n, err := s.ReapDeletedAccountTombstones(bgctx)
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("reaped %d rows, want exactly 1 (only A is past its grace)", n)
	}

	if tombstoneExists(t, pool, tokA) {
		t.Fatal("A's tombstone survived: the table is not bounded at all")
	}
	if !tombstoneExists(t, pool, tokB) {
		t.Fatal("B's tombstone was reaped an hour after its session expired: the grace is not honoured")
	}
	if !tombstoneExists(t, pool, tokC) {
		t.Fatal("C's tombstone was reaped while its session is still LIVE: a deleted account now " +
			"answers 401, which is the answer a device must not wipe on")
	}
	if _, err := s.Resolve(bgctx, tokC); !errors.Is(err, ErrSessionAccountDeleted) {
		t.Fatalf("err = %v, want ErrSessionAccountDeleted: the sweep broke the row that still answers", err)
	}

	again, err := s.ReapDeletedAccountTombstones(bgctx)
	if err != nil {
		t.Fatal(err)
	}
	if again != 0 {
		t.Fatalf("a second sweep reaped %d more rows, want 0", again)
	}
	if got := countTombstones(t, pool); got != 2 {
		t.Fatalf("%d tombstones after two sweeps, want 2", got)
	}
}

func TestTheTombstoneGraceIsAFiniteWindowPastExpiry(t *testing.T) {
	t.Parallel()
	if tombstoneGrace <= 0 {
		t.Fatalf("tombstoneGrace = %v: the sweep would reap rows the moment they expire", tombstoneGrace)
	}
	if tombstoneGrace > 365*24*time.Hour {
		t.Fatalf("tombstoneGrace = %v: a bound this loose does not bound the table", tombstoneGrace)
	}
}

func countTombstones(t *testing.T, pool *pgxpool.Pool) int {
	t.Helper()
	var n int
	if err := pool.QueryRow(bgctx, `SELECT count(*) FROM deleted_account_sessions`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

func tombstoneExists(t *testing.T, pool *pgxpool.Pool, token string) bool {
	t.Helper()
	var n int
	if err := pool.QueryRow(bgctx,
		`SELECT count(*) FROM deleted_account_sessions WHERE token_hash = $1`,
		tokenHash(token)).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n == 1
}
