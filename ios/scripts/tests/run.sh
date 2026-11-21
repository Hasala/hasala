#!/usr/bin/env bash
set -euo pipefail
tests="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "release-script tests with $(command -v bash) ($BASH_VERSION), stat=$(command -v stat), date=$(command -v date)"
failed=()
for t in "$tests"/*_test.sh; do
	[[ "${t##*/}" == devshell_test.sh ]] && continue
	echo "== ${t##*/}"
	if ! "$t"; then failed+=("${t##*/}"); fi
done
if ((${#failed[@]})); then
	echo "FAILED: ${failed[*]}"
	exit 1
fi
echo "all release-script tests passed"
