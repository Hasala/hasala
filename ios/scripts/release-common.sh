# shellcheck shell=bash

# shellcheck disable=SC2034 # read by the scripts that source this file
HASALA_TRIAL_MARKER="TRIAL"

# shellcheck disable=SC2034
RELEASE_API_BASE_URL=https://api.hasala.app

hasala_build_root() {
	if [[ -z "${HASALA_BUILD_DIR:-}" ]]; then
		printf '%s\n' "$1/build"
		return 0
	fi
	if [[ "${HASALA_TEST_MODE:-}" != 1 ]]; then
		echo "HASALA_BUILD_DIR is set ('$HASALA_BUILD_DIR') but HASALA_TEST_MODE is not 1: HASALA_BUILD_DIR is for the offline script tests only; unset it to release from $1/build" >&2
		return 1
	fi
	echo "TEST MODE (HASALA_TEST_MODE=1): builds and last-build-number are in $HASALA_BUILD_DIR, not $1/build" >&2
	printf '%s\n' "$HASALA_BUILD_DIR"
}

hasala_now() {
	if [[ -z "${HASALA_TEST_NOW:-}" ]]; then
		/bin/date -u +%Y-%m-%dT%H:%M:%SZ
		return 0
	fi
	if [[ "${HASALA_TEST_MODE:-}" != 1 ]]; then
		echo "HASALA_TEST_NOW is set ('$HASALA_TEST_NOW') but HASALA_TEST_MODE is not 1: HASALA_TEST_NOW is for the offline script tests only" >&2
		return 1
	fi
	printf '%s\n' "$HASALA_TEST_NOW"
}

hasala_build_newer() {
	local new="$1" last="$2"
	[[ "$new" =~ ^[0-9]{6}\.1[0-9]{4}$ && "$last" =~ ^[0-9]{6}\.1[0-9]{4}$ ]] || return 1
	local nd="${new%%.*}" nt="${new##*.}" ld="${last%%.*}" lt="${last##*.}"
	((10#$nd > 10#$ld)) && return 0
	((10#$nd == 10#$ld && 10#$nt > 10#$lt))
}

hasala_record_build() {
	local root="$1" build="$2"
	mkdir -p -- "$root" || return 1
	/usr/bin/lockf -k -t 30 "$root/last-build-number.lock" "$BASH" -c \
		'source "$1" && hasala_record_build_locked "$2" "$3"' _ "${BASH_SOURCE[0]}" "$root" "$build"
}

hasala_record_build_locked() {
	local root="$1" build="$2" last
	if [[ -f "$root/last-build-number" ]]; then
		last="$(cat -- "$root/last-build-number")" || return 1
		if ! hasala_build_newer "$build" "$last"; then
			echo "build $build is not newer than the recorded $last" >&2
			return 1
		fi
	fi
	printf '%s\n' "$build" >"$root/last-build-number.tmp" &&
		mv -f -- "$root/last-build-number.tmp" "$root/last-build-number"
}

hasala_marketing_version() {
	local dir="$1" f line found=()
	for f in "$dir"/*.xcconfig; do
		[[ -f "$f" ]] || continue
		while IFS= read -r line || [[ -n "$line" ]]; do
			[[ "$line" =~ ^[[:space:]]*MARKETING_VERSION ]] || continue
			if [[ "$line" =~ ^[[:space:]]*MARKETING_VERSION[[:space:]]*=[[:space:]]*([^[:space:]]*)[[:space:]]*$ ]]; then
				found+=("${BASH_REMATCH[1]}")
			else
				echo "${f##*/}: cannot read '$line'; set MARKETING_VERSION = X.Y.Z, unconditionally, once" >&2
				return 1
			fi
		done <"$f"
	done
	if ((${#found[@]} != 1)); then
		echo "$dir/*.xcconfig set MARKETING_VERSION ${#found[@]} times; it must be set exactly once" >&2
		return 1
	fi
	if [[ ! "${found[0]}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
		echo "MARKETING_VERSION is '${found[0]}', not X.Y.Z" >&2
		return 1
	fi
	printf '%s\n' "${found[0]}"
}

hasala_sha256() {
	local out
	out="$(/usr/bin/shasum -a 256 -- "$1")" || return 1
	out="${out%% *}"
	[[ "$out" =~ ^[0-9a-f]{64}$ ]] || return 1
	printf '%s\n' "$out"
}

hasala_sample_manifest_sha256() {
	local line
	[[ -f "$1" ]] || return 1
	line="$(grep -E '^[[:space:]]*public static let sha256 = "[0-9a-f]{64}"' -- "$1" || true)"
	[[ "$line" =~ \"([0-9a-f]{64})\" ]] || return 1
	printf '%s\n' "${BASH_REMATCH[1]}"
}

hasala_sample_pinned() {
	local ios="$1" golden="$1/scripts/golden/maya-v1.sha256" want="" pinned="" got=""
	local resources="$1/HasalaCore/Sources/HasalaCore/Resources"
	if [[ -f "$golden" ]]; then want="$(head -n 1 -- "$golden")"; fi
	if [[ ! "$want" =~ ^[0-9a-f]{64}$ ]]; then
		echo "golden/maya-v1.sha256 is missing or is not one SHA-256 in hex" >&2
		return 1
	fi
	if ! pinned="$(hasala_sample_manifest_sha256 "$resources/SampleManifest.swift")"; then
		echo "cannot read SampleManifest.sha256 from ${resources#"$ios/"}/SampleManifest.swift" >&2
		return 1
	fi
	if [[ "$want" != "$pinned" ]]; then
		echo "golden/maya-v1.sha256 ($want) is not SampleManifest.sha256 ($pinned); regenerate the seed (HASALA_WRITE_SAMPLE=1) and update both" >&2
		return 1
	fi
	if ! got="$(hasala_sha256 "$resources/sample/maya-v1.json" 2>/dev/null)"; then
		echo "cannot hash sample/maya-v1.json" >&2
		return 1
	fi
	if [[ "$got" != "$want" ]]; then
		echo "sample/maya-v1.json has SHA-256 $got, not golden/maya-v1.sha256's $want" >&2
		return 1
	fi
}

hasala_is_macho() {
	local magic
	magic="$(od -An -tx1 -N4 -- "$1" 2>/dev/null)" || return 1
	magic="${magic//[[:space:]]/}"
	case "$magic" in
	cffaedfe | cefaedfe | feedfacf | feedface | cafebabe | cafebabf | bebafeca | bfbafeca) return 0 ;;
	*) return 1 ;;
	esac
}

hasala_absent() {
	hasala_grep_absent -E "$@"
}

hasala_absent_i() {
	hasala_grep_absent -iE "$@"
}

hasala_grep_absent() {
	(($# > 2)) || return 1
	local flags="$1" re="$2" rc=0
	shift 2
	LC_ALL=C grep -r -a -q "$flags" -e "$re" -- "$@" || rc=$?
	[[ "$rc" == 1 ]]
}

HASALA_PASS_RE='^PASS ([0-9]+)/([0-9]+) sha256=([0-9a-f]{64})$'

hasala_summary_passed() {
	local summary="$1" ipa="$2" build="$3" first last oks want
	if [[ ! -f "$summary" ]]; then
		echo "there is no $summary; only an .ipa that archive.sh exported and inspected can be uploaded" >&2
		return 1
	fi
	first="$(head -n 1 -- "$summary")" || return 1
	if [[ "$first" != "Hasala $build ("* ]]; then
		echo "$summary is for '$first', not build $build" >&2
		return 1
	fi
	if ! hasala_absent '^  FAIL' "$summary"; then
		echo "build $build failed inspection (see $summary)" >&2
		return 1
	fi
	last="$(tail -n 1 -- "$summary")" || return 1
	if [[ ! "$last" =~ $HASALA_PASS_RE ]]; then
		echo "$summary does not end in the PASS line; the inspection did not finish (last line: '$last')" >&2
		return 1
	fi
	local passed="${BASH_REMATCH[1]}" total="${BASH_REMATCH[2]}" hash="${BASH_REMATCH[3]}"
	oks="$(grep -c -e '^  ok    ' -- "$summary" || true)"
	if [[ "$passed" != "$total" || "$total" == 0 || "$oks" != "$total" ]]; then
		echo "$summary says PASS $passed/$total but lists ${oks:-no} passing checks" >&2
		return 1
	fi
	if ! want="$(hasala_sha256 "$ipa")"; then
		echo "cannot hash $ipa" >&2
		return 1
	fi
	if [[ "$hash" != "$want" ]]; then
		echo "$ipa is not the file that was inspected: its sha256 is $want, the summary's is $hash" >&2
		return 1
	fi
}
