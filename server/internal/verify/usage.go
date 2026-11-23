package verify

import (
	"context"
	"errors"
	"fmt"
	"slices"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/budget"
)

const usageScope = `(coalesce(cardinality($1::uuid[]), 0) = 0 OR user_id = ANY($1::uuid[]))`

const usageDriftSQL = `
WITH truth AS (
        SELECT user_id, 'oplog_' || stream || '_bytes' AS resource,
               sum(octet_length(blob))::bigint AS amount
          FROM op_log WHERE ` + usageScope + `
         GROUP BY user_id, stream
),
ledger AS (
   SELECT user_id, resource, amount FROM account_usage WHERE ` + usageScope + `
)
SELECT coalesce(t.user_id, l.user_id), coalesce(t.resource, l.resource),
       coalesce(l.amount, 0), coalesce(t.amount, 0)
  FROM truth t FULL JOIN ledger l ON l.user_id = t.user_id AND l.resource = t.resource
 WHERE coalesce(l.amount, 0) <> coalesce(t.amount, 0)
 ORDER BY 1, 2`

type drift struct {
	UserID   uuid.UUID
	Resource string
	Ledger   int64
	Actual   int64
}

type Correction struct {
	UserID   uuid.UUID `json:"user_id"`
	Resource string    `json:"resource"`
	From     int64     `json:"from"`
	To       int64     `json:"to"`
}

func UsageLedger(ctx context.Context, pool *pgxpool.Pool) ([]Finding, error) {
	return UsageLedgerFor(ctx, pool, nil)
}

func UsageLedgerFor(ctx context.Context, pool *pgxpool.Pool, users []uuid.UUID) ([]Finding, error) {
	drifts, err := usageDrift(ctx, pool, users)
	if err != nil {
		return nil, err
	}
	out := make([]Finding, 0, len(drifts))
	for _, d := range drifts {
		if len(out) >= maxFindings {
			out = append(out, truncated())
			break
		}
		out = append(out, Finding{ID: U1UsageDrift, UserID: d.UserID, Detail: d.detail()})
	}
	return out, nil
}

func usageDrift(ctx context.Context, pool *pgxpool.Pool, users []uuid.UUID) ([]drift, error) {
	if pool == nil {
		return nil, errors.New("verify: pool is nil")
	}
	if users == nil {
		users = []uuid.UUID{}
	}
	rows, err := pool.Query(ctx, usageDriftSQL, users)
	if err != nil {
		return nil, fmt.Errorf("verify: usage ledger: %w", err)
	}
	out, err := pgx.CollectRows(rows, pgx.RowToStructByPos[drift])
	if err != nil {
		return nil, fmt.Errorf("verify: usage ledger: %w", err)
	}
	return out, nil
}

func (d drift) detail() string {
	unit := usageUnit(d.Resource)
	if d.Ledger > d.Actual {
		return fmt.Sprintf(
			"%s: the ledger says %d %s and the stored rows total %d, so it is %d too HIGH — "+
				"this account is charged for space it does not hold and will be refused writes early. "+
				"Recompute it with `hasalad verify usage --repair`.",
			d.Resource, d.Ledger, unit, d.Actual, d.Ledger-d.Actual)
	}
	return fmt.Sprintf(
		"%s: the ledger says %d %s and the stored rows total %d, so it is %d too LOW — "+
			"this account holds space nobody is charged for, which is budget the ceiling "+
			"cannot see. Recompute it with `hasalad verify usage --repair`.",
		d.Resource, d.Ledger, unit, d.Actual, d.Actual-d.Ledger)
}

func usageUnit(string) string { return "bytes" }

var repairable = []string{budget.ResourceOplogHotBytes}

func RepairUsageLedger(ctx context.Context, pool *pgxpool.Pool, users []uuid.UUID) ([]Correction, error) {
	drifts, err := usageDrift(ctx, pool, users)
	if err != nil {
		return nil, err
	}
	var out []Correction
	for _, d := range drifts {
		if !slices.Contains(repairable, d.Resource) {
			continue
		}
		c, ok, err := repairOne(ctx, pool, d)
		if err != nil {
			return out, err
		}
		if ok {
			out = append(out, c)
		}
	}
	return out, nil
}

func repairOne(ctx context.Context, pool *pgxpool.Pool, d drift) (Correction, bool, error) {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return Correction{}, false, fmt.Errorf("verify: repair usage ledger: %w", err)
	}
	defer tx.Rollback(ctx)

	if _, err := tx.Exec(ctx,
		`INSERT INTO account_usage (user_id, resource) VALUES ($1, $2) ON CONFLICT DO NOTHING`,
		d.UserID, d.Resource); err != nil {
		var pge *pgconn.PgError
		if errors.As(err, &pge) && pge.Code == "23503" {
			return Correction{}, false, nil
		}
		return Correction{}, false, fmt.Errorf("verify: repair usage ledger: ensure %s for %s: %w",
			d.Resource, d.UserID, err)
	}

	var have int64
	err = tx.QueryRow(ctx,
		`SELECT amount FROM account_usage WHERE user_id = $1 AND resource = $2 FOR UPDATE`,
		d.UserID, d.Resource).Scan(&have)
	if errors.Is(err, pgx.ErrNoRows) {
		return Correction{}, false, nil
	}
	if err != nil {
		return Correction{}, false, fmt.Errorf("verify: repair usage ledger: lock %s for %s: %w",
			d.Resource, d.UserID, err)
	}

	actual, err := usageTruth(ctx, tx, d.UserID, d.Resource)
	if err != nil {
		return Correction{}, false, err
	}
	if actual == have {
		return Correction{}, false, nil
	}
	if _, err := tx.Exec(ctx,
		`UPDATE account_usage SET amount = $3, updated_at = now()
		  WHERE user_id = $1 AND resource = $2`, d.UserID, d.Resource, actual); err != nil {
		return Correction{}, false, fmt.Errorf("verify: repair usage ledger: write %s for %s: %w",
			d.Resource, d.UserID, err)
	}
	if err := tx.Commit(ctx); err != nil {
		return Correction{}, false, fmt.Errorf("verify: repair usage ledger: commit %s for %s: %w",
			d.Resource, d.UserID, err)
	}
	return Correction{UserID: d.UserID, Resource: d.Resource, From: have, To: actual}, true, nil
}

func usageTruth(ctx context.Context, tx pgx.Tx, userID uuid.UUID, resource string) (int64, error) {
	var (
		sql    string
		args   = []any{userID}
		amount int64
	)
	switch resource {
	case budget.ResourceOplogHotBytes:
		sql = `SELECT coalesce(sum(octet_length(blob)), 0)::bigint FROM op_log
		        WHERE user_id = $1 AND stream = $2`
		args = append(args, streamForResource(resource))
	default:
		return 0, fmt.Errorf("verify: repair usage ledger: %q is not a ledger resource", resource)
	}
	if err := tx.QueryRow(ctx, sql, args...).Scan(&amount); err != nil {
		return 0, fmt.Errorf("verify: repair usage ledger: recompute %s for %s: %w",
			resource, userID, err)
	}
	return amount, nil
}

func streamForResource(string) string { return "hot" }
