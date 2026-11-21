package main

import (
	"bytes"
	"context"
	"log/slog"
	"os"
	"regexp"
	"strings"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/salehtl/hasala/server/internal/config"
	"github.com/salehtl/hasala/server/internal/oplog/oplogtest"
	"github.com/salehtl/hasala/server/internal/pgtest"
)

func TestMain(m *testing.M) { os.Exit(pgtest.Main(m)) }

func hasalad(t *testing.T, environ []string, argv ...string) (code int, stdout, stderr string) {
	t.Helper()
	var out, errb bytes.Buffer
	err := run(&runEnv{stdout: &out, stderr: &errb, environ: environ}, argv)
	return exitCode(err), out.String(), errb.String() + errString(err)
}

func errString(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}

func TestEveryAdvertisedModeHasAHandlerAndNoOther(t *testing.T) {
	defer func() {
		if r := recover(); r != nil {
			t.Fatal(r)
		}
	}()
	checkModeHandlers()
}

func TestTheModeComesFirst(t *testing.T) {
	for _, argv := range [][]string{nil, {"--verbose"}, {"ledgerd"}, {"smtp"}, {"admin"}, {"dev-auth"}} {
		if code, _, _ := hasalad(t, nil, argv...); code != 2 {
			t.Fatalf("hasalad %v exited %d, want 2", argv, code)
		}
	}
}

func TestHelpExitsZero(t *testing.T) {
	code, out, _ := hasalad(t, nil, "--help")
	if code != 0 || !strings.Contains(out, "usage: hasalad") {
		t.Fatalf("--help exited %d with %q", code, out)
	}
	if code, _, _ := hasalad(t, nil, "serve", "--help"); code != 0 {
		t.Fatalf("serve --help exited %d", code)
	}
}

func TestVersionNeedsNoConfiguration(t *testing.T) {
	code, out, _ := hasalad(t, nil, "version")
	if code != 0 || !regexp.MustCompile(`^hasalad \S+ go\S+\n$`).MatchString(out) {
		t.Fatalf("version exited %d with %q", code, out)
	}
}

func TestArgumentMistakesAreRefusedBeforeTheDatabase(t *testing.T) {
	id := uuid.NewString()
	for _, argv := range [][]string{
		{"purge-user"},
		{"purge-user", id},
		{"purge-user", id, "--confirm", uuid.NewString()},
		{"purge-user", "not-a-uuid", "--confirm", "not-a-uuid"},
		{"purge-user", uuid.Nil.String(), "--confirm", uuid.Nil.String()},
		{"verify"},
		{"verify", "everything"},
		{"verify", "structural", "--repair"},
		{"verify", "usage", "--user", "nope"},
		{"invite"},
		{"invite", "revoke"},
		{"invite", "list", "--note", "x"},
		{"account"},
		{"account", "review", id},
		{"account", "review", id, "on"},
		{"account", "review", id, "on", "--confirm", uuid.NewString()},
		{"account", "review", id, "maybe", "--confirm", id},
		{"account", "review", strings.ToUpper(id), "on", "--confirm", strings.ToUpper(id)},
		{"account", "freeze", id, "on", "--confirm", id},
		{"account", "unfreeze"},
		{"account", "unfreeze", id},
		{"account", "unfreeze", id, "--confirm", uuid.NewString()},
		{"account", "unfreeze", id, id, "--confirm", id},
		{"account", "unfreeze", strings.ToUpper(id), "--confirm", strings.ToUpper(id)},
		{"account", "unfreeze", id, "--confirm", id, "extra"},
		{"mailbox"},
		{"mailbox", "rekey"},
		{"mailbox", "rekey", "--drop-links"},
		{"mailbox", "rekey", "--keep-key-id", "0011223344556677"},
		{"mailbox", "rekey", "--drop-links", "--keep-key-id", "0011"},
		{"mailbox", "drop", "--drop-links", "--keep-key-id", "0011223344556677"},
		{"mailbox", "rekey", "extra", "--drop-links", "--keep-key-id", "0011223344556677"},
		{"migrate", "--status", "--pending"},
		{"migrate", "--to", "-1"},
		{"migrate", "extra"},
		{"serve", "--no-such-flag"},
	} {
		code, _, msg := hasalad(t, nil, argv...)
		if code != 2 {
			t.Fatalf("hasalad %v exited %d (%s), want 2", argv, code, msg)
		}
		if strings.Contains(msg, "postgres") {
			t.Fatalf("hasalad %v reached the database before refusing its arguments: %s", argv, msg)
		}
	}
}

func TestMigrateRefusesAVersionItWouldIgnore(t *testing.T) {
	env := []string{"HASALA_MIGRATE_DSN=postgres://hasala_migrate@127.0.0.1:1/none", "HASALA_PG_DSN=postgres://hasala_runtime@127.0.0.1:1/none"}
	for _, argv := range [][]string{{"migrate", "--status", "--to", "5"}, {"migrate", "--pending", "--to", "5"}} {
		code, _, msg := hasalad(t, env, argv...)
		if code != 2 || !strings.Contains(msg, "--to") {
			t.Fatalf("hasalad %v exited %d (%s), want 2 naming --to", argv, code, msg)
		}
	}
}

func TestEveryDatabaseModeNeedsItsDSN(t *testing.T) {
	for _, argv := range [][]string{
		{"serve"}, {"verify", "structural"}, {"invite", "list"},
		{"purge-user", uuid.Nil.String()[:35] + "1", "--confirm", uuid.Nil.String()[:35] + "1"},
	} {
		if code, _, msg := hasalad(t, nil, argv...); code != 2 || !strings.Contains(msg, "HASALA_PG_DSN") {
			t.Fatalf("hasalad %v without a DSN exited %d (%s), want 2 naming HASALA_PG_DSN", argv, code, msg)
		}
	}
	code, _, msg := hasalad(t, []string{"HASALA_PG_DSN=postgres://x@127.0.0.1/x"}, "migrate")
	if code != 2 || !strings.Contains(msg, "HASALA_MIGRATE_DSN") {
		t.Fatalf("migrate with only the runtime DSN exited %d (%s), want 2", code, msg)
	}
}

func TestServeRefusesTheConsolesEnvironment(t *testing.T) {
	for _, kv := range []string{"HASALA_CONSOLE_LISTEN=127.0.0.1:9", "HASALA_ASC_KEY_ID=x", "HASALA_TESTFLIGHT_MODE=1"} {
		code, _, msg := hasalad(t, []string{kv}, "serve")
		if code != 2 || !strings.Contains(msg, "operator console") {
			t.Fatalf("serve with %s exited %d (%s), want a 2 naming the console", kv, code, msg)
		}
	}
}

func TestConsoleRefuses(t *testing.T) {
	code, _, msg := hasalad(t, []string{"HASALA_AUTH_KEY_FILE=/x"}, "console")
	if code != 2 || !strings.Contains(msg, "secret of serve") {
		t.Fatalf("console with serve's secret exited %d (%s)", code, msg)
	}
	if code, _, _ := hasalad(t, nil, "console"); code != 2 {
		t.Fatalf("console exited %d, want 2", code)
	}
}

func TestMigrateThenOperateAsTheRuntimeRole(t *testing.T) {
	migrateDSN, runtimeDSN := pgtest.NewEmpty(t)
	asOwner := []string{"HASALA_MIGRATE_DSN=" + migrateDSN}
	asRuntime := []string{"HASALA_PG_DSN=" + runtimeDSN}

	if code, _, msg := hasalad(t, asRuntime, "verify", "structural"); code != 2 {
		t.Fatalf("verify on an unmigrated database exited %d (%s), want 2", code, msg)
	}
	if code, out, msg := hasalad(t, asRuntime, "migrate", "--pending"); code != 0 || out != "0\n" {
		t.Fatalf("migrate --pending exited %d with %q (%s), want 0 and 0", code, out, msg)
	}
	if code, _, msg := hasalad(t, []string{"HASALA_MIGRATE_DSN=" + runtimeDSN}, "migrate"); code != 2 {
		t.Fatalf("migrate as the runtime role exited %d (%s), want 2", code, msg)
	}

	if code, _, msg := hasalad(t, asOwner, "migrate"); code != 0 {
		t.Fatalf("migrate exited %d: %s", code, msg)
	}
	code, out, msg := hasalad(t, asOwner, "migrate", "--status")
	if code != 0 || !strings.Contains(out, "pending 0") {
		t.Fatalf("migrate --status exited %d with %q (%s)", code, out, msg)
	}
	if code, _, msg := hasalad(t, asOwner, "migrate"); code != 0 {
		t.Fatalf("a second migrate exited %d: %s", code, msg)
	}

	for _, argv := range [][]string{{"verify", "structural"}, {"invite", "list"}} {
		if code, _, msg := hasalad(t, []string{"HASALA_PG_DSN=" + migrateDSN}, argv...); code != 2 {
			t.Fatalf("%v as the schema owner exited %d (%s), want 2", argv, code, msg)
		}
	}

	code, out, msg = hasalad(t, asRuntime, "invite", "mint", "--note", "lifecycle")
	if code != 0 || !regexp.MustCompile(`^[A-Z2-7]{24}\n$`).MatchString(out) {
		t.Fatalf("invite mint exited %d with %q (%s), want the bare 24-character code", code, out, msg)
	}
	if code, out, msg := hasalad(t, asRuntime, "invite", "list"); code != 0 || !strings.Contains(out, "1 invite(s), 1 still outstanding") {
		t.Fatalf("invite list exited %d with %q (%s)", code, out, msg)
	}
	if code, _, msg := hasalad(t, asRuntime, "verify", "structural"); code != 0 {
		t.Fatalf("verify structural on a clean database exited %d: %s", code, msg)
	}
	unknown := uuid.NewString()
	if code, _, msg := hasalad(t, asRuntime, "account", "review", unknown, "on", "--confirm", unknown); code != 2 ||
		!strings.Contains(msg, "no account") {
		t.Fatalf("account review of an unknown account exited %d (%s)", code, msg)
	}
	pool, err := pgxpool.New(context.Background(), runtimeDSN)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	user := oplogtest.NewUser(t, pool).String()
	for _, c := range []struct{ to, want string }{{"on", "review on (was off)"}, {"off", "review off (was on)"}} {
		if code, out, msg := hasalad(t, asRuntime, "account", "review", user, c.to, "--confirm", user); code != 0 ||
			!strings.Contains(out, c.want) {
			t.Fatalf("account review %s exited %d with %q (%s)", c.to, code, out, msg)
		}
	}
	var audits int
	if err := pool.QueryRow(context.Background(),
		`SELECT count(*) FROM admin_audit WHERE action = 'cli.account_review' AND target_id = $1`, user).Scan(&audits); err != nil ||
		audits != 2 {
		t.Fatalf("%d audit rows (%v), want 2", audits, err)
	}
	if code, _, msg := hasalad(t, asRuntime, "verify", "usage"); code != 0 {
		t.Fatalf("verify usage on a clean database exited %d: %s", code, msg)
	}
	id := uuid.NewString()
	if code, out, msg := hasalad(t, asRuntime, "purge-user", id, "--confirm", id, "--dry-run"); code != 0 || !strings.Contains(out, "Nothing was deleted") {
		t.Fatalf("purge-user --dry-run exited %d with %q (%s)", code, out, msg)
	}
	if code, out, msg := hasalad(t, asRuntime, "purge-user", id, "--confirm", id); code != 0 || !strings.Contains(out, "no such account") {
		t.Fatalf("purge-user of an unknown account exited %d with %q (%s)", code, out, msg)
	}

	serveEnv := []string{
		"HASALA_PG_DSN=" + migrateDSN, "HASALA_RP_ID=example.test",
		"HASALA_RP_ORIGINS=https://example.test", "HASALA_HEADROOM_PATH=" + t.TempDir(),
		"HASALA_HTTP_LISTEN=127.0.0.1:0",
	}
	if code, _, msg := hasalad(t, serveEnv, "serve"); code != 2 {
		t.Fatalf("serve as the schema owner exited %d (%s), want 2", code, msg)
	}
}

func TestServeNoLongerWarnsAboutTheCloudflareProxy(t *testing.T) {
	var buf bytes.Buffer
	prev := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&buf, nil)))
	defer slog.SetDefault(prev)

	var cfg config.Config
	cfg.Server.TrustedProxy = config.ProxyCloudflare
	logGroups(cfg)
	if strings.Contains(buf.String(), "global limit") || !strings.Contains(buf.String(), "trusted_proxy=cloudflare") {
		t.Fatalf("logGroups: %s", buf.String())
	}
}

func TestUnreadVariablesAreWarnedOnStderrOnly(t *testing.T) {
	_, stdout, stderr := hasalad(t, []string{"HASALA_PG_DSN=host=/nonexistent dbname=hasala", "HASALA_TURNSTYLE_REQUIRED=true"},
		"migrate", "--pending")
	if !strings.Contains(stderr, "does not read HASALA_TURNSTYLE_REQUIRED") {
		t.Fatalf("stderr %q", stderr)
	}
	if strings.Contains(stdout, "HASALA_TURNSTYLE_REQUIRED") {
		t.Fatalf("the warning reached stdout: %q", stdout)
	}
}
