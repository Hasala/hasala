package pgtest_test

import (
	"context"
	"os"
	"os/exec"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

func TestBootStandaloneServesConnectionsAndStopScriptTearsDown(t *testing.T) {
	dsn, stopScript, err := pgtest.BootStandalone(0)
	if err != nil {
		t.Fatalf("BootStandalone: %v", err)
	}
	t.Cleanup(func() {
		if _, err := os.Stat(stopScript); err == nil {
			_ = exec.Command(stopScript).Run()
		}
	})
	if stopScript == "" {
		t.Fatal("BootStandalone returned an empty stop script path")
	}
	if fi, err := os.Stat(stopScript); err != nil {
		t.Fatalf("stat stop script: %v", err)
	} else if fi.Mode()&0o100 == 0 {
		t.Fatalf("stop script %s is not executable: mode %v", stopScript, fi.Mode())
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatalf("connect to standalone cluster: %v", err)
	}
	if err := pool.Ping(ctx); err != nil {
		t.Fatalf("ping standalone cluster: %v", err)
	}
	pool.Close()

	stop := exec.Command(stopScript)
	if out, err := stop.CombinedOutput(); err != nil {
		t.Fatalf("run stop script: %v: %s", err, out)
	}

	deadline := time.Now().Add(5 * time.Second)
	var pingErr error
	for time.Now().Before(deadline) {
		p, err := pgxpool.New(context.Background(), dsn)
		if err != nil {
			pingErr = err
			break
		}
		pingErr = p.Ping(context.Background())
		p.Close()
		if pingErr != nil {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if pingErr == nil {
		t.Fatal("stop script ran but the cluster is still accepting connections")
	}
}
