package main

import (
	"context"
	"flag"
	"fmt"
	"os"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/pgtest"
)

func main() {
	owner := flag.Int("owner", 0, "pid of the process this cluster belongs to")
	flag.Parse()
	if reaped, err := pgtest.ReapOrphans(); err != nil {
		fmt.Fprintf(os.Stderr, "boot: %v\n", err)
	} else if reaped > 0 {
		fmt.Fprintf(os.Stderr, "boot: reaped %d orphaned scratch cluster(s) from an earlier run\n", reaped)
	}
	dsn, stopScript, err := pgtest.BootStandalone(*owner)
	if err != nil {
		fmt.Fprintf(os.Stderr, "boot: %v\n", err)
		os.Exit(1)
	}
	pool, err := pgxpool.New(context.Background(), dsn)
	if err == nil {
		err = pgtest.EnsureRoles(context.Background(), pool)
		pool.Close()
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "boot: %v\n", err)
		os.Exit(1)
	}
	fmt.Printf("HASALA_TEST_POSTGRES_URL=%q\n", dsn)
	fmt.Printf("PG_STOP=%q\n", stopScript)
}
