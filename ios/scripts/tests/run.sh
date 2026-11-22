#!/usr/bin/env bash
set -euo pipefail
tests="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "release-script tests with $(command -v bash) ($BASH_VERSION), stat=$(command -v stat), date=$(command -v date)"
logs="$(mktemp -d)"
trap 'rm -rf "$logs"' EXIT

names=()
for t in "$tests"/*_test.sh; do
	[[ "${t##*/}" == devshell_test.sh ]] && continue
	names+=("${t##*/}")
done

one() {
	local name="$1" begin=$SECONDS rc=0
	"$tests/$name" >"$logs/$name.out" 2>&1 || rc=$?
	echo "$rc $((SECONDS - begin))" >"$logs/$name.result"
}

if [[ "${RELEASE_TEST_JOBS:-}" == 1 ]]; then
	for name in "${names[@]}"; do one "$name"; done
else
	for name in "${names[@]}"; do one "$name" & done
	wait
fi

failed=()
for name in "${names[@]}"; do
	rc=1 took="?"
	if [[ -s "$logs/$name.result" ]]; then read -r rc took <"$logs/$name.result"; fi
	echo "== $name (exit $rc, $took s)"
	cat "$logs/$name.out"
	if [[ "$rc" != 0 ]]; then failed+=("$name"); fi
done
if ((${#failed[@]})); then
	echo "FAILED: ${failed[*]}"
	exit 1
fi
echo "all ${#names[@]} release-script tests passed"
