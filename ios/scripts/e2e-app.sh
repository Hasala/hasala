#!/usr/bin/env bash
set -euo pipefail

usage() {
	echo "usage: e2e-app.sh <hasalad binary> [--server-only | <LiveE2ETests method>...]" >&2
	exit 2
}
[[ $# -ge 1 && -x "$1" ]] || usage
HASALAD="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
shift
SERVER_ONLY=0
if [[ "${1:-}" == "--server-only" ]]; then
	SERVER_ONLY=1
	shift
	[[ $# -eq 0 ]] || usage
fi

IOS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XCODEBUILD=/usr/bin/xcodebuild
XCRUN=/usr/bin/xcrun
PORT="${HASALA_E2E_PORT:-18453}"
MAIL_PORT="${HASALA_E2E_MAIL_PORT:-18454}"
SIGNING="${HASALA_E2E_SIGNING:-adhoc}"
DEVICE_TYPE="${HASALA_E2E_DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17}"
INVITES="${HASALA_E2E_INVITES:-3}"
BUNDLE_ID=app.hasala.ios
API="http://127.0.0.1:$PORT"

ALL_TESTS=(test00_launch test01_pathB test02_pathA_secondDevice test03_rebind test04_delete test05_deletedElsewhere)
sim_for() {
	case "$1" in
	test02_pathA_secondDevice | test04_delete) echo B ;;
	*) echo A ;;
	esac
}
if [[ $# -gt 0 ]]; then TESTS=("$@"); else TESTS=("${ALL_TESTS[@]}"); fi
for t in "${TESTS[@]}"; do
	[[ "$t" =~ ^test[0-9A-Za-z_]+$ ]] || {
		echo "e2e-app: '$t' is not a LiveE2ETests method name" >&2
		exit 2
	}
done

for tool in initdb pg_ctl pg_isready psql bun curl; do
	command -v "$tool" >/dev/null || {
		echo "e2e-app: $tool is missing; run inside \`nix develop\`" >&2
		exit 2
	}
done
[[ -x "$XCODEBUILD" && -x "$XCRUN" ]] || {
	echo "e2e-app: Xcode's $XCODEBUILD and $XCRUN are required" >&2
	exit 2
}
port_free() { ! /usr/sbin/lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }
for p in "$PORT" "$MAIL_PORT"; do
	port_free "$p" || {
		echo "e2e-app: 127.0.0.1:$p is already in use; set HASALA_E2E_PORT / HASALA_E2E_MAIL_PORT" >&2
		exit 2
	}
done

TMP="$(mktemp -d /tmp/pgtest-e2e-app.XXXXXX)"
echo "$$" >"$TMP/owner.pid"
STATE="$TMP/state"
MAIL="$TMP/mail"
mkdir -p "$STATE" "$MAIL" "$TMP/results"
OUT="${HASALA_E2E_OUT:-$IOS/build/e2e/$(date -u +%Y%m%dT%H%M%SZ)}"
DD="${HASALA_E2E_DERIVED_DATA:-$TMP/dd}"
SERVER_PID=""
MAIL_PID=""
WAKE_PID=""
SIMS=()

log() { printf 'e2e-app: %s\n' "$*" >&2; }

keep_logs() {
	mkdir -p "$OUT"
	for f in serve.log mail-capture.log migrate.log pg.log wake.log build.log; do
		[[ -f "$TMP/$f" ]] && cp "$TMP/$f" "$OUT/"
	done
	for f in "$TMP"/results/*; do
		[[ -e "$f" ]] && cp -R "$f" "$OUT/"
	done
	return 0
}

cleanup() {
	local status=$?
	set +e
	keep_logs
	[[ -n "$WAKE_PID" ]] && kill "$WAKE_PID" 2>/dev/null
	[[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null && wait "$SERVER_PID" 2>/dev/null
	[[ -n "$MAIL_PID" ]] && kill "$MAIL_PID" 2>/dev/null && wait "$MAIL_PID" 2>/dev/null
	pg_ctl -D "$TMP/data" -m immediate stop >/dev/null 2>&1
	for sim in ${SIMS[@]+"${SIMS[@]}"}; do
		"$XCRUN" simctl shutdown "$sim" >/dev/null 2>&1
		"$XCRUN" simctl delete "$sim" >/dev/null 2>&1
	done
	rm -rf "$TMP"
	log "logs and results: $OUT"
	exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

initdb -D "$TMP/data" -U postgres -A trust --no-sync >/dev/null
pg_ctl -D "$TMP/data" -l "$TMP/pg.log" -o "-k $TMP -c listen_addresses='' -c fsync=off" start >/dev/null
for _ in $(seq 50); do pg_isready -h "$TMP" -q && break; sleep 0.1; done

psql "host=$TMP user=postgres dbname=postgres" -v ON_ERROR_STOP=1 -q <<'SQL'
CREATE ROLE hasala_migrate LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT;
CREATE ROLE hasala_runtime LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT;
CREATE DATABASE hasala OWNER hasala_migrate;
SQL
psql "host=$TMP user=postgres dbname=hasala" -v ON_ERROR_STOP=1 -q <<'SQL'
ALTER SCHEMA public OWNER TO hasala_migrate;
REVOKE ALL ON SCHEMA public FROM PUBLIC;
REVOKE ALL ON DATABASE hasala FROM PUBLIC;
GRANT CONNECT ON DATABASE hasala TO hasala_runtime;
SQL
HASALA_MIGRATE_DSN="host=$TMP user=hasala_migrate dbname=hasala" "$HASALAD" migrate >"$TMP/migrate.log" 2>&1 || {
	cat "$TMP/migrate.log" >&2
	exit 1
}

(
	umask 077
	head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' >"$TMP/auth.key"
	head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' >"$TMP/salt.key"
	echo e2e >"$TMP/email.token"
	echo 1 >"$TMP/log-generation"
)

export HASALA_PG_DSN="host=$TMP user=hasala_runtime dbname=hasala"
export HASALA_HTTP_LISTEN="127.0.0.1:$PORT"
export HASALA_RP_ID=hasala.app HASALA_RP_ORIGINS=https://hasala.app
export HASALA_AUTH_KEY_FILE="$TMP/auth.key" HASALA_SALT_KEY_FILE="$TMP/salt.key"
export HASALA_LOG_GENERATION_FILE="$TMP/log-generation"
export HASALA_HEADROOM_PATH="$TMP" HASALA_HEADROOM_FLOOR_BYTES=1
export HASALA_EMAIL_CF_ACCOUNT_ID=00000000000000000000000000000000
export HASALA_EMAIL_API_TOKEN_FILE="$TMP/email.token"
export HASALA_EMAIL_API_BASE_URL="http://127.0.0.1:$MAIL_PORT/client/v4"
export HASALA_ADMIN_ACTOR=e2e

bun "$IOS/scripts/e2e/mail-capture.ts" --port "$MAIL_PORT" --dir "$MAIL" --token e2e >"$TMP/mail-capture.log" 2>&1 &
MAIL_PID=$!
for _ in $(seq 100); do curl -fsS "http://127.0.0.1:$MAIL_PORT/healthz" >/dev/null 2>&1 && break; sleep 0.1; done
curl -fsS "http://127.0.0.1:$MAIL_PORT/healthz" >/dev/null || {
	cat "$TMP/mail-capture.log" >&2
	exit 1
}

"$HASALAD" serve >"$TMP/serve.log" 2>&1 &
SERVER_PID=$!
server_up=0
for _ in $(seq 150); do
	kill -0 "$SERVER_PID" 2>/dev/null || break
	if curl -fsS "$API/api/v1/healthz" >/dev/null 2>&1 &&
		/usr/sbin/lsof -a -p "$SERVER_PID" -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
		server_up=1
		break
	fi
	sleep 0.1
done
[[ "$server_up" == 1 ]] || {
	log "hasalad did not come up"
	cat "$TMP/serve.log" >&2
	exit 1
}
log "hasalad is up at $API ($(curl -fsS "$API/api/v1/healthz"))"

"$HASALAD" email test e2e-selftest@example.test >/dev/null
for _ in $(seq 100); do
	grep -lq '"to": "e2e-selftest@example.test"' "$MAIL"/*.json 2>/dev/null && break
	sleep 0.1
done
grep -lq '"to": "e2e-selftest@example.test"' "$MAIL"/*.json 2>/dev/null || {
	log "the self-check email never reached the capture"
	tail -20 "$TMP/serve.log" >&2
	cat "$TMP/mail-capture.log" >&2
	exit 1
}
log "mail capture works ($(find "$MAIL" -name '*.json' | wc -l | tr -d ' ') message)"

: >"$STATE/invites.txt"
for _ in $(seq "$INVITES"); do
	code="$("$HASALAD" invite mint --review --note e2e 2>/dev/null | grep -oE '[A-Z2-7-]{24,29}' | tr -d - | head -1)"
	[[ ${#code} -eq 24 ]] || {
		log "invite mint printed no 24-character code"
		exit 1
	}
	echo "$code" >>"$STATE/invites.txt"
done
INVITE="$(head -1 "$STATE/invites.txt")"
log "minted $INVITES review invites"

if [[ "$SERVER_ONLY" == 1 ]]; then
	cat >&2 <<EOF
e2e-app: serving until Ctrl-C. For a run from Xcode, set these on the test action:
  TEST_RUNNER_HASALA_E2E_API=$API
  TEST_RUNNER_HASALA_E2E_MAIL_DIR=$MAIL
  TEST_RUNNER_HASALA_E2E_STATE=$STATE
  TEST_RUNNER_HASALA_E2E_INVITE=$INVITE
(other invites: $STATE/invites.txt)
EOF
	wait "$SERVER_PID"
	exit $?
fi

RUNTIME="${HASALA_E2E_RUNTIME:-$("$XCRUN" simctl list runtimes available |
	grep -oE 'com\.apple\.CoreSimulator\.SimRuntime\.iOS-[0-9-]+' | sort -V | tail -1)}"
[[ -n "$RUNTIME" ]] || {
	log "no iOS simulator runtime is installed"
	exit 1
}
SIM_A="$("$XCRUN" simctl create "hasala-e2e-a-$$" "$DEVICE_TYPE" "$RUNTIME")"
SIMS+=("$SIM_A")
SIM_B=""
for t in "${TESTS[@]}"; do
	if [[ "$(sim_for "$t")" == B && -z "$SIM_B" ]]; then
		SIM_B="$("$XCRUN" simctl create "hasala-e2e-b-$$" "$DEVICE_TYPE" "$RUNTIME")"
		SIMS+=("$SIM_B")
	fi
done
for sim in "${SIMS[@]}"; do
	"$XCRUN" simctl boot "$sim"
	"$XCRUN" simctl bootstatus "$sim" -b >/dev/null
done
log "simulators: A=$SIM_A B=${SIM_B:-none} ($RUNTIME)"

TEAM="$(sed -n 's/^DEVELOPMENT_TEAM = //p' "$IOS/Config/Shared.xcconfig" | head -1)"
case "$SIGNING" in
adhoc)
	SIGN_ARGS=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES
		DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= "AppIdentifierPrefix=$TEAM.")
	;;
team) SIGN_ARGS=() ;;
unsigned) SIGN_ARGS=(CODE_SIGNING_ALLOWED=NO) ;;
*)
	log "HASALA_E2E_SIGNING is '$SIGNING': want adhoc, team or unsigned"
	exit 2
	;;
esac

log "build-for-testing (signing: $SIGNING) into $DD"
"$XCODEBUILD" build-for-testing -project "$IOS/Hasala.xcodeproj" -scheme Hasala -configuration Debug \
	-destination "id=$SIM_A" -derivedDataPath "$DD" "${SIGN_ARGS[@]}" >"$TMP/build.log" 2>&1 || {
	grep -E 'error:|BUILD FAILED' "$TMP/build.log" | head -40 >&2
	log "build-for-testing failed; the full log is kept in $OUT/build.log"
	exit 1
}
XCTESTRUN="$(find "$DD/Build/Products" -maxdepth 1 -name '*.xctestrun' | head -1)"
[[ -n "$XCTESTRUN" ]] || {
	log "build-for-testing wrote no .xctestrun"
	exit 1
}
if [[ "$SIGNING" == adhoc ]]; then
	ENTS="$(find "$DD/Build/Intermediates.noindex" -path '*Hasala.build/Hasala.app-Simulated.xcent' | head -1)"
	if [[ -z "$ENTS" ]] || ! grep -q "$TEAM.app.hasala.ios" "$ENTS"; then
		log "the simulator entitlements lack the $TEAM.app.hasala.ios Keychain group; E3-E5 will fail"
	fi
fi

(
	while :; do
		if [[ -f "$STATE/wake-request" ]]; then
			rm -f "$STATE/wake-request"
			sim="$(cat "$STATE/current-sim")"
			if "$XCRUN" simctl push "$sim" "$BUNDLE_ID" "$IOS/scripts/e2e/wake.apns" >"$TMP/wake.out" 2>&1; then
				date -u +%Y-%m-%dT%H:%M:%SZ >"$STATE/wake-sent"
			else
				cp "$TMP/wake.out" "$STATE/wake-failed"
			fi
			cat "$TMP/wake.out" >>"$TMP/wake.log"
		fi
		sleep 0.5
	done
) &
WAKE_PID=$!

passed=()
failed=()
for t in "${TESTS[@]}"; do
	which="$(sim_for "$t")"
	if [[ "$which" == B ]]; then sim="$SIM_B"; else sim="$SIM_A"; fi
	echo "$sim" >"$STATE/current-sim"
	rm -f "$STATE/wake-sent" "$STATE/wake-failed"
	log "run $t on $which"
	status=0
	TEST_RUNNER_HASALA_E2E_API="$API" \
		TEST_RUNNER_HASALA_E2E_MAIL_DIR="$MAIL" \
		TEST_RUNNER_HASALA_E2E_STATE="$STATE" \
		TEST_RUNNER_HASALA_E2E_INVITE="$INVITE" \
		TEST_RUNNER_HASALA_E2E_DEVICE="$which" \
		"$XCODEBUILD" test-without-building -xctestrun "$XCTESTRUN" -destination "id=$sim" \
		-only-testing:"HasalaUITests/LiveE2ETests/$t" -resultBundlePath "$TMP/results/$t.xcresult" \
		-collect-test-diagnostics never \
		>"$TMP/results/$t.log" 2>&1 || status=$?
	if [[ "$status" == 0 ]] && grep -qiE "test case .*$t.* passed" "$TMP/results/$t.log" &&
		! grep -qiE "test case .*$t.* skipped" "$TMP/results/$t.log"; then
		passed+=("$t")
		log "PASS $t"
	else
		failed+=("$t")
		log "FAIL $t (exit $status)"
		grep -E 'error: |XCTAssert|failed \(|skipped' "$TMP/results/$t.log" | head -20 >&2 || true
		"$XCRUN" simctl spawn "$sim" log show --last 5m --style compact \
			--predicate 'process == "Hasala" OR process == "SpringBoard" OR process == "usernotificationsd"' \
			>"$TMP/results/$t.syslog" 2>&1 || true
		if [[ "${HASALA_E2E_CONTINUE:-0}" != 1 ]]; then
			log "stopping: the later tests build on this one (HASALA_E2E_CONTINUE=1 runs them anyway)"
			break
		fi
	fi
done

log "passed: ${passed[*]:-none}"
log "failed: ${failed[*]:-none}"
[[ ${#failed[@]} -eq 0 && ${#passed[@]} -eq ${#TESTS[@]} ]]
