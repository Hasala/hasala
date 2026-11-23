#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

OUTPUTS=(gate swift ios ios_scripts web nixos_vm)
MAX_PATHS=10000
RESULTS=()
PATHS=()
PRINTED=""

usage() {
	echo "usage: scripts/ci-changes.sh [--log] <file of NUL-terminated changed paths> | --all" >&2
	echo "prints <output>=true|false for: ${OUTPUTS[*]} (CLAUDE.md, \"Path rules in CI\")" >&2
}

all_true() { printf '%s=true\n' "${OUTPUTS[@]}"; }

on_exit() {
	local rc=$?
	if [[ -z "$PRINTED" ]]; then
		all_true
		((rc)) || rc=2
	fi
	exit "$rc"
}
trap on_exit EXIT

die() {
	echo "ci-changes: $*; every job runs" >&2
	exit 2
}

regex() { [[ "$1" =~ $2 ]]; }

matches() {
	local rc=0
	regex "$1" "$2" || rc=$?
	((rc < 2)) || die "the pattern '$2' is not a valid regular expression"
	return "$rc"
}

SELECTOR='^scripts/ci-changes\.sh$'

rule() {
	local name="$1" inert="$2" reads="$SELECTOR${3:+|$3}" p
	for p in "${PATHS[@]}"; do
		if ! matches "$p" "$inert" || matches "$p" "$reads"; then
			RESULTS+=("$name=true")
			return 0
		fi
	done
	RESULTS+=("$name=false")
}

log_paths() {
	local token
	token="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
	[[ "$token" =~ ^[0-9a-f]{32}$ ]] || die "no random token to guard the path listing with"
	{
		echo "::group::${#PATHS[@]} changed path(s)"
		echo "::stop-commands::$token"
		((${#PATHS[@]} == 0)) || printf '%s\n' "${PATHS[@]}"
		echo "::$token::"
		echo "::endgroup::"
	} >&2
}

LOG=""
if [[ "${1:-}" == --log ]]; then
	LOG=1
	shift
fi
if [[ $# -ne 1 || -z "$1" ]]; then
	usage
	exit 2
fi
if [[ "$1" == --all ]]; then
	[[ -z "$LOG" ]] || die "--log needs a file"
	all_true
	PRINTED=1
	exit 0
fi

file="$1"
[[ -r "$file" && ! -d "$file" ]] || die "cannot read $file"
p=""
while IFS= read -r -d '' p; do
	[[ -n "$p" ]] || die "$file holds an empty path"
	PATHS+=("$p")
done <"$file"
[[ -z "$p" ]] || die "the last path in $file has no NUL terminator"

[[ -z "$LOG" ]] || log_paths

if ((${#PATHS[@]} == 0 || ${#PATHS[@]} > MAX_PATHS)); then
	if ((${#PATHS[@]})); then
		echo "ci-changes: ${#PATHS[@]} changed paths, more than $MAX_PATHS; every job runs" >&2
	else
		echo "ci-changes: no changed path; every job runs" >&2
	fi
	all_true
	PRINTED=1
	exit 0
fi

SHARED='^LICENSES/|^[^/]+\.md$|^NOTICE$'
LOCK='^private-fixtures\.lock$'
LEAKS='^\.gitleaks\.toml$'

rule gate "$SHARED|$LOCK|^(design|docs|web|ios)/" \
	'\.(go|nix)$|(^|/)go\.(mod|sum|work|work\.sum)$|^ios/HasalaCore/Sources/HasalaCore/Resources/(templates/|TemplatesManifest\.swift$)|^docs/runbooks/restore\.md$'

rule swift "$SHARED|$LEAKS|^(design|docs|web|server|scripts|infra)/|^flake\.(nix|lock)$" \
	'^server/internal/tmpl/seed/'

rule ios "$SHARED|$LOCK|$LEAKS|^(docs|web|server|conformance|scripts|infra)/"

rule ios_scripts "$SHARED|$LOCK|$LEAKS|^(design|docs|web|server|conformance|scripts|infra)/"

rule web "$SHARED|$LOCK|$LEAKS|^(design|docs|ios|server|conformance|scripts|infra)/" \
	'^docs/legal/'

rule nixos_vm "$SHARED|$LOCK|$LEAKS|^(design|docs|web|ios|conformance|scripts|infra/assist)/"

printf '%s\n' "${RESULTS[@]}"
PRINTED=1
