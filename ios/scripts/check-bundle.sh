#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ios="$(cd "$here/.." && pwd)"
# shellcheck source=release-common.sh
source "$here/release-common.sh"

golden="$here/golden/maya-v1.sha256"
manifest="$ios/HasalaCore/Sources/HasalaCore/Resources/SampleManifest.swift"
seed_path="HasalaCore_CoreResources.bundle/sample/maya-v1.json"
limit=5000000

usage() {
	echo "usage: check-bundle.sh <Hasala.app | Hasala.xcarchive | Hasala.ipa>" >&2
	exit 2
}
(($# == 1)) || usage
target="${1%/}"

work="$(mktemp -d "${TMPDIR:-/tmp}/hasala-check-bundle.XXXXXX")"
trap 'chmod -R u+rwx "$work" 2>/dev/null || true; rm -rf "$work" || true' EXIT

case "$target" in
*.app) app="$target" ;;
*.xcarchive) app="$target/Products/Applications/Hasala.app" ;;
*.ipa)
	[[ -f "$target" ]] || usage
	if ! unzip -q "$target" -d "$work/x"; then
		echo "check-bundle: cannot unzip $target" >&2
		exit 1
	fi
	app="$work/x/Payload/Hasala.app"
	;;
*) usage ;;
esac
if [[ ! -d "$app" || ! -f "$app/Info.plist" ]]; then
	echo "check-bundle: no app at $app" >&2
	exit 1
fi

failed=0
fail() {
	echo "check-bundle: $1" >&2
	failed=1
}

if ! find "$app" \( -name conformance -o -path '*/conformance/*' -o -iname '*.eml' -o -name 'corpus-*' \
	-o -name 'manifest.synthetic*' \) -print >"$work/forbidden.txt"; then
	fail "cannot list $app"
elif [[ -s "$work/forbidden.txt" ]]; then
	fail "test or private data in the bundle:"
	sed "s|^$app/|    |" "$work/forbidden.txt" >&2
fi

if ! find "$app" -type f -size +"$limit"c -print0 >"$work/large.bin"; then
	fail "cannot list the large files in $app"
else
	while IFS= read -r -d '' f; do
		case "${f##*/}" in
		*.ttf | *.otf | *.ttc | merchant-dictionary.json) continue ;;
		esac
		hasala_is_macho "$f" && continue
		fail "${f#"$app/"} is larger than 5 MB and is not code, a font or the merchant dictionary"
	done <"$work/large.bin"
fi

outlook_id='A[AQ]MkAD[A-Za-z0-9_=-]{40,}|AAkALgAA[A-Za-z0-9_=-]{40,}'
rc=0
grep -rlaE -- "$outlook_id" "$app" >"$work/outlook.txt" 2>"$work/outlook.err" || rc=$?
if ((rc == 0)); then
	fail "a string shaped like an Outlook message id in:"
	sed "s|^$app/|    |" "$work/outlook.txt" >&2
elif ((rc != 1)); then
	fail "cannot search $app for Outlook message ids"
fi

seed="$app/$seed_path"
want=""
if [[ ! -f "$golden" ]] || ! want="$(head -n 1 -- "$golden")" || [[ ! "$want" =~ ^[0-9a-f]{64}$ ]]; then
	fail "golden/maya-v1.sha256 is missing or is not one SHA-256 in hex"
	want=""
fi
pinned="$(hasala_sample_manifest_sha256 "$manifest" || true)"
if [[ -z "$pinned" ]]; then
	fail "cannot read SampleManifest.sha256 from ${manifest#"$ios/"}"
elif [[ -n "$want" && "$want" != "$pinned" ]]; then
	fail "golden/maya-v1.sha256 ($want) is not SampleManifest.sha256 ($pinned); regenerate the seed (HASALA_WRITE_SAMPLE=1) and update both"
fi
if [[ ! -f "$seed" ]]; then
	fail "the sample seed $seed_path is missing"
else
	if ! got="$(hasala_sha256 "$seed")"; then
		fail "cannot hash $seed_path"
	elif [[ -n "$want" && "$got" != "$want" ]]; then
		fail "$seed_path has SHA-256 $got, not golden/maya-v1.sha256's $want"
	fi
	if ! /usr/bin/python3 -I - "$seed" <<'PY'; then
import json, re, sys

EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+")
GMAIL_ID = re.compile(r"[0-9a-f]{16}")
OUTLOOK_ID = re.compile(r"A[AQ]MkAD[A-Za-z0-9_=-]{40,}|AAkALgAA[A-Za-z0-9_=-]{40,}")
bad = []

def walk(v, key=None):
    if isinstance(v, dict):
        for k, x in v.items():
            walk(x, k)
    elif isinstance(v, list):
        for x in v:
            walk(x, key)
    elif isinstance(v, str):
        for m in EMAIL.finditer(v):
            if m.group(0) != "review@hasala.app":
                bad.append(f"an email address in {key}")
        if key == "message_id" and not (v.startswith("@message:") or v.startswith("sample-")):
            bad.append(f"message_id {v!r} is not a placeholder")
        if GMAIL_ID.fullmatch(v):
            bad.append(f"{key} looks like a Gmail message id")
        if OUTLOOK_ID.search(v):
            bad.append(f"{key} looks like an Outlook message id")

try:
    with open(sys.argv[1], "rb") as f:
        doc = json.load(f)
except Exception as e:
    print(f"    not JSON: {type(e).__name__}", file=sys.stderr)
    sys.exit(1)
if not isinstance(doc, dict) or doc.get("format") != "hasala.sample" or not isinstance(doc.get("ops"), list):
    bad.append("not a hasala.sample document with ops")
walk(doc)
for b in sorted(set(bad)):
    print("    " + b, file=sys.stderr)
sys.exit(1 if bad else 0)
PY
		fail "$seed_path is not synthetic (above)"
	fi
fi

if ((failed)); then
	exit 1
fi
echo "check-bundle: ok (no test data, no oversized resources, no Outlook message ids, the sample seed is golden/maya-v1.sha256)"
