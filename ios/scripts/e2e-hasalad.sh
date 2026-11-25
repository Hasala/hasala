#!/usr/bin/env bash
set -euo pipefail

HASALAD="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
IOS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${HASALA_E2E_PORT:-18443}"
if /usr/sbin/lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
	echo "e2e-hasalad: 127.0.0.1:$PORT is already in use; stop that process or set HASALA_E2E_PORT" >&2
	exit 2
fi
TMP="$(mktemp -d /tmp/pgtest-e2e.XXXXXX)"
echo "$$" >"$TMP/owner.pid"
SERVER_PID=""

cleanup() {
	[[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null && wait "$SERVER_PID" 2>/dev/null || true
	pg_ctl -D "$TMP/data" -m immediate stop >/dev/null 2>&1 || true
	rm -rf "$TMP"
}
trap cleanup EXIT

initdb -D "$TMP/data" -U postgres -A trust --no-sync >/dev/null
pg_ctl -D "$TMP/data" -l "$TMP/pg.log" -o "-k $TMP -c listen_addresses='' -c fsync=off" start >/dev/null
for _ in $(seq 50); do pg_isready -h "$TMP" -q && break; sleep 0.1; done

ADMIN="host=$TMP user=postgres dbname=postgres"
psql "$ADMIN" -v ON_ERROR_STOP=1 -q <<'SQL'
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

umask 077
head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' >"$TMP/auth.key"
head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' >"$TMP/salt.key"
echo 1 >"$TMP/log-generation"
SUITES=(LiveHasaladTests LivePasskeyTests LiveRecoveryTests LiveSampleSeedTests LiveGmailToReplayTests LiveOutlookToReplayTests)

serve() {
	HASALA_PG_DSN="host=$TMP user=hasala_runtime dbname=hasala" \
		HASALA_HTTP_LISTEN="127.0.0.1:$PORT" \
		HASALA_RP_ID=hasala.app HASALA_RP_ORIGINS=https://hasala.app \
		HASALA_AUTH_KEY_FILE="$TMP/auth.key" HASALA_SALT_KEY_FILE="$TMP/salt.key" \
		HASALA_LOG_GENERATION_FILE="$TMP/log-generation" \
		HASALA_HEADROOM_PATH="$TMP" HASALA_HEADROOM_FLOOR_BYTES=1 \
		"$HASALAD" serve >>"$TMP/serve.log" 2>&1 &
	SERVER_PID=$!
	local ready=0
	for _ in $(seq 100); do
		kill -0 "$SERVER_PID" 2>/dev/null || break
		if curl -fsS "http://127.0.0.1:$PORT/api/v1/healthz" >/dev/null 2>&1 &&
			/usr/sbin/lsof -a -p "$SERVER_PID" -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
			ready=1
			break
		fi
		sleep 0.1
	done
	if [[ "$ready" != 1 ]] || ! kill -0 "$SERVER_PID" 2>/dev/null; then
		cat "$TMP/serve.log" >&2
		exit 1
	fi
}

stop_serve() {
	kill "$SERVER_PID" 2>/dev/null || true
	wait "$SERVER_PID" 2>/dev/null || true
	SERVER_PID=""
}

PATH="/usr/bin:$PATH" swift build --package-path "$IOS/HasalaCore" --build-tests

status=0
for suite in "${SUITES[@]}"; do
	serve
	out="$TMP/$suite.log"
	HASALA_E2E_URL="http://127.0.0.1:$PORT" HASALA_E2E_PSQL="$(command -v psql)" \
		HASALA_E2E_DSN="host=$TMP user=postgres dbname=hasala" HASALA_E2E_AUTH_KEY_FILE="$TMP/auth.key" \
		PATH="/usr/bin:$PATH" swift test --package-path "$IOS/HasalaCore" --skip-build --filter "HasalaCoreE2ETests\.$suite/" 2>&1 |
		tee "$out" || status=$?
	if ! grep -Eq 'Test run with [1-9][0-9]* tests? in 1 suite passed' "$out"; then
		echo "e2e-hasalad: $suite did not run and pass" >&2
		status=1
	fi
	stop_serve
done
if [[ "$status" != 0 ]]; then
	echo "--- hasalad log ---" >&2
	tail -40 "$TMP/serve.log" >&2
fi
exit "$status"
