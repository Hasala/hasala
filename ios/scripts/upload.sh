#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ios="$(cd "$here/.." && pwd)"
# shellcheck source=asc-env.sh
source "$here/asc-env.sh"
# shellcheck source=release-common.sh
source "$here/release-common.sh"

ipa="${1:-}"
confirm="${2:-}"
if [[ -z "$ipa" || ! -f "$ipa" ]] || [[ -n "$confirm" && "$confirm" != "--yes" ]] || (($# > 2)); then
	echo "usage: upload.sh <path/to/Hasala.ipa> [--yes]" >&2
	exit 2
fi
if ! build_root="$(hasala_build_root "$ios")"; then
	echo "upload: refusing to run with HASALA_BUILD_DIR set outside test mode" >&2
	exit 2
fi
if [[ -n "${HASALA_BUILD_DIR:-}" ]] && hasala_is_macho "$(command -v xcrun || true)"; then
	echo "upload: refusing to reach the real xcrun with the builds moved to $HASALA_BUILD_DIR; test mode runs only against a stub xcrun" >&2
	exit 2
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
build=""
if unzip -p "$ipa" Payload/Hasala.app/Info.plist >"$tmp/Info.plist" 2>/dev/null; then
	build="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$tmp/Info.plist" 2>/dev/null || true)"
fi
if [[ ! "$build" =~ ^[0-9]{6}\.1[0-9]{4}$ ]]; then
	echo "upload: cannot read a build number (YYMMDD.1HHMM) from $ipa's CFBundleVersion ('$build')" >&2
	exit 40
fi

out="$build_root/$build"
ipa_dir="$(cd "$(dirname "$ipa")" && pwd -P)"
want_dir="$(cd "$out/export" 2>/dev/null && pwd -P || true)"
if [[ -z "$want_dir" || "$ipa_dir" != "$want_dir" || "$(basename "$ipa")" != "Hasala.ipa" ]]; then
	echo "upload: $ipa is not $out/export/Hasala.ipa; only the .ipa that archive.sh exported and inspected for build $build can be uploaded" >&2
	exit 40
fi
summary="$out/summary.txt"
if ! hasala_summary_passed "$summary" "$ipa" "$build"; then
	echo "upload: build $build has not passed inspection; it is not uploadable" >&2
	exit 40
fi
if [[ -f "$out/$HASALA_TRIAL_MARKER" ]]; then
	echo "upload: build $build is a local trial ($(head -n1 "$out/$HASALA_TRIAL_MARKER")); archive it again from a clean main" >&2
	exit 40
fi
last_file="$build_root/last-build-number"
if [[ -f "$last_file" ]] && ! hasala_build_newer "$build" "$(cat "$last_file")"; then
	echo "upload: build $build is not newer than the last upload $(cat "$last_file")" >&2
	exit 21
fi

asc_resolve_key || exit 14
API_PRIVATE_KEYS_DIR="$(cd "$(dirname "$ASC_KEY_PATH")" && pwd -P)"
export API_PRIVATE_KEYS_DIR
auth=(--api-key "$ASC_KEY_ID" --api-issuer "$ASC_ISSUER_ID" --p8-file-path "$ASC_KEY_PATH")

echo "upload: validating Hasala $build"
if ! xcrun altool --validate-app "$ipa" "${auth[@]}" --output-format json >"$out/validate.json"; then
	cat "$out/validate.json" >&2
	echo "upload: validation failed" >&2
	exit 50
fi
cat "$out/validate.json"

if [[ "$confirm" != "--yes" ]]; then
	echo "upload: validated only. Re-run with --yes to upload build $build."
	exit 0
fi

if ! hasala_record_build "$build_root" "$build"; then
	echo "upload: cannot record build $build in $last_file; not uploading" >&2
	exit 21
fi
upload_state() {
	printf '%s\n' "$1" >"$out/upload-state.tmp" && mv -f -- "$out/upload-state.tmp" "$out/upload-state"
}
if ! upload_state uploading; then
	echo "upload: cannot write $out/upload-state; not uploading" >&2
	exit 21
fi
echo "upload: build $build recorded in $last_file; uploading (this waits for processing)"
altool_rc=0
xcrun altool --upload-package "$ipa" "${auth[@]}" --wait --output-format json >"$out/upload.json" || altool_rc=$?
if ((altool_rc != 0)); then
	upload_state "failed $altool_rc" || echo "upload: cannot write $out/upload-state" >&2
	cat "$out/upload.json" >&2
	echo "upload: upload failed; build $build stays recorded, so archive a new build rather than re-upload this one" >&2
	exit 60
fi
upload_state uploaded || echo "upload: cannot write $out/upload-state" >&2
cat "$out/upload.json"
echo "upload: done; build $build uploaded"
