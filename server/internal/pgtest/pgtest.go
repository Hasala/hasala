package pgtest

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/salehtl/hasala/server/internal/pg"
)

var (
	adminDSN  string
	adminPool *pgxpool.Pool
	dbSeq     atomic.Int64

	tmplOnce sync.Once
	tmplName string
	tmplErr  error
)

func EnsureRoles(ctx context.Context, admin *pgxpool.Pool) error {
	const ddl = `DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'hasala_migrate') THEN
    CREATE ROLE hasala_migrate LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'hasala_runtime') THEN
    CREATE ROLE hasala_runtime LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT;
    ALTER ROLE hasala_runtime SET statement_timeout = '15s';
    ALTER ROLE hasala_runtime SET lock_timeout = '5s';
    ALTER ROLE hasala_runtime SET idle_in_transaction_session_timeout = '30s';
  END IF;
END $$`
	var err error
	for attempt := 0; attempt < 10; attempt++ {
		if _, err = admin.Exec(ctx, ddl); err == nil {
			return nil
		}
		time.Sleep(time.Duration(50*(attempt+1)) * time.Millisecond)
	}
	return fmt.Errorf("pgtest: create roles: %w", err)
}

func Main(m *testing.M) int {
	stop, dsn, err := boot()
	if err != nil {
		fmt.Fprintf(os.Stderr, "pgtest: %v\n", err)
		return 1
	}
	adminDSN = dsn
	pool, err := pgxpool.New(context.Background(), dsn)
	if err != nil {
		fmt.Fprintf(os.Stderr, "pgtest: connect admin pool: %v\n", err)
		stop()
		return 1
	}
	adminPool = pool
	if err := EnsureRoles(context.Background(), pool); err != nil {
		fmt.Fprintf(os.Stderr, "pgtest: %v\n", err)
		adminPool.Close()
		stop()
		return 1
	}
	code := m.Run()
	dropTemplate()
	adminPool.Close()
	stop()
	return code
}

func New(t *testing.T) *pgxpool.Pool {
	t.Helper()
	runtime, _ := NewWithOwner(t)
	return runtime
}

func NewOwner(t *testing.T) *pgxpool.Pool {
	t.Helper()
	_, owner := NewWithOwner(t)
	return owner
}

func NewWithOwner(t *testing.T) (runtime, owner *pgxpool.Pool) {
	t.Helper()
	tmpl, err := migratedTemplate()
	if err != nil {
		t.Fatal(err)
	}
	name := copyDatabase(t, tmpl)
	owner = openPool(t, dsnFor(adminDSN, pg.RoleMigrate, name))
	runtime = openPool(t, dsnFor(adminDSN, pg.RoleRuntime, name))
	return runtime, owner
}

func migratedTemplate() (string, error) {
	tmplOnce.Do(func() {
		ctx := context.Background()
		name := fmt.Sprintf("tmpl%d", os.Getpid())
		if _, err := adminPool.Exec(ctx, "CREATE DATABASE "+name+" OWNER hasala_migrate"); err != nil {
			tmplErr = fmt.Errorf("pgtest: create the migrated template: %w", err)
			return
		}
		tmplName = name
		if err := prepareDatabase(ctx, name); err != nil {
			tmplErr = err
			return
		}
		owner, err := pg.Open(ctx, dsnFor(adminDSN, pg.RoleMigrate, name))
		if err != nil {
			tmplErr = fmt.Errorf("pgtest: open the template as the schema owner: %w", err)
			return
		}
		err = pg.Migrate(ctx, owner)
		owner.Close()
		if err != nil {
			tmplErr = fmt.Errorf("pgtest: migrate the template: %w", err)
			return
		}
		awaitNoBackends(ctx, name)
	})
	return tmplName, tmplErr
}

func dropTemplate() {
	if tmplName == "" {
		return
	}
	if _, err := adminPool.Exec(context.Background(), "DROP DATABASE IF EXISTS "+tmplName+" WITH (FORCE)"); err != nil {
		fmt.Fprintf(os.Stderr, "pgtest: drop the migrated template %s: %v\n", tmplName, err)
	}
}

func copyDatabase(t *testing.T, tmpl string) string {
	t.Helper()
	ctx := context.Background()
	name := fmt.Sprintf("t%d_%d", os.Getpid(), dbSeq.Add(1))
	if _, err := adminPool.Exec(ctx, "CREATE DATABASE "+name+" TEMPLATE "+tmpl+" OWNER hasala_migrate STRATEGY file_copy"); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { dropDatabase(t, name) })
	for _, stmt := range databaseGrants(name) {
		if _, err := adminPool.Exec(ctx, stmt); err != nil {
			t.Fatalf("pgtest: %s: %v", stmt, err)
		}
	}
	return name
}

func NewEmpty(t *testing.T) (migrateDSN, runtimeDSN string) {
	t.Helper()
	name := newDatabase(t)
	return dsnFor(adminDSN, pg.RoleMigrate, name), dsnFor(adminDSN, pg.RoleRuntime, name)
}

func newDatabase(t *testing.T) string {
	t.Helper()
	ctx := context.Background()
	name := fmt.Sprintf("t%d_%d", os.Getpid(), dbSeq.Add(1))
	if _, err := adminPool.Exec(ctx, "CREATE DATABASE "+name+" OWNER hasala_migrate"); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { dropDatabase(t, name) })
	if err := prepareDatabase(ctx, name); err != nil {
		t.Fatal(err)
	}
	return name
}

func dropDatabase(t *testing.T, name string) {
	t.Helper()
	ctx := context.Background()
	awaitNoBackends(ctx, name)
	if _, err := adminPool.Exec(ctx, "DROP DATABASE IF EXISTS "+name+" WITH (FORCE)"); err != nil {
		t.Errorf("pgtest: drop database %s: %v", name, err)
	}
}

func awaitNoBackends(ctx context.Context, name string) {
	for deadline := time.Now().Add(backendExitWait); time.Now().Before(deadline); time.Sleep(time.Millisecond) {
		var n int
		if err := adminPool.QueryRow(ctx,
			"SELECT count(*) FROM pg_stat_activity WHERE datname = $1", name).Scan(&n); err != nil || n == 0 {
			return
		}
	}
}

const backendExitWait = 250 * time.Millisecond

func prepareDatabase(ctx context.Context, name string) error {
	su, err := pg.Open(ctx, dsnFor(adminDSN, "", name))
	if err != nil {
		return err
	}
	defer su.Close()
	for _, stmt := range append([]string{
		"ALTER SCHEMA public OWNER TO hasala_migrate",
		"REVOKE ALL ON SCHEMA public FROM PUBLIC",
	}, databaseGrants(name)...) {
		if _, err := su.Exec(ctx, stmt); err != nil {
			return fmt.Errorf("pgtest: %s: %w", stmt, err)
		}
	}
	return nil
}

func databaseGrants(name string) []string {
	return []string{
		"REVOKE ALL ON DATABASE " + name + " FROM PUBLIC",
		"GRANT CONNECT ON DATABASE " + name + " TO hasala_runtime",
	}
}

func openPool(t *testing.T, dsn string) *pgxpool.Pool {
	t.Helper()
	cfg, err := pg.PoolConfig(dsn)
	if err != nil {
		t.Fatal(err)
	}
	cfg.MinConns = 0
	p, err := pgxpool.NewWithConfig(context.Background(), cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(p.Close)
	return p
}

func OpenAs(t *testing.T, p *pgxpool.Pool, role string) *pgxpool.Pool {
	t.Helper()
	return openPool(t, dsnFor(adminDSN, role, p.Config().ConnConfig.Database))
}

func Superuser(t *testing.T, p *pgxpool.Pool) *pgxpool.Pool {
	t.Helper()
	return OpenAs(t, p, "")
}

func dsnFor(adminDSN, user, name string) string {
	u, err := url.Parse(adminDSN)
	if err != nil || u.Scheme == "" {
		out := adminDSN + " dbname=" + name
		if user != "" {
			out += " user=" + user
		}
		return out
	}
	if user != "" {
		u.User = url.User(user)
	}
	u.Path = "/" + name
	return u.String()
}

func boot() (func(), string, error) {
	if u := os.Getenv("HASALA_TEST_POSTGRES_URL"); u != "" {
		return func() {}, u, nil
	}
	dir, srv, dsn, err := bootCluster(false, os.Getpid())
	if err != nil {
		return nil, "", err
	}
	stop := func() {
		_ = srv.Process.Signal(syscall.SIGQUIT)
		_, _ = srv.Process.Wait()
		_ = os.RemoveAll(dir)
	}
	return stop, dsn, nil
}

func BootStandalone(owner int) (dsn string, stopScript string, err error) {
	dir, srv, dsn, err := bootCluster(true, owner)
	if err != nil {
		return "", "", err
	}
	go func() { _, _ = srv.Process.Wait() }()
	script := filepath.Join(dir, "stop.sh")
	contents := fmt.Sprintf("#!/bin/sh\nkill -QUIT %d 2>/dev/null\nfor i in $(seq 1 100); do kill -0 %d 2>/dev/null || break; sleep 0.1; done\nrm -rf %s\n",
		srv.Process.Pid, srv.Process.Pid, dir)
	if err := os.WriteFile(script, []byte(contents), 0o700); err != nil {
		_ = srv.Process.Kill()
		_ = os.RemoveAll(dir)
		return "", "", fmt.Errorf("write stop script: %w", err)
	}
	return dsn, script, nil
}

func bootCluster(detach bool, owner int) (dir string, srv *exec.Cmd, dsn string, err error) {
	binDir, err := postgresBinDir()
	if err != nil {
		return "", nil, "", err
	}
	dir, err = os.MkdirTemp("", "pgtest-")
	if err != nil {
		return "", nil, "", err
	}
	bootDir := dir
	ok := false
	defer func() {
		if !ok {
			_ = os.RemoveAll(bootDir)
		}
	}()
	data := filepath.Join(dir, "data")
	cred, err := unprivileged()
	if err != nil {
		return "", nil, "", err
	}
	if cred != nil {
		if err := os.Chown(dir, int(cred.Uid), int(cred.Gid)); err != nil {
			return "", nil, "", err
		}
	}
	cmd := func(name string, args ...string) *exec.Cmd {
		c := exec.Command(filepath.Join(binDir, name), args...)
		if cred != nil || detach {
			c.SysProcAttr = &syscall.SysProcAttr{Credential: cred, Setsid: detach}
		}
		return c
	}
	if out, err := cmd("initdb", "-D", data, "-U", "postgres", "-A", "trust",
		"--encoding=UTF8", "--locale=C.UTF-8").CombinedOutput(); err != nil {
		return "", nil, "", fmt.Errorf("initdb: %v: %s", err, out)
	}
	port := 5433
	srv = cmd("postgres", "-D", data, "-k", dir, "-p", strconv.Itoa(port),
		"-c", "listen_addresses=", "-c", "fsync=off", "-c", "full_page_writes=off",
		"-c", "synchronous_commit=off", "-c", "max_connections=400")
	srv.Stdout, srv.Stderr = os.Stderr, os.Stderr
	if owner > 0 {
		if err := os.WriteFile(filepath.Join(dir, ownerFile), []byte(strconv.Itoa(owner)), 0o644); err != nil {
			return "", nil, "", fmt.Errorf("write owner file: %w", err)
		}
	}
	if err := srv.Start(); err != nil {
		return "", nil, "", err
	}
	dsn = fmt.Sprintf("postgres://postgres@/postgres?host=%s&port=%d&sslmode=disable", dir, port)
	if err := waitReady(dsn); err != nil {
		_ = srv.Process.Kill()
		_, _ = srv.Process.Wait()
		return "", nil, "", err
	}
	ok = true
	return dir, srv, dsn, nil
}

func postgresBinDir() (string, error) {
	hasPostgres := func(dir string) bool {
		_, err := os.Stat(filepath.Join(dir, "postgres"))
		return err == nil
	}
	if dir := os.Getenv("HASALA_TEST_PG_BINDIR"); dir != "" {
		if hasPostgres(dir) {
			return dir, nil
		}
		return "", fmt.Errorf("HASALA_TEST_PG_BINDIR=%s holds no postgres binary", dir)
	}
	if initdb, err := exec.LookPath("initdb"); err == nil {
		if dir := filepath.Dir(initdb); hasPostgres(dir) {
			return dir, nil
		}
		if real, err := filepath.EvalSymlinks(initdb); err == nil {
			if dir := filepath.Dir(real); hasPostgres(dir) {
				return dir, nil
			}
		}
	}
	if bin, err := filepath.Glob("/usr/lib/postgresql/*/bin/initdb"); err == nil && len(bin) > 0 {
		return filepath.Dir(bin[len(bin)-1]), nil
	}
	return "", fmt.Errorf("initdb (with postgres beside it) not found on PATH or under /usr/lib/postgresql; " +
		"run inside the devShell: `direnv exec . <cmd>` or `nix develop`")
}

func unprivileged() (*syscall.Credential, error) {
	if os.Geteuid() != 0 {
		return nil, nil
	}
	name := os.Getenv("HASALA_TEST_PG_USER")
	if name == "" {
		name = "nobody"
	}
	u, err := user.Lookup(name)
	if err != nil {
		return nil, fmt.Errorf("lookup %q: %w", name, err)
	}
	uid, _ := strconv.Atoi(u.Uid)
	gid, _ := strconv.Atoi(u.Gid)
	return &syscall.Credential{Uid: uint32(uid), Gid: uint32(gid)}, nil
}

func waitReady(dsn string) error {
	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		pool, err := pgxpool.New(context.Background(), dsn)
		if err == nil {
			if err = pool.Ping(context.Background()); err == nil {
				pool.Close()
				return nil
			}
			pool.Close()
		}
		time.Sleep(200 * time.Millisecond)
	}
	return fmt.Errorf("postgres did not become ready")
}

const ownerFile = "owner.pid"

var postmasterLine = regexp.MustCompile(`^\s*(\d+)\s+\S*postgres -D (.+/pgtest-[^/]+/data) -k `)

func ReapOrphans() (int, error) {
	out, err := exec.Command("ps", "-u", strconv.Itoa(os.Getuid()), "-o", "pid=", "-o", "args=").Output()
	if err != nil {
		return 0, fmt.Errorf("pgtest: list processes: %w", err)
	}
	reaped := 0
	for _, line := range strings.Split(string(out), "\n") {
		m := postmasterLine.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		dir := filepath.Dir(m[2])
		if !ownerGone(dir) {
			continue
		}
		pid, err := strconv.Atoi(m[1])
		if err != nil {
			continue
		}
		_ = syscall.Kill(pid, syscall.SIGQUIT)
		_ = os.RemoveAll(dir)
		reaped++
	}
	return reaped, nil
}

func ownerGone(dir string) bool {
	raw, err := os.ReadFile(filepath.Join(dir, ownerFile))
	if err != nil {
		return false
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(raw)))
	if err != nil || pid <= 1 {
		return false
	}
	return errors.Is(syscall.Kill(pid, 0), syscall.ESRCH)
}
