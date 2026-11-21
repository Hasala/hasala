package budget

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

const (
	ResourceOplogHotBytes = "oplog_hot_bytes"
)

const (
	ResourceUploadBytes = "upload_bytes"
	ResourceHeadroom    = "headroom"
	ResourceSuspended   = "suspended"
)

var refusalResources = []string{
	ResourceOplogHotBytes,
	ResourceUploadBytes,
	ResourceHeadroom, ResourceSuspended,
}

type family struct {
	limitColumn string
	members     []string
}

var families = map[string]family{
	ResourceOplogHotBytes: {
		limitColumn: "oplog_bytes",
		members:     []string{ResourceOplogHotBytes},
	},
}

var ErrRefused = errors.New("budget: refused")

var ErrLedgerUnderflow = errors.New("budget: ledger underflow")

type RefusedError struct {
	UserID   uuid.UUID
	Resource string
	Have     int64
	Delta    int64
	Limit    int64
}

func (e *RefusedError) Error() string {
	return fmt.Sprintf("budget: refused: %s holds %d of %d for %s and asked for %d more",
		e.UserID, e.Have, e.Limit, e.Resource, e.Delta)
}

func (e *RefusedError) Is(target error) bool { return target == ErrRefused }

type Gate struct {
	Pool *pgxpool.Pool
	now  func() time.Time
}

func New(pool *pgxpool.Pool) *Gate { return &Gate{Pool: pool} }

func (g *Gate) Admit(ctx context.Context, tx pgx.Tx, userID uuid.UUID, resource string, delta int64) error {
	if g == nil || g.Pool == nil {
		return errors.New("budget: admit: gate has no pool")
	}
	if tx == nil {
		return errors.New("budget: admit: no transaction")
	}
	if userID == uuid.Nil {
		return errors.New("budget: admit: user_id is zero")
	}
	fam, ok := families[resource]
	if !ok {
		return fmt.Errorf("budget: admit: unknown resource %q", resource)
	}
	if delta == 0 {
		return nil
	}

	limit, err := g.limitFor(ctx, tx, userID, fam)
	if err != nil {
		return err
	}

	if _, err := tx.Exec(ctx,
		`INSERT INTO account_usage (user_id, resource)
		 SELECT $1, r FROM unnest($2::text[]) AS r
		 ON CONFLICT (user_id, resource) DO NOTHING`, userID, fam.members); err != nil {
		return fmt.Errorf("budget: admit: ensure usage rows for %s: %w", userID, err)
	}

	amounts, err := g.lockFamily(ctx, tx, userID, fam)
	if err != nil {
		return err
	}
	var have int64
	for _, m := range fam.members {
		have += amounts[m]
	}
	next := amounts[resource] + delta
	if next < 0 {
		return fmt.Errorf("%w: %s holds %d of %s and a release of %d was asked for",
			ErrLedgerUnderflow, userID, amounts[resource], resource, -delta)
	}
	if delta > 0 && have+delta > limit {
		return &RefusedError{UserID: userID, Resource: resource, Have: have, Delta: delta, Limit: limit}
	}

	if _, err := tx.Exec(ctx,
		`UPDATE account_usage SET amount = $3, updated_at = now()
		  WHERE user_id = $1 AND resource = $2`, userID, resource, next); err != nil {
		return fmt.Errorf("budget: admit: update %s for %s: %w", resource, userID, err)
	}
	return nil
}

func (g *Gate) Usage(ctx context.Context, userID uuid.UUID, resource string) (int64, error) {
	if g == nil || g.Pool == nil {
		return 0, errors.New("budget: usage: gate has no pool")
	}
	var amount int64
	err := g.Pool.QueryRow(ctx,
		`SELECT coalesce(max(amount), 0) FROM account_usage WHERE user_id = $1 AND resource = $2`,
		userID, resource).Scan(&amount)
	if err != nil {
		return 0, fmt.Errorf("budget: usage: %s for %s: %w", resource, userID, err)
	}
	return amount, nil
}

func (g *Gate) limitFor(ctx context.Context, tx pgx.Tx, userID uuid.UUID, fam family) (int64, error) {
	var limit int64
	err := tx.QueryRow(ctx,
		`SELECT `+fam.limitColumn+` FROM account_limits
		  WHERE user_id = $1 OR user_id IS NULL
		  ORDER BY user_id NULLS LAST LIMIT 1`, userID).Scan(&limit)
	if errors.Is(err, pgx.ErrNoRows) {
		return 0, fmt.Errorf("budget: admit: no policy row for %s and no default in account_limits", userID)
	}
	if err != nil {
		return 0, fmt.Errorf("budget: admit: read limit %s for %s: %w", fam.limitColumn, userID, err)
	}
	return limit, nil
}

func (g *Gate) lockFamily(ctx context.Context, tx pgx.Tx, userID uuid.UUID, fam family) (map[string]int64, error) {
	rows, err := tx.Query(ctx,
		`SELECT resource, amount FROM account_usage
		  WHERE user_id = $1 AND resource = ANY($2::text[])
		  ORDER BY resource FOR UPDATE`, userID, fam.members)
	if err != nil {
		return nil, fmt.Errorf("budget: admit: lock usage rows for %s: %w", userID, err)
	}
	defer rows.Close()
	amounts := make(map[string]int64, len(fam.members))
	for rows.Next() {
		var res string
		var amount int64
		if err := rows.Scan(&res, &amount); err != nil {
			return nil, fmt.Errorf("budget: admit: scan usage row for %s: %w", userID, err)
		}
		amounts[res] = amount
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("budget: admit: read usage rows for %s: %w", userID, err)
	}
	for _, m := range fam.members {
		if _, ok := amounts[m]; !ok {
			return nil, fmt.Errorf("budget: admit: usage row %s is missing for %s", m, userID)
		}
	}
	return amounts, nil
}

func (g *Gate) RecordRefusal(ctx context.Context, err error) error {
	var refused *RefusedError
	if !errors.As(err, &refused) {
		return err
	}
	if g == nil || g.Pool == nil {
		return errors.Join(err, errors.New("budget: refusal: gate has no pool"))
	}
	if rerr := g.recordRefusal(ctx, refused.UserID, refused.Resource); rerr != nil {
		return errors.Join(err, rerr)
	}
	return err
}

func (g *Gate) recordRefusal(ctx context.Context, userID uuid.UUID, resource string) error {
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
	defer cancel()
	return countRefusals(ctx, g.Pool, userID, resource, 1, g.overrideDay())
}

func (g *Gate) overrideDay() *string {
	if g.now == nil {
		return nil
	}
	day := g.now().UTC().Format("2006-01-02")
	return &day
}

func CountRefusals(ctx context.Context, pool *pgxpool.Pool, userID uuid.UUID, resource string, n int64) error {
	return countRefusals(ctx, pool, userID, resource, n, nil)
}

func countRefusals(ctx context.Context, pool *pgxpool.Pool, userID uuid.UUID, resource string, n int64, day *string) error {
	if pool == nil {
		return errors.New("budget: refusal: no pool")
	}
	if userID == uuid.Nil {
		return errors.New("budget: refusal: user_id is zero")
	}
	if !slices.Contains(refusalResources, resource) {
		return fmt.Errorf("budget: refusal: unknown resource %q", resource)
	}
	if n <= 0 {
		return nil
	}
	_, err := pool.Exec(ctx,
		`INSERT INTO account_refusals (user_id, day, resource, count)
		 SELECT $1, coalesce($4::date, (now() AT TIME ZONE 'UTC')::date), $2, $3
		  WHERE EXISTS (SELECT 1 FROM users WHERE id = $1)
		 ON CONFLICT (user_id, day, resource)
		 DO UPDATE SET count = account_refusals.count + EXCLUDED.count`,
		userID, resource, n, day)
	if err != nil {
		return fmt.Errorf("budget: refusal: count %s for %s: %w", resource, userID, err)
	}
	return nil
}
