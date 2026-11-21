package verify

import (
	"strings"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/blob"
	"github.com/salehtl/hasala/server/internal/budget"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

func ledgerAmount(t *testing.T, pool *pgxpool.Pool, u uuid.UUID, resource string) (int64, bool) {
	t.Helper()
	rows, err := pool.Query(bg,
		`SELECT amount FROM account_usage WHERE user_id = $1 AND resource = $2`, u, resource)
	if err != nil {
		t.Fatalf("read usage: %v", err)
	}
	defer rows.Close()
	if !rows.Next() {
		return 0, false
	}
	var amount int64
	if err := rows.Scan(&amount); err != nil {
		t.Fatalf("read usage: %v", err)
	}
	return amount, true
}

func storedBytes(t *testing.T, pool *pgxpool.Pool, u uuid.UUID, stream string) int64 {
	t.Helper()
	var n int64
	if err := pool.QueryRow(bg,
		`SELECT coalesce(sum(octet_length(blob)), 0)::bigint FROM op_log
		  WHERE user_id = $1 AND stream = $2`, u, stream).Scan(&n); err != nil {
		t.Fatalf("stored bytes: %v", err)
	}
	return n
}

func usageFindings(t *testing.T, pool *pgxpool.Pool, users ...uuid.UUID) []Finding {
	t.Helper()
	f, err := UsageLedgerFor(bg, pool, users)
	if err != nil {
		t.Fatalf("UsageLedgerFor: %v", err)
	}
	return f
}

func findingFor(t *testing.T, f []Finding, u uuid.UUID, resource string) Finding {
	t.Helper()
	var out []Finding
	for _, x := range f {
		if x.UserID == u && strings.HasPrefix(x.Detail, resource+":") {
			out = append(out, x)
		}
	}
	if len(out) != 1 {
		t.Fatalf("want exactly one %s finding for %s, got %d: %+v", resource, u, len(out), f)
	}
	return out[0]
}

func TestTheLedgerReconcilesAgainstARealAppend(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	appendPairs(t, pool, u, 3)

	if f := usageFindings(t, pool, u); len(f) != 0 {
		t.Fatalf("a log written by the appender itself does not reconcile: %+v", f)
	}

	hot, ok := ledgerAmount(t, pool, u, budget.ResourceOplogHotBytes)
	if !ok {
		t.Fatal("the appender charged nothing: there is no oplog_hot_bytes row at all")
	}
	if want := storedBytes(t, pool, u, blob.StreamHot); hot != want {
		t.Fatalf("ledger holds %d hot bytes, stored rows total %d", hot, want)
	}
	if hot != 6*1024 {
		t.Fatalf("hot usage is %d bytes, want the six padded frames' 6144", hot)
	}
}

func TestUsageDriftIsReportedInBothDirectionsWithBothNumbers(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	appendHot(t, pool, u, 2)
	actual := storedBytes(t, pool, u, blob.StreamHot)

	exec(t, pool, `UPDATE account_usage SET amount = $2 WHERE user_id = $1 AND resource = 'oplog_hot_bytes'`,
		u, actual+1000)
	high := findingFor(t, usageFindings(t, pool, u), u, budget.ResourceOplogHotBytes)
	if high.ID != U1UsageDrift {
		t.Fatalf("finding id = %q, want %s", high.ID, U1UsageDrift)
	}
	for _, want := range []string{"too HIGH", "1000"} {
		if !strings.Contains(high.Detail, want) {
			t.Fatalf("a ledger 1000 bytes over reality reads %q, which does not contain %q", high.Detail, want)
		}
	}

	exec(t, pool, `UPDATE account_usage SET amount = $2 WHERE user_id = $1 AND resource = 'oplog_hot_bytes'`,
		u, actual-500)
	low := findingFor(t, usageFindings(t, pool, u), u, budget.ResourceOplogHotBytes)
	for _, want := range []string{"too LOW", "500"} {
		if !strings.Contains(low.Detail, want) {
			t.Fatalf("a ledger 500 bytes under reality reads %q, which does not contain %q", low.Detail, want)
		}
	}
}

func TestStoredBytesWithNoLedgerRowAreDrift(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	appendPairs(t, pool, u, 2)
	exec(t, pool, `DELETE FROM account_usage WHERE user_id = $1`, u)

	f := usageFindings(t, pool, u)
	if len(f) != 1 {
		t.Fatalf("want one finding for the deleted ledger row, got %d: %+v", len(f), f)
	}
	hot := findingFor(t, f, u, budget.ResourceOplogHotBytes)
	if !strings.Contains(hot.Detail, "the ledger says 0 bytes") {
		t.Fatalf("a missing row does not read as zero: %q", hot.Detail)
	}
	if !strings.Contains(hot.Detail, "too LOW") {
		t.Fatalf("a missing row with stored bytes must read LOW: %q", hot.Detail)
	}
}

func TestAnAccountWithNothingStoredIsSilent(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	if f := usageFindings(t, pool, u); len(f) != 0 {
		t.Fatalf("an empty account produced findings: %+v", f)
	}
	exec(t, pool, `INSERT INTO account_usage (user_id, resource, amount)
	  VALUES ($1, 'oplog_hot_bytes', 0)`, u)
	if f := usageFindings(t, pool, u); len(f) != 0 {
		t.Fatalf("a zero ledger row on an empty account produced findings: %+v", f)
	}
}

func TestUsageReconciliationCanBeScopedToOneAccount(t *testing.T) {
	pool := pgtest.New(t)
	a, b := insertUser(t, pool), insertUser(t, pool)
	for _, u := range []uuid.UUID{a, b} {
		appendHot(t, pool, u, 1)
		exec(t, pool, `UPDATE account_usage SET amount = amount + 7
		                WHERE user_id = $1 AND resource = 'oplog_hot_bytes'`, u)
	}
	if f := usageFindings(t, pool, a); len(f) != 1 || f[0].UserID != a {
		t.Fatalf("scoping to one account returned %+v", f)
	}
	if f := usageFindings(t, pool); len(f) != 2 {
		t.Fatalf("unscoped, both accounts must be reported, got %+v", f)
	}
}

func TestRepairSetsEachDriftingRowToItsRecomputedTotal(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	appendPairs(t, pool, u, 2)
	hot := storedBytes(t, pool, u, blob.StreamHot)

	exec(t, pool, `UPDATE account_usage SET amount = amount + 4096
	                WHERE user_id = $1 AND resource = 'oplog_hot_bytes'`, u)

	corrections, err := RepairUsageLedger(bg, pool, []uuid.UUID{u})
	if err != nil {
		t.Fatalf("RepairUsageLedger: %v", err)
	}
	if len(corrections) != 1 {
		t.Fatalf("want a correction for the drifting row, got %d: %+v", len(corrections), corrections)
	}
	for _, c := range corrections {
		switch c.Resource {
		case budget.ResourceOplogHotBytes:
			if c.From != hot+4096 || c.To != hot {
				t.Fatalf("hot correction %+v, want from %d to %d", c, hot+4096, hot)
			}
		default:
			t.Fatalf("unexpected correction %+v", c)
		}
	}
	if f := usageFindings(t, pool, u); len(f) != 0 {
		t.Fatalf("the ledger still drifts after a repair: %+v", f)
	}
	exec(t, pool, `DELETE FROM account_usage WHERE user_id = $1`, u)
	if _, err := RepairUsageLedger(bg, pool, []uuid.UUID{u}); err != nil {
		t.Fatalf("RepairUsageLedger: %v", err)
	}
	if got, _ := ledgerAmount(t, pool, u, budget.ResourceOplogHotBytes); got != hot {
		t.Fatalf("the recreated row holds %d after the repair, want %d", got, hot)
	}
}

func TestRepairLeavesACorrectLedgerUntouched(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	appendHot(t, pool, u, 2)

	var before string
	if err := pool.QueryRow(bg,
		`SELECT max(updated_at)::text FROM account_usage WHERE user_id = $1`, u).Scan(&before); err != nil {
		t.Fatal(err)
	}
	corrections, err := RepairUsageLedger(bg, pool, []uuid.UUID{u})
	if err != nil {
		t.Fatalf("RepairUsageLedger: %v", err)
	}
	if len(corrections) != 0 {
		t.Fatalf("a correct ledger was 'repaired': %+v", corrections)
	}
	var after string
	if err := pool.QueryRow(bg,
		`SELECT max(updated_at)::text FROM account_usage WHERE user_id = $1`, u).Scan(&after); err != nil {
		t.Fatal(err)
	}
	if before != after {
		t.Fatalf("the repair rewrote a correct row: updated_at moved from %s to %s", before, after)
	}
}

func TestRepairSkipsARowThatStoppedDriftingBeforeItsTurn(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	appendHot(t, pool, u, 1)

	stale := drift{UserID: u, Resource: budget.ResourceOplogHotBytes, Ledger: 999999, Actual: 0}
	c, ok, err := repairOne(bg, pool, stale)
	if err != nil {
		t.Fatalf("repairOne: %v", err)
	}
	if ok {
		t.Fatalf("a row that no longer drifts was rewritten and reported as %+v", c)
	}
	if got, _ := ledgerAmount(t, pool, u, budget.ResourceOplogHotBytes); got != storedBytes(t, pool, u, blob.StreamHot) {
		t.Fatalf("the ledger holds %d after a skipped repair", got)
	}
}

func TestRepairSkipsAnAccountThatWasPurgedMidRun(t *testing.T) {
	pool := pgtest.New(t)
	gone := uuid.New()
	c, ok, err := repairOne(bg, pool, drift{
		UserID: gone, Resource: budget.ResourceOplogHotBytes, Ledger: 0, Actual: 4096,
	})
	if err != nil {
		t.Fatalf("repairing a deleted account is an error rather than a skip: %v", err)
	}
	if ok {
		t.Fatalf("a usage row was written for an account that does not exist: %+v", c)
	}
}

func TestTheReconciliationReportsAndDoesNotRepair(t *testing.T) {
	pool := pgtest.New(t)
	u := insertUser(t, pool)
	appendHot(t, pool, u, 1)
	exec(t, pool, `UPDATE account_usage SET amount = 999999 WHERE user_id = $1 AND resource = 'oplog_hot_bytes'`, u)

	if f := usageFindings(t, pool, u); len(f) != 1 {
		t.Fatalf("want one finding, got %+v", f)
	}
	if got, _ := ledgerAmount(t, pool, u, budget.ResourceOplogHotBytes); got != 999999 {
		t.Fatalf("the report changed the ledger: amount is now %d, want the drifting 999999", got)
	}
	if f := usageFindings(t, pool, u); len(f) != 1 {
		t.Fatalf("the second run reads %+v; a report that heals hides the bug it found", f)
	}
}

func TestTheReconciledResourceNamesAreTheLedgersOwn(t *testing.T) {
	if got := "oplog_" + blob.StreamHot + "_bytes"; got != budget.ResourceOplogHotBytes {
		t.Errorf("the hot stream builds %q, the ledger holds %q", got, budget.ResourceOplogHotBytes)
	}
	if got := streamForResource(budget.ResourceOplogHotBytes); got != blob.StreamHot {
		t.Errorf("streamForResource(hot bytes) = %q, want %q", got, blob.StreamHot)
	}
	if len(repairable) != 1 || repairable[0] != budget.ResourceOplogHotBytes || usageUnit(repairable[0]) != "bytes" {
		t.Errorf("repairable = %v, want exactly the one ledger resource, in bytes", repairable)
	}
}
