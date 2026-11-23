package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"

	"github.com/salehtl/hasala/server/internal/config"
	"github.com/salehtl/hasala/server/internal/pg"
)

func runMigrate(env *runEnv, args []string) error {
	var a config.MigrateArgs
	fs := newFlags(env, "migrate")
	fs.BoolVar(&a.Status, "status", false, "print the applied and embedded versions and exit")
	fs.BoolVar(&a.Pending, "pending", false, "print the number of unapplied migrations and exit (read-only)")
	fs.Int64Var(&a.To, "to", 0, "migrate up to and including this version")
	if err := parseFlags(fs, args); err != nil {
		return err
	}
	if fs.NArg() > 0 {
		return refusal{fmt.Errorf("migrate takes no positional arguments, got %q", fs.Arg(0))}
	}
	if a.Status && a.Pending {
		return refusal{errors.New("--status and --pending are alternatives")}
	}
	if a.To < 0 {
		return refusal{errors.New("--to must be a positive version")}
	}
	if a.To != 0 && (a.Status || a.Pending) {
		return refusal{errors.New("--to migrates up to a version; it cannot go with --status or --pending")}
	}
	cfg, err := env.load("migrate", func(c *config.Config) { c.Migrate = a })
	if err != nil {
		return err
	}
	ctx := context.Background()
	dsn := cfg.MigrateDSN
	if dsn == "" {
		dsn = cfg.PGDSN
	}
	pool, err := pg.Open(ctx, dsn)
	if err != nil {
		return fmt.Errorf("open postgres: %w", err)
	}
	defer pool.Close()

	if a.Pending {
		n, err := pg.Pending(ctx, pool)
		if err != nil {
			return err
		}
		fmt.Fprintln(env.stdout, n)
		return nil
	}
	if err := pg.CheckMigrator(ctx, pool); err != nil {
		return err
	}
	applied, err := pg.AppliedVersion(ctx, pool)
	if err != nil {
		return err
	}
	latest, err := pg.LatestEmbedded()
	if err != nil {
		return err
	}
	if a.Status {
		pending, err := pg.Pending(ctx, pool)
		if err != nil {
			return err
		}
		fmt.Fprintf(env.stdout, "applied %d\nembedded %d\npending %d\n", applied, latest, pending)
		return nil
	}
	if err := pg.MigrateLocked(ctx, pool, a.To); err != nil {
		return fmt.Errorf("migrate: %w", err)
	}
	now, err := pg.AppliedVersion(ctx, pool)
	if err != nil {
		return err
	}
	slog.Info("hasalad migrate: done", "from", applied, "to", now, "embedded", latest)
	return nil
}
