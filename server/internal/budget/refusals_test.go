package budget

import (
	"reflect"
	"regexp"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

func TestCountRefusalsAcceptsEveryResourceTheClosedSetAllows(t *testing.T) {
	pool := pgtest.New(t)
	u := newUser(t, pool)
	for _, res := range refusalResources {
		if err := CountRefusals(bg, pool, u, res, 1); err != nil {
			t.Fatalf("CountRefusals(%s): %v", res, err)
		}
	}
	got := refusals(t, pool, u)
	if len(got) != len(refusalResources) {
		t.Fatalf("account_refusals holds %d resources, want %d: %v", len(got), len(refusalResources), got)
	}
	for _, res := range refusalResources {
		if got[res] != 1 {
			t.Fatalf("account_refusals[%s] = %d, want 1", res, got[res])
		}
	}
}

func TestTheAllowlistIsExactlyTheDatabasesClosedSet(t *testing.T) {
	pool := pgtest.New(t)
	var def string
	if err := pool.QueryRow(bg,
		`SELECT pg_get_constraintdef(oid) FROM pg_constraint
		  WHERE conname = 'account_refusals_resource_is_closed'`).Scan(&def); err != nil {
		t.Fatal(err)
	}
	var inDB []string
	for _, m := range regexp.MustCompile(`'([a-z_]+)'`).FindAllStringSubmatch(def, -1) {
		inDB = append(inDB, m[1])
	}
	if len(inDB) == 0 {
		t.Fatalf("read no resources out of the constraint: %q", def)
	}
	want := slices.Clone(refusalResources)
	slices.Sort(want)
	slices.Sort(inDB)
	if !slices.Equal(want, inDB) {
		t.Fatalf("budget's allowlist is %v, the CHECK constraint is %v — the two must change together",
			want, inDB)
	}
}

func TestCountRefusalsRefusesWhatItCannotRecord(t *testing.T) {
	pool := pgtest.New(t)
	u := newUser(t, pool)
	if err := CountRefusals(bg, pool, u, "disk_bytes", 1); err == nil {
		t.Fatal("a resource outside the closed set was accepted; the database would have refused it " +
			"inside a retry loop instead")
	}
	if err := CountRefusals(bg, pool, uuid.Nil, ResourceHeadroom, 1); err == nil {
		t.Fatal("a zero user was accepted")
	}
	if err := CountRefusals(bg, nil, u, ResourceHeadroom, 1); err == nil {
		t.Fatal("a nil pool was accepted")
	}
	if err := CountRefusals(bg, pool, u, ResourceHeadroom, 0); err != nil {
		t.Fatalf("n = 0 must be a no-op: %v", err)
	}
	if got := refusals(t, pool, u); len(got) != 0 {
		t.Fatalf("account_refusals = %v after only rejected calls, want empty", got)
	}
}

func TestARefusalForAPurgedAccountIsSkippedRatherThanFailed(t *testing.T) {
	pool := pgtest.New(t)
	u := newUser(t, pool)
	if _, err := pool.Exec(bg, `DELETE FROM users WHERE id = $1`, u); err != nil {
		t.Fatal(err)
	}
	if err := CountRefusals(bg, pool, u, ResourceHeadroom, 3); err != nil {
		t.Fatalf("a refusal for a purged account = %v, want it silently skipped", err)
	}
	if got := refusals(t, pool, u); len(got) != 0 {
		t.Fatalf("a row was written for an account that no longer exists: %v", got)
	}
}

func TestCountRefusalsAccumulates(t *testing.T) {
	pool := pgtest.New(t)
	u := newUser(t, pool)
	if err := CountRefusals(bg, pool, u, ResourceHeadroom, 7); err != nil {
		t.Fatal(err)
	}
	if err := CountRefusals(bg, pool, u, ResourceHeadroom, 5); err != nil {
		t.Fatal(err)
	}
	if got := refusals(t, pool, u)[ResourceHeadroom]; got != 12 {
		t.Fatalf("account_refusals[headroom] = %d, want 12", got)
	}
}

func TestBothRefusalPathsShareTheDatabasesDay(t *testing.T) {
	pool := pgtest.New(t)
	g := New(pool)
	setDefaultLimit(t, pool, 1)
	u := newUser(t, pool)

	if err := admit(t, g, u, ResourceOplogHotBytes, 2); err == nil {
		t.Fatal("want a refusal")
	}
	if err := CountRefusals(bg, pool, u, ResourceHeadroom, 1); err != nil {
		t.Fatal(err)
	}

	var dbDay time.Time
	if err := pool.QueryRow(bg, `SELECT (now() AT TIME ZONE 'UTC')::date`).Scan(&dbDay); err != nil {
		t.Fatal(err)
	}
	rows, err := pool.Query(bg, `SELECT resource, day FROM account_refusals WHERE user_id = $1`, u)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var seen int
	for rows.Next() {
		var res string
		var day time.Time
		if err := rows.Scan(&res, &day); err != nil {
			t.Fatal(err)
		}
		seen++
		if !day.Equal(dbDay) {
			t.Fatalf("%s was stamped %s, but the database's UTC day is %s",
				res, day.Format(time.DateOnly), dbDay.Format(time.DateOnly))
		}
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	if seen != 2 {
		t.Fatalf("%d refusal rows, want 2 (one from each path)", seen)
	}
}

func TestTheDayOverrideIsOffUnlessATestSetsIt(t *testing.T) {
	pool := pgtest.New(t)
	if got := New(pool).overrideDay(); got != nil {
		t.Fatalf("New returned a gate with a day override of %q; production must use the database's day",
			*got)
	}
	g := New(pool)
	g.now = func() time.Time { return time.Date(2026, 8, 2, 1, 30, 0, 0, time.UTC) }
	if got := g.overrideDay(); got == nil || *got != "2026-08-02" {
		t.Fatalf("overrideDay = %v, want 2026-08-02", got)
	}
}

func TestCountRefusalsTakesAPoolAndNotATransaction(t *testing.T) {
	if got := reflect.TypeOf(CountRefusals).String(); !strings.Contains(got, "*pgxpool.Pool") {
		t.Fatalf("CountRefusals takes %s; a receipt written in the caller's transaction is "+
			"rolled back with it and counted nowhere", got)
	}
}
