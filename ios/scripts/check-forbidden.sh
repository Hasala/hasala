#!/usr/bin/env bash
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../HasalaCore/Sources/HasalaCore" && pwd)"
fail=0

B='(^|[^A-Za-z0-9_])'
E='([^A-Za-z0-9_]|$)'

lint() {
	local rule="$1" name="$2" re="$3"
	shift 3
	local p f hit file targets=()
	for p in "$@"; do
		if [[ "$p" == *"*" ]]; then
			while IFS= read -r f; do targets+=("$f"); done < <(cd "$SRC" && find "${p%/*}" -path "$p" 2>/dev/null)
		elif [[ -e "$SRC/$p" ]]; then
			targets+=("$p")
		fi
	done
	[[ ${#targets[@]} -gt 0 ]] || return 0
	while IFS= read -r hit; do
		[[ -n "$hit" ]] || continue
		file="${hit%%:*}"
		grep -qF "// lint-allow: $name " "$SRC/$file" && continue
		echo "check-forbidden: Sources/HasalaCore/$(echo "$hit" | cut -d: -f1-2): $rule forbids $name here (spec 04 §2.4)" >&2
		fail=1
	done < <(cd "$SRC" && grep -rnE --include='*.swift' -- "$re" "${targets[@]}" |
		sed "s|^\./||" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)
}

BYTE_EXACT=(JSON Time Wire Norm Template/Exec Mail Categorize/Canon Replay)
for t in JSONSerialization JSONDecoder JSONEncoder DateFormatter ISO8601DateFormatter Calendar \
	Regex NSRegularExpression Double Float Decimal trimmingCharacters; do
	lint R2 "$t" "$B$t$E" "${BYTE_EXACT[@]}"
done
lint R2 'lowercased()' '\.lowercased\(\)' "${BYTE_EXACT[@]}"
lint R2 'uppercased()' '\.uppercased\(\)' "${BYTE_EXACT[@]}"
lint R2 'components(separatedBy:)' "${B}components\\(separatedBy:" "${BYTE_EXACT[@]}"
lint R2 'regex-literal' '#/' "${BYTE_EXACT[@]}"

lint R3 '[String:' '\[String:' Replay 'Domain/Fold*'
lint R3 'Set<' "${B}Set<" Replay 'Domain/Fold*'

for t in print NSLog debugPrint dump; do
	lint R7 "$t" "$B$t\\(" .
done

NOT_ADAPTERS=()
for d in "$SRC"/*/; do
	d="$(basename "$d")"
	[[ "$d" == Primitives || "$d" == Time ]] || NOT_ADAPTERS+=("$d")
done
lint R8 Date "${B}Date(\\(\\)|\\.now$E)" "${NOT_ADAPTERS[@]}"
lint R8 UUID "${B}UUID\\(\\)" "${NOT_ADAPTERS[@]}"
lint R8 SystemRandomNumberGenerator "${B}SystemRandomNumberGenerator$E" "${NOT_ADAPTERS[@]}"

IOS="$(cd "$SRC/../../.." && pwd)"
while IFS= read -r hit; do
	[[ -n "$hit" ]] || continue
	echo "check-forbidden: ios/$(echo "$hit" | cut -d: -f1-2): D1 forbids MinorExponent outside HasalaCore/Sources/HasalaCore/Money/ (amounts are hundredths at schema v4)" >&2
	fail=1
done < <(cd "$IOS" && find . \( -path ./HasalaCore/Sources/HasalaCore/Money -o -path ./HasalaCore/Tests -o -path ./HasalaKit/Tests \
	-o -path ./HasalaTests -o -path ./HasalaUITests -o -name .build -o -name DerivedData \) -prune -o -name '*.swift' -type f -print0 |
	xargs -0 grep -nE -- "${B}MinorExponent$E" /dev/null | sed "s|^\./||" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)

if [[ "$fail" != 0 ]]; then
	echo "check-forbidden: FAILED" >&2
	exit 1
fi
echo "check-forbidden: ok (R2, R3, R7, R8 over Sources/HasalaCore, D1 over ios/)"
