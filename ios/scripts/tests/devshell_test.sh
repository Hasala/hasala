#!/usr/bin/env bash
set -euo pipefail
tests="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$tests/../../.." && pwd)"
nix="$(command -v nix || echo /nix/var/nix/profiles/default/bin/nix)"
if [[ ! -x "$nix" ]]; then
	echo "FAIL nix is not installed; this test needs the repository's devShell"
	exit 1
fi
# shellcheck disable=SC2016 # the script is for the devShell's bash, which expands $1
"$nix" develop "$repo" --command bash -c '
	if ! { stat --version && date --version; } >/dev/null 2>&1; then
		echo "FAIL the devShell does not put GNU stat and date first on PATH; this test would prove nothing"
		exit 1
	fi
	echo "ok   the devShell puts GNU stat and date first on PATH"
	exec "$1"
' devshell_test "$tests/run.sh"
