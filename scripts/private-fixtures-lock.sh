#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$ROOT/private-fixtures.lock"
mode="${1:-}"
dir="${2:-${HASALA_PRIVATE_FIXTURES:-}}"

if [[ "$mode" != "write" && "$mode" != "check" ]] || [[ -z "$dir" ]]; then
	echo "usage: $0 write|check [CHECKOUT]   (CHECKOUT defaults to \$HASALA_PRIVATE_FIXTURES)" >&2
	exit 2
fi
if [[ ! -d "$dir" ]]; then
	echo "private-fixtures-lock: $dir is not a directory" >&2
	exit 1
fi

sha() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
	else
		shasum -a 256 "$1" | cut -d' ' -f1
	fi
}

fixture_files() {
	if git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		git -C "$dir" ls-files --cached --others --exclude-standard
	else
		(cd "$dir" && find . -type f ! -path './.git/*' | sed 's|^\./||')
	fi | grep -vxE 'README\.md|\.gitignore|.*/\.DS_Store|\.DS_Store' | LC_ALL=C sort
}

commit_of() {
	git -C "$dir" rev-parse HEAD 2>/dev/null || echo "unknown"
}

if [[ "$mode" == "write" ]]; then
	if [[ "$(git -C "$dir" rev-parse --is-inside-work-tree --show-prefix 2>/dev/null)" != "true" ]]; then
		echo "private-fixtures-lock: $dir is not the top of a git checkout; write needs a checkout of salehtl/hasala-fixtures" >&2
		exit 1
	fi
	if ! git -C "$dir" rev-parse --verify -q HEAD >/dev/null; then
		echo "private-fixtures-lock: $dir has no commit for the lock to name" >&2
		exit 1
	fi
	if [[ -n "$(git -C "$dir" status --porcelain)" ]]; then
		echo "private-fixtures-lock: $dir has uncommitted changes; commit them in the fixtures repo first" >&2
		exit 1
	fi
	{
		echo "# salehtl/hasala-fixtures: the private real-mail fixtures this commit expects."
		echo "# Written by scripts/private-fixtures-lock.sh write; checked by scripts/check.sh"
		echo "# when HASALA_PRIVATE_FIXTURES is set. Do not edit by hand."
		echo "commit $(commit_of)"
		while IFS= read -r f; do
			printf '%s  %s\n' "$(sha "$dir/$f")" "$f"
		done < <(fixture_files)
	} >"$LOCK"
	echo "private-fixtures-lock: wrote $(grep -c '  ' "$LOCK") file(s) at commit $(commit_of) to private-fixtures.lock"
	exit 0
fi

if [[ ! -f "$LOCK" ]]; then
	echo "private-fixtures-lock: $LOCK is missing" >&2
	exit 1
fi
want_commit="$(sed -n 's/^commit //p' "$LOCK")"
bad=0
pinned="$(mktemp)"
trap 'rm -f "$pinned"' EXIT
while IFS= read -r line; do
	[[ "$line" == "#"* || "$line" == commit* || -z "$line" ]] && continue
	want="${line%%  *}"
	f="${line#*  }"
	echo "$f" >>"$pinned"
	if [[ ! -f "$dir/$f" ]]; then
		echo "private-fixtures-lock: MISSING $f" >&2
		bad=1
	elif [[ "$(sha "$dir/$f")" != "$want" ]]; then
		echo "private-fixtures-lock: CHANGED $f" >&2
		bad=1
	fi
done <"$LOCK"
while IFS= read -r f; do
	if ! grep -qxF -- "$f" "$pinned"; then
		echo "private-fixtures-lock: NOT IN THE LOCK $f" >&2
		bad=1
	fi
done < <(fixture_files)
n="$(wc -l <"$pinned" | tr -d ' ')"
if [[ "$bad" -ne 0 ]]; then
	echo "private-fixtures-lock: $dir does not match private-fixtures.lock (pinned commit $want_commit)." >&2
	echo "Check out that commit of salehtl/hasala-fixtures, or, if the fixtures changed on purpose," >&2
	echo "run scripts/private-fixtures-lock.sh write and commit the lock with the change." >&2
	exit 1
fi
have_commit="$(commit_of)"
if [[ "$have_commit" != "$want_commit" ]]; then
	echo "private-fixtures-lock: all $n pinned files match, at commit $have_commit (the lock names $want_commit)"
else
	echo "private-fixtures-lock: all $n pinned files match, at commit $have_commit"
fi
