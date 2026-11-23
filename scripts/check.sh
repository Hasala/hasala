#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JOBS="${CHECK_JOBS:-8}"
SHUFFLE="${CHECK_SHUFFLE:-on}"
if [[ ! "$SHUFFLE" =~ ^(on|[0-9]+)$ ]]; then
	echo "check: CHECK_SHUFFLE=$SHUFFLE must be 'on' or a seed that an earlier run printed" >&2
	exit 2
fi
step() { printf '\n== check: %s\n' "$*"; }

FENCE_ONLY=""
SELF_TESTS_ONLY=""
case "$*" in
"") ;;
--fence-only) FENCE_ONLY=1 ;;
--self-tests) SELF_TESTS_ONLY=1 ;;
*)
	echo "usage: scripts/check.sh [--fence-only | --self-tests]" >&2
	exit 2
	;;
esac

CI_RUN=""
if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
	CI_RUN=1
fi
ci_report() {
	[[ -n "$CI_RUN" ]] || return 0
	echo "::notice title=$1::$2"
	if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
		printf '**%s**: %s\n\n' "$1" "$2" >>"$GITHUB_STEP_SUMMARY"
	fi
}

step "real-mail fence"
fence_scan() {
	local path
	while IFS= read -r -d '' path; do
		if [[ -e "$path" || -L "$path" ]]; then
			printf '%s\0' "$path"
		fi
	done | xargs -0 grep -lE -e "$1" -- /dev/null 2>&1 || true
}
leaked="$(
	cd "$ROOT"
	{
		find conformance/normalizer -type f ! -name edge-cases.json ! -name charset-tables.ts ! -name '.*' || true
		find conformance/templates -type f -name 'corpus-*' || true
		find conformance/templates/eml -type f || true
		find conformance/templates/sms -type f ! -name 'synthetic-*' ! -name '.*' || true
		find conformance -type f \( -ipath 'conformance/*sms*/*' -o -ipath 'conformance/*text*/*' \) \
			! -name 'synthetic-*' ! -name README.md ! -name '.*' || true
		find conformance/templates -path conformance/templates/sms -prune -o -type f ! -name '.*' -print0 |
			fence_scan '\\?"channel\\?"[[:space:]]*:[[:space:]]*\\?"sms\\?"' || true
		{
			find conformance -type f ! -name '.*' -print0 || true
			git ls-files -z -co --exclude-standard -- '*.json' '*.jsonl' '*.csv' '*.txt' || true
		} | fence_scan '\\?"note\\?"[[:space:]]*:[[:space:]]*\\?"PRIVATE:'
		{
			find conformance -type f ! -name 'synthetic-*' ! -name '.*' -print0 || true
			git ls-files -z -co --exclude-standard -- '*.json' '*.jsonl' '*.csv' '*.txt' || true
		} | { grep -azv '/synthetic-[^/]*$' || true; } |
			fence_scan '\\?"read_by\\?"[[:space:]]*:|\\?"sender\\?"[[:space:]]*:[[:space:]]*\\?"DIB-SMS\\?"|^DIB-SMS,|,DIB-SMS(,|$)'
		find server/internal/origin/testdata -type f ! -name dns.json ! -name '.*' || true
		find server/internal/tmpl/seed/testdata -type f ! -name '.*' || true
		git ls-files -co --exclude-standard -- ':(icase)*.eml' || true
	} 2>/dev/null | sort -u
)"
if [[ -n "$leaked" ]]; then
	echo "check: real bank mail or text fixtures are in the public tree; they belong in salehtl/hasala-fixtures:" >&2
	echo "$leaked" >&2
	exit 1
fi
unread="$(cd "$ROOT" && find conformance/templates/sms -mindepth 2 -type f ! -name '.*' 2>/dev/null | sort)"
if [[ -n "$unread" ]]; then
	echo "check: no template runner reads a subdirectory of conformance/templates/sms, so these cases would never run; move them into conformance/templates/sms itself:" >&2
	echo "$unread" >&2
	exit 1
fi
echo "no real-mail fixture or private expectation file in the public tree"
if [[ -n "$FENCE_ONLY" ]]; then
	exit 0
fi

NOT_RUN=()
if [[ -n "$CI_RUN" && -z "$SELF_TESTS_ONLY" ]]; then
	step "self-tests"
	echo "skipped in CI: the selftest job runs scripts/check.sh --self-tests"
	NOT_RUN+=("the self-tests (the selftest job runs them)")
else
	step "real-mail fence self-test"
	"$ROOT/scripts/tests/fence_test.sh"

	step "gate run self-test"
	"$ROOT/scripts/tests/gate_run_test.sh"
	"$ROOT/scripts/tests/gotest_ran_test.sh"
	"$ROOT/scripts/tests/git_env_test.sh"
	"$ROOT/scripts/tests/ci_changes_test.sh"
	"$ROOT/scripts/tests/comment_lint_test.sh"

	step "Mac devShell cache check self-test"
	"$ROOT/scripts/tests/ci_mac_devshell_test.sh"

	step "CI time budget self-test"
	"$ROOT/scripts/tests/ci_budget_test.sh"
fi

if [[ -n "$SELF_TESTS_ONLY" ]]; then
	echo
	echo "check: OK (real-mail fence, self-tests)"
	exit 0
fi

step "pre-push hook self-test"
"$ROOT/scripts/tests/pre_push_hook_test.sh"

GATE_STEPS="real-mail fence, toolchain, fence"

step "HasalaCore import and API lints"
"$ROOT/ios/scripts/check-imports.sh" --no-manifest
"$ROOT/ios/scripts/check-forbidden.sh"

step "comment lint"
"$ROOT/scripts/check-comments.sh"

step "bundled templates equal the server seed"
bundled="$ROOT/ios/HasalaCore/Sources/HasalaCore/Resources/templates"
seed="$ROOT/server/internal/tmpl/seed"
if [ "$(cd "$bundled" && ls -1 ./*.json)" != "$(cd "$seed" && ls -1 ./*.json)" ]; then
  echo "the bundled template set differs from server/internal/tmpl/seed; run swift ios/tools/templates/sync.swift" >&2
  exit 1
fi
for f in "$seed"/*.json; do
  if ! cmp -s "$f" "$bundled/${f##*/}"; then
    echo "${f##*/} differs from the server seed; run swift ios/tools/templates/sync.swift" >&2
    exit 1
  fi
done
echo "$(ls -1 "$seed"/*.json | wc -l | tr -d ' ') templates identical"

step "the template manifest names every seed by its hash"
"$ROOT/scripts/tests/templates_manifest_test.sh"
"$ROOT/scripts/check-templates-manifest.sh"

step "oxlint (infra/assist, scripts, ios/scripts)"
(cd "$ROOT" && oxlint infra/assist scripts ios/scripts)
GATE_STEPS+=", oxlint"

step "oxfmt --check (infra/assist, scripts, ios/scripts)"
(cd "$ROOT" && oxfmt --check infra/assist scripts ios/scripts)
GATE_STEPS+=", oxfmt"

GOLDEN_SETS=(authres categorize extract fx merchant-group norm-dates outlook-sender replay sms-extract)
step "golden fixtures change only with a Swift test change"
cd "$ROOT"
if [[ -n "$CI_RUN" ]]; then
	golden_base="$(git rev-parse -q --verify 'HEAD^1' || true)"
else
	golden_base="$(git merge-base HEAD origin/main 2>/dev/null || true)"
fi
if [[ -z "$golden_base" && -n "$CI_RUN" ]]; then
	echo "check: no base commit (HEAD^1), so the golden-fixture rule cannot run; the gate job's checkout needs fetch-depth 2" >&2
	exit 1
elif [[ -z "$golden_base" ]]; then
	echo "no base commit to compare with (the merge base with origin/main); skipped"
	NOT_RUN+=("the golden-fixture rule (no merge base with origin/main)")
else
	golden_paths=()
	for s in "${GOLDEN_SETS[@]}"; do golden_paths+=("conformance/$s"); done
	changed_since() { { git diff --name-only "$golden_base" -- "$@" && git ls-files --others --exclude-standard -- "$@"; } | sort -u; }
	golden_changed="$(changed_since "${golden_paths[@]}")"
	if [[ -n "$golden_changed" && -z "$(changed_since ios/HasalaCore/Tests)" ]]; then
		echo "check: golden fixtures changed since ${golden_base:0:12} with no change under ios/HasalaCore/Tests:" >&2
		sed 's/^/  /' <<<"$golden_changed" >&2
		echo "regenerate them with HASALA_UPDATE_GOLDEN=1 (conformance/README.md) and change the Swift test that pins the new behaviour" >&2
		exit 1
	fi
	echo "$(grep -c . <<<"$golden_changed" || true) golden fixture file(s) changed since ${golden_base:0:12}"
fi

cd "$ROOT/server"

step "toolchain"
want="$(sed -n 's/^toolchain go//p' go.mod)"
have="$(go env GOVERSION)"
have="${have#go}"
if [[ -z "$want" ]]; then
	echo "check: server/go.mod has no toolchain line" >&2
	exit 1
fi
if [[ "$(printf '%s\n%s\n' "$want" "$have" | sort -V | head -n1)" != "$want" ]]; then
	echo "check: go $have is older than server/go.mod's toolchain go$want; run through the devShell" >&2
	exit 1
fi
echo "go $have (floor go$want)"

step "private fixtures (HASALA_PRIVATE_FIXTURES)"
"$ROOT/scripts/tests/private_fixtures_lock_test.sh"
if [[ -n "${HASALA_PRIVATE_FIXTURES:-}" ]]; then
	if [[ ! -d "$HASALA_PRIVATE_FIXTURES" ]]; then
		echo "check: HASALA_PRIVATE_FIXTURES=$HASALA_PRIVATE_FIXTURES is not a directory" >&2
		exit 1
	fi
	HASALA_PRIVATE_FIXTURES="$(cd "$HASALA_PRIVATE_FIXTURES" && pwd -P)"
	"$ROOT/scripts/private-fixtures-lock.sh" check "$HASALA_PRIVATE_FIXTURES"
	export HASALA_PRIVATE_FIXTURES
	echo "real-corpus tests will RUN against $HASALA_PRIVATE_FIXTURES"
else
	echo "HASALA_PRIVATE_FIXTURES is unset: real-corpus tests will SKIP (this run is not the full gate)"
fi

step "hasalad fences"
go test -count=1 -run '^TestFence' ./cmd/hasalad

step "govulncheck ./cmd/hasalad/..."
if [[ -n "$CI_RUN" ]]; then
	echo "skipped in CI: the vuln job runs govulncheck ./... in server/ and server/oracle/"
	NOT_RUN+=("govulncheck (the vuln job runs it)")
else
	govulncheck ./cmd/hasalad/...
	GATE_STEPS+=", govulncheck"
fi

PG_STOP=""
PG_LOG="$(mktemp "${TMPDIR:-/tmp}/hasala-check-pg.XXXXXX")"
REAL_GO="$(mktemp)"
REAL_ORACLE="$(mktemp)"
GO_RECORD="$(mktemp)"
ORACLE_RECORD="$(mktemp)"
GO_LIST="$(mktemp)"
cleanup() {
	local status=$?
	if [[ -n "$PG_STOP" && -x "$PG_STOP" ]]; then
		"$PG_STOP" || true
	fi
	rm -f "$REAL_GO" "$REAL_ORACLE" "$GO_RECORD" "$ORACLE_RECORD" "$GO_LIST"
	if [[ "$status" -eq 0 ]]; then
		rm -f "$PG_LOG"
	else
		echo "check: FAILED; the postgres server log is at $PG_LOG" >&2
		if [[ -n "$CI_RUN" && -s "$PG_LOG" ]]; then
			echo "::group::postgres server log"
			cat "$PG_LOG"
			echo "::endgroup::"
		fi
	fi
}
trap cleanup EXIT INT TERM

step "postgres"
BOOT_OUT="$(go run ./internal/pgtest/cmd/boot -owner "$$" 2>"$PG_LOG")" || {
	cat "$PG_LOG" >&2
	echo "check: failed to boot the postgres cluster (see the error above)" >&2
	exit 1
}
eval "$BOOT_OUT"
export HASALA_TEST_POSTGRES_URL
echo "cluster up (unix socket only; listen_addresses is empty)"

KNOWN_FAILING=(
	"oracle|./v1ref/store|^TestSelectMonthlyTotals\$|june = {Period: SpentFils:0 IncomeFils:0}, want spent 8000 income 100000"
)
skip_re="$(printf '%s\n' "${KNOWN_FAILING[@]}" | cut -d'|' -f3 | paste -sd'|' -)"
if [[ "$skip_re" == */* ]]; then
	echo "check: a KNOWN_FAILING regexp names a subtest ('/' in $skip_re); name top-level tests only (see above)" >&2
	exit 1
fi

step "go vet ./..."
go vet -p "$JOBS" ./...

step "go test ./... (random order, -shuffle=$SHUFFLE; known failures skipped by name: $skip_re)"
go test -count=1 -shuffle="$SHUFFLE" -p "$JOBS" -skip "$skip_re" -json ./... 2>&1 | tee "$GO_RECORD" | REALCORPUS_COUNTS="$REAL_GO" bun "$ROOT/scripts/gotest-summary.ts"

step "oracle: go vet ./... and go test ./..."
(
	cd oracle
	go vet -p "$JOBS" ./...
	go test -count=1 -shuffle="$SHUFFLE" -p "$JOBS" -skip "$skip_re" -json ./... 2>&1 | tee "$ORACLE_RECORD" | REALCORPUS_COUNTS="$REAL_ORACLE" bun "$ROOT/scripts/gotest-summary.ts"
)
read -r s_ran s_skipped <"$REAL_GO"
read -r o_ran o_skipped <"$REAL_ORACLE"
echo "$((s_ran + o_ran)) $((s_skipped + o_skipped))" >"$REAL_GO"

step "assist worker (infra/assist)"
cd "$ROOT/infra/assist"
bun install --frozen-lockfile
bun run --bun typecheck
bun test --randomize

step "typecheck the scripts (scripts, ios/scripts)"
(cd "$ROOT" && tsgo --noEmit -p scripts)

CONFORMANCE=(
	"api-v1|./cmd/gen-crypto-vectors ./internal/cryptoref"
	"authres|"
	"blob|./internal/oplog/opref"
	"categorize|"
	"crypto-v3|./cmd/gen-crypto-vectors ./internal/cryptoref ./internal/pg ./internal/api"
	"dialect|./internal/tmpl"
	"dict|./internal/dict"
	"extract|"
	"fx|"
	"import|./oracle/v1ref/importer"
	"merchant-group|"
	"norm-dates|"
	"normalizer|./internal/norm"
	"op|./internal/oplog/opref"
	"outlook-sender|"
	"replay|"
	"sms-extract|"
	"swift|"
	"templates|./internal/tmpl ./internal/tmpl/seed"
	"ts|./internal/oplog/opref"
)
step "conformance"
cd "$ROOT"
listed="$(printf '%s\n' "${CONFORMANCE[@]}" | cut -d'|' -f1 | sort)"
on_disk="$(cd conformance && for d in */; do echo "${d%/}"; done | sort)"
if [[ "$listed" != "$on_disk" ]]; then
	echo "check: conformance/ and the CONFORMANCE table in scripts/check.sh disagree" >&2
	echo "(< table, > conformance/):" >&2
	diff <(echo "$listed") <(echo "$on_disk") >&2 || true
	exit 1
fi
go_pkgs="$(printf '%s\n' "${CONFORMANCE[@]}" | cut -d'|' -f2 | tr ' ' '\n' | awk 'NF' | sort -u)"
for entry in "${CONFORMANCE[@]}"; do
	IFS='|' read -r set go <<<"$entry"
	printf '  %-14s go: %s\n' "$set" "${go:-(none)}"
done
server_pkgs="$(grep -v '^\./oracle/' <<<"$go_pkgs" || true)"
oracle_pkgs="$(grep '^\./oracle/' <<<"$go_pkgs" | sed 's|^\./oracle/|./|' || true)"
# shellcheck disable=SC2086 # word splitting is the point: one package/file per word
(cd server && go test -count=1 -p "$JOBS" -json -list . $server_pkgs) >"$GO_LIST"
if [[ -n "$oracle_pkgs" ]]; then
	# shellcheck disable=SC2086
	(cd server/oracle && go test -count=1 -p "$JOBS" -json -list . $oracle_pkgs) >>"$GO_LIST"
fi
bun "$ROOT/scripts/gotest-ran.ts" "$GO_LIST" "$GO_RECORD" "$ORACLE_RECORD"

step "known failures"
cd "$ROOT/server"
for entry in "${KNOWN_FAILING[@]}"; do
	IFS='|' read -r mod pkg re reason <<<"$entry"
	if out="$(cd "$ROOT/server/$mod" && go test -count=1 -v -run "$re" "$pkg" 2>&1)"; then
		echo "check: $pkg $re now PASSES; remove it from KNOWN_FAILING in scripts/check.sh" >&2
		exit 1
	fi
	if ! grep -q -- '^--- FAIL: ' <<<"$out"; then
		printf '%s\n' "$out" >&2
		echo "check: $pkg $re did not run to a FAIL (see above); it is not the recorded failure" >&2
		exit 1
	fi
	if [[ -z "$reason" ]] || ! grep -qF -- "$reason" <<<"$out"; then
		printf '%s\n' "$out" >&2
		echo "check: $pkg $re failed, but not with its recorded reason ('$reason'); fix the new failure or record it in KNOWN_FAILING" >&2
		exit 1
	fi
	echo "still failing, as recorded: $pkg $re"
	{ grep -E '^\s+\S+_test\.go:[0-9]+:' <<<"$out" || true; } | sed 's/^/    /'
done

GATE_STEPS+=", go vet, go test, assist worker, scripts typecheck, conformance"
read -r go_ran go_skipped <"$REAL_GO"
corpus="go ${go_ran} ran / ${go_skipped} skipped"
echo
echo "real corpus: $corpus"
if [[ -n "${HASALA_PRIVATE_FIXTURES:-}" ]]; then
	if [[ "$go_skipped" -ne 0 || "$go_ran" -eq 0 ]]; then
		echo "check: HASALA_PRIVATE_FIXTURES is set, so every real-corpus test must run and none may skip" >&2
		exit 1
	fi
	echo "check: OK ($GATE_STEPS; real corpus included)"
	ci_report "Real corpus included" "$corpus."
else
	echo "check: OK ($GATE_STEPS)"
	echo "check: WITHOUT the real corpus: HASALA_PRIVATE_FIXTURES is unset, so the tests above that read real bank mail were skipped"
	ci_report "Real corpus skipped" "$corpus. HASALA_PRIVATE_FIXTURES is unset, so every test that reads real bank mail skipped by name (listed in the log); this run is the gate without the real corpus."
fi
if ((${#NOT_RUN[@]})); then
	not_run="$(printf '%s; ' "${NOT_RUN[@]}")"
	echo "check: NOT RUN: ${not_run%; }"
	ci_report "Gate steps not run" "${not_run%; }"
fi
