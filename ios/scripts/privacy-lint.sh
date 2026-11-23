#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ios="$(cd "$here/.." && pwd)"
excluded=(HasalaMocks TestSupport SoftAuth)

[[ $# == 0 ]] || {
	echo "usage: privacy-lint.sh" >&2
	exit 2
}

work="$(mktemp -d "${TMPDIR:-/tmp}/hasala-privacy-lint.XXXXXX")"
trap 'rm -rf "$work"' EXIT

b='(^|[^A-Za-z0-9_])'
e='([^A-Za-z0-9_]|$)'
categories=(UserDefaults FileTimestamp SystemBootTime DiskSpace ActiveKeyboards)
triggers=(
	"UserDefaults|NSUserDefaults|@AppStorage|${b}AppStorage\\("
	"[cC]reationDate|[mM]odificationDate|attributesOfItem|getattrlist|${b}stat\\(|${b}fstat\\(|${b}fstatat\\(|${b}lstat\\("
	"systemUptime|mach_absolute_time"
	"volumeAvailableCapacity|volumeTotalCapacity|systemFreeSize${e}|systemSize${e}|NSFileSystemFreeSize|NSFileSystemSize${e}|getattrlist|${b}statfs\\(|${b}statvfs\\(|${b}fstatfs\\(|${b}fstatvfs\\("
	"activeInputModes"
)

failed=0

lint_bundle() {
	local name="$1" manifest="$2"
	shift 2
	local roots=("$@") root d i c hits declared n
	local names=()
	[[ -f "$manifest" ]] || {
		echo "privacy-lint: $manifest is missing" >&2
		exit 2
	}
	if ! /usr/bin/plutil -convert xml1 -o "$work/$name.manifest.xml" "$manifest" >/dev/null 2>&1; then
		echo "privacy-lint: $manifest is not a property list" >&2
		exit 2
	fi
	grep -oE 'NSPrivacyAccessedAPICategory[A-Za-z]+' "$work/$name.manifest.xml" >"$work/$name.declared.txt" || true
	for root in "${roots[@]}"; do
		[[ -d "$root" ]] || {
			echo "privacy-lint: $root is missing" >&2
			exit 2
		}
	done
	for d in "${excluded[@]}"; do names+=(-o -name "$d"); done
	find "${roots[@]}" \( -type d \( -false "${names[@]}" \) -prune \) -o \( -type f -name '*.swift' -print \) \
		>"$work/$name.files.txt"
	[[ -s "$work/$name.files.txt" ]] || {
		echo "privacy-lint: no Swift sources found for $name" >&2
		exit 2
	}
	for i in "${!categories[@]}"; do
		c="${categories[$i]}"
		hits="$work/$name.$c.txt"
		: >"$hits"
		while IFS= read -r f; do
			grep -nE "${triggers[$i]}" "$f" | sed "s|^|${f#"$ios/"}:|" >>"$hits" || true
		done <"$work/$name.files.txt"
		grep -vE '^[^:]+:[0-9]+:[[:space:]]*(//|\*)' "$hits" >"$hits.code" || true
		declared=0
		grep -qx "NSPrivacyAccessedAPICategory$c" "$work/$name.declared.txt" && declared=1
		n="$(wc -l <"$hits.code" | tr -d ' ')"
		if [[ "$c" == ActiveKeyboards ]]; then
			if ((n > 0)); then
				echo "  FAIL  $c: must not be used ($n hits)"
				sed 's/^/        /' "$hits.code" | head -20
				failed=1
			else
				echo "  ok    $c: not used"
			fi
		elif ((n > 0 && declared == 0)); then
			echo "  FAIL  $c: used but not declared in ${manifest#"$ios/"} ($n hits)"
			sed 's/^/        /' "$hits.code" | head -20
			failed=1
		elif ((n > 0)); then
			echo "  ok    $c: declared, $n hits"
		elif ((declared == 1)); then
			echo "  warn  $c: declared, no direct hit (use may be through a wrapper)"
		else
			echo "  ok    $c: not used, not declared"
		fi
	done
}

lint_bundle app "$ios/Hasala/PrivacyInfo.xcprivacy" "$ios/Hasala" "$ios/HasalaCore/Sources" "$ios/HasalaKit/Sources"
if [[ -d "$ios/HasalaWidgets" ]]; then
	echo "widget extension (HasalaWidgets/PrivacyInfo.xcprivacy):"
	lint_bundle widgets "$ios/HasalaWidgets/PrivacyInfo.xcprivacy" "$ios/HasalaWidgets" "$ios/HasalaKit/Sources"
fi

if ((failed)); then
	echo "FAIL"
	exit 1
fi
echo "PASS"
