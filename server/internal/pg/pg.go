package pg

import (
	"context"
	"database/sql"
	"embed"
	"errors"
	"fmt"
	"strconv"
	"sync"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"
)

//go:embed migrations/*.sql
var migrations embed.FS

var gooseMu sync.Mutex

func Open(ctx context.Context, dsn string) (*pgxpool.Pool, error) {
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, fmt.Errorf("parse dsn: %w", err)
	}
	cfg.MaxConns = 16
	cfg.MinConns = 2
	return pgxpool.NewWithConfig(ctx, cfg)
}

func LogIdentity(ctx context.Context, pool *pgxpool.Pool) (string, error) {
	var oid uint32
	if err := pool.QueryRow(ctx, `SELECT 'public.op_log'::regclass::oid`).Scan(&oid); err != nil {
		return "", fmt.Errorf("read the op log's identity: %w", err)
	}
	return strconv.FormatUint(uint64(oid), 10), nil
}

func Migrate(ctx context.Context, pool *pgxpool.Pool) error {
	return withGoose(pool, func(db *sql.DB) error { return goose.UpContext(ctx, db, "migrations") })
}

func MigrateTo(ctx context.Context, pool *pgxpool.Pool, version int64) error {
	return withGoose(pool, func(db *sql.DB) error { return goose.UpToContext(ctx, db, "migrations", version) })
}

func MigrateDown(ctx context.Context, pool *pgxpool.Pool) error {
	return withGoose(pool, func(db *sql.DB) error { return goose.DownToContext(ctx, db, "migrations", 0) })
}

func MigrateDownTo(ctx context.Context, pool *pgxpool.Pool, version int64) error {
	return withGoose(pool, func(db *sql.DB) error { return goose.DownToContext(ctx, db, "migrations", version) })
}

func withGoose(pool *pgxpool.Pool, run func(*sql.DB) error) error {
	gooseMu.Lock()
	defer gooseMu.Unlock()
	goose.SetBaseFS(migrations)
	if err := goose.SetDialect("postgres"); err != nil {
		return err
	}
	db := stdlib.OpenDBFromPool(pool)
	defer db.Close()
	return run(db)
}

func EmbeddedVersions() ([]int64, error) {
	gooseMu.Lock()
	defer gooseMu.Unlock()
	goose.SetBaseFS(migrations)
	ms, err := goose.CollectMigrations("migrations", 0, goose.MaxVersion)
	if err != nil {
		return nil, err
	}
	out := make([]int64, len(ms))
	for i, m := range ms {
		out[i] = m.Version
	}
	return out, nil
}

func LatestEmbedded() (int64, error) {
	vs, err := EmbeddedVersions()
	if err != nil {
		return 0, err
	}
	if len(vs) == 0 {
		return 0, errors.New("pg: no embedded migrations")
	}
	return vs[len(vs)-1], nil
}

func AppliedVersion(ctx context.Context, pool *pgxpool.Pool) (int64, error) {
	v, _, err := appliedVersion(ctx, pool)
	return v, err
}

func appliedVersion(ctx context.Context, pool *pgxpool.Pool) (version int64, ledger bool, err error) {
	if err := pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_class c
		JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
		WHERE n.nspname = 'public' AND c.relname = 'goose_db_version')`).Scan(&ledger); err != nil {
		return 0, false, fmt.Errorf("pg: look for goose_db_version: %w", err)
	}
	if !ledger {
		return 0, false, nil
	}
	var v *int64
	if err := pool.QueryRow(ctx,
		`SELECT max(version_id) FROM goose_db_version WHERE is_applied`).Scan(&v); err != nil {
		return 0, true, fmt.Errorf("pg: read goose_db_version: %w", err)
	}
	if v == nil {
		return 0, true, nil
	}
	return *v, true, nil
}

func Pending(ctx context.Context, pool *pgxpool.Pool) (int, error) {
	applied, ledger, err := appliedVersion(ctx, pool)
	if err != nil || !ledger {
		return 0, err
	}
	vs, err := EmbeddedVersions()
	if err != nil {
		return 0, err
	}
	n := 0
	for _, v := range vs {
		if v > applied {
			n++
		}
	}
	return n, nil
}
