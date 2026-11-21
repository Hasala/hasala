#!/usr/bin/env bash
set -euo pipefail

RELEASE_ASSIST_BASE_URL=https://assist.hasala.app

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=release-common.sh
source "$here/release-common.sh"

usage() {
	echo "usage: inspect-ipa.sh <ipa> <build> <marketing-version> <commit> <true|false>" >&2
	exit 2
}
(($# == 5)) || usage
ipa="$1" build="$2" marketing="$3" commit="$4" encryption="$5"
[[ -f "$ipa" ]] || usage
[[ "$build" =~ ^[0-9]{6}\.1[0-9]{4}$ ]] || usage
[[ "$marketing" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage
[[ "$commit" =~ ^[0-9a-f]{7,40}$ ]] || usage
[[ "$encryption" == true || "$encryption" == false ]] || usage

echo "Hasala $build ($commit)"

tmp="${TMPDIR:-/tmp}"
work="$(mktemp -d "${tmp%/}/hasala-inspect-ipa.XXXXXX")"
trap 'chmod -R u+rwx "$work" 2>/dev/null || true; rm -rf "$work" || true' EXIT
if ! cp -- "$ipa" "$work/inspected.ipa" || ! sha="$(hasala_sha256 "$work/inspected.ipa")" ||
	! unzip -q "$work/inspected.ipa" -d "$work/x"; then
	echo "  FAIL  the .ipa can be hashed and unzipped"
	exit 40
fi
payload="$work/x/Payload"
app="$payload/Hasala.app"
bin="$app/Hasala"
info="$app/Info.plist"
ents="$work/entitlements.plist"
plists="$work/plists"
golden="$here/golden/app.release.entitlements.plist"
appex="$app/PlugIns/HasalaWidgets.appex"
appex_info="$appex/Info.plist"
appex_ents="$work/widgets.entitlements.plist"
appex_golden="$here/golden/widgets.release.entitlements.plist"

if ! /usr/bin/codesign -d --entitlements - --xml "$app" >"$ents" 2>/dev/null; then rm -f "$ents"; fi
if [[ ! -d "$appex" ]] || ! /usr/bin/codesign -d --entitlements - --xml "$appex" >"$appex_ents" 2>/dev/null; then
	rm -f "$appex_ents"
fi

plist_text() {
	local f n=0
	mkdir -- "$plists" && find "$payload" -type f -print0 >"$work/files" &&
		/usr/bin/plutil -convert xml1 -o "$plists/Info.plist.xml" "$info" >/dev/null 2>&1 &&
		[[ -s "$plists/Info.plist.xml" ]] || return 1
	while IFS= read -r -d '' f; do
		n=$((n + 1))
		[[ "$f" != "$info" ]] || continue
		/usr/bin/plutil -convert xml1 -o "$plists/$n.xml" "$f" >/dev/null 2>&1 || rm -f -- "$plists/$n.xml"
	done <"$work/files"
}
if ! plist_text; then rm -rf -- "$plists"; fi
in_no_file() {
	[[ -d "$app" && -d "$plists" ]] && hasala_absent "$1" "$payload" "$plists"
}
in_no_file_i() {
	[[ -d "$app" && -d "$plists" ]] && hasala_absent_i "$1" "$payload" "$plists"
}

plist_get() {
	/usr/bin/python3 -I - "$1" "$2" <<'PY'
import os, plistlib, sys
try:
    with open(sys.argv[1], "rb") as f:
        d = plistlib.load(f)
except Exception as e:
    print(f"        {os.path.basename(sys.argv[1])}: {type(e).__name__}", file=sys.stderr)
    sys.exit(1)
if not isinstance(d, dict):
    sys.exit(1)
if sys.argv[2] not in d:
    sys.exit(3)
v = d[sys.argv[2]]
if isinstance(v, bool):
    print("true" if v else "false")
elif isinstance(v, (str, int)):
    print(v)
else:
    sys.exit(4)
PY
}
is() {
	local got
	got="$(plist_get "$1" "$2")" && [[ "$got" == "$3" ]]
}
lacks() {
	local rc=0
	plist_get "$1" "$2" >/dev/null 2>&1 || rc=$?
	[[ "$rc" == 3 ]]
}
valid_plist() { [[ -s "$1" ]] && /usr/bin/plutil -lint -s "$1" >/dev/null; }

ents_match_golden() {
	ents_match "$golden" "$ents"
}
ents_match() {
	valid_plist "$2" || return 1
	/usr/bin/python3 -I - "$1" "$2" <<'PY'
import plistlib, sys
def norm(path):
    with open(path, "rb") as f:
        d = plistlib.load(f)
    d.pop("beta-reports-active", None)
    return {k: sorted(v) if isinstance(v, list) else v for k, v in d.items()}
want, got = norm(sys.argv[1]), norm(sys.argv[2])
for k in sorted(set(want) | set(got)):
    if want.get(k) != got.get(k):
        print(f"        {k}: want {want.get(k)!r}, got {got.get(k)!r}", file=sys.stderr)
sys.exit(0 if want == got else 1)
PY
}

privacy_manifest_ok() {
	valid_plist "$app/PrivacyInfo.xcprivacy" || return 1
	/usr/bin/python3 -I - "$app/PrivacyInfo.xcprivacy" <<'PY'
import plistlib, sys
want = {"NSPrivacyCollectedDataType" + t for t in
        ("UserID", "DeviceID", "EmailAddress", "Name", "OtherFinancialInfo")}
with open(sys.argv[1], "rb") as f:
    d = plistlib.load(f)
bad = []
if d.get("NSPrivacyTracking") is not False:
    bad.append("NSPrivacyTracking is not false")
entries = d.get("NSPrivacyCollectedDataTypes")
if not isinstance(entries, list) or not all(isinstance(e, dict) for e in entries):
    bad.append("NSPrivacyCollectedDataTypes is not a list of dictionaries")
    entries = []
got = [e.get("NSPrivacyCollectedDataType") for e in entries]
if len(got) != len(want) or set(got) != want:
    bad.append(f"collected types {got}, want exactly {sorted(want)}")
for e in entries:
    if e.get("NSPrivacyCollectedDataTypeTracking") is not False:
        bad.append(f"{e.get('NSPrivacyCollectedDataType')} is not marked as not used for tracking")
for b in bad:
    print("        " + b, file=sys.stderr)
sys.exit(1 if bad else 0)
PY
}

widget_privacy_manifest_ok() {
	valid_plist "$appex/PrivacyInfo.xcprivacy" || return 1
	/usr/bin/python3 -I - "$appex/PrivacyInfo.xcprivacy" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as f:
    d = plistlib.load(f)
bad = []
if d.get("NSPrivacyTracking") is not False:
    bad.append("NSPrivacyTracking is not false")
if d.get("NSPrivacyTrackingDomains", []) != []:
    bad.append("NSPrivacyTrackingDomains is not empty")
if d.get("NSPrivacyCollectedDataTypes", []) != []:
    bad.append("NSPrivacyCollectedDataTypes is not empty")
for b in bad:
    print("        " + b, file=sys.stderr)
sys.exit(1 if bad else 0)
PY
}

widget_versions_match() {
	local v s
	v="$(plist_get "$info" CFBundleVersion)" && s="$(plist_get "$info" CFBundleShortVersionString)" &&
		is "$appex_info" CFBundleVersion "$v" && is "$appex_info" CFBundleShortVersionString "$s" &&
		is "$appex_info" CFBundleIdentifier app.hasala.ios.widgets
}

no_forbidden_files() {
	[[ -d "$app" ]] || return 1
	find "$payload" \( -iname "*.eml" -o -iname "*.mbox" -o -path "*conformance*" -o -path "*fixtures*" \
		-o -iname "*.sqlite" -o -iname "*.db" -o -iname "*.p8" -o -iname "*.env" \) -print >"$work/forbidden.txt" || return 1
	if [[ -s "$work/forbidden.txt" ]]; then
		sed 's/^/        /' "$work/forbidden.txt" >&2
		return 1
	fi
}

CRYPTO_SYMBOLS='argon2|sodium|crypto_|EVP_|BoringSSL|mbedtls|wolfSSL|scrypt|bcrypt'
no_third_party_crypto() {
	local f main=0
	[[ -s "$bin" ]] && find "$payload" -type f -print0 >"$work/all-files" && : >"$work/symbols.txt" || return 1
	while IFS= read -r -d '' f; do
		hasala_is_macho "$f" || continue
		[[ "$f" != "$bin" ]] || main=1
		if ! /usr/bin/xcrun nm -g -- "$f" >"$work/nm.txt" 2>/dev/null; then
			echo "        nm cannot read ${f#"$payload/"}" >&2
			return 1
		fi
		sed "s|^|${f#"$payload/"}: |" "$work/nm.txt" >>"$work/symbols.txt" || return 1
	done <"$work/all-files"
	[[ "$main" == 1 && -s "$work/symbols.txt" ]] || return 1
	if ! hasala_absent "$CRYPTO_SYMBOLS" "$work/symbols.txt"; then
		grep -E -e "$CRYPTO_SYMBOLS" -- "$work/symbols.txt" | head -n 10 | sed 's/^/        /' >&2 || true
		return 1
	fi
}

no_javascriptcore() {
	[[ -s "$bin" ]] && /usr/bin/otool -L "$bin" >"$work/linked.txt" &&
		grep -q libSystem "$work/linked.txt" && hasala_absent 'JavaScriptCore' "$work/linked.txt"
}

icon_compiled() {
	[[ -s "$app/Assets.car" ]] && /usr/bin/xcrun assetutil --info "$app/Assets.car" >"$work/assets.json" 2>/dev/null &&
		/usr/bin/python3 -I - "$work/assets.json" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    items = json.load(f)
sys.exit(0 if any(isinstance(i, dict) and i.get("Name") == "AppIcon" for i in items) else 1)
PY
}

minos_26() {
	[[ -s "$bin" ]] && /usr/bin/xcrun vtool -show-build "$bin" >"$work/build-version.txt" 2>/dev/null &&
		grep -qE '^[[:space:]]*minos 26\.0$' "$work/build-version.txt"
}

pass=0 total=0
check() {
	local label="$1"
	shift
	total=$((total + 1))
	if "$@"; then
		echo "  ok    $label"
		pass=$((pass + 1))
	else
		echo "  FAIL  $label"
	fi
}

check "I3 CFBundleVersion is $build" is "$info" CFBundleVersion "$build"
check "I3 CFBundleShortVersionString is $marketing (MARKETING_VERSION)" is "$info" CFBundleShortVersionString "$marketing"
check "I3 HasalaGitCommit is $commit" is "$info" HasalaGitCommit "$commit"
check "I4 ITSAppUsesNonExemptEncryption is $encryption" is "$info" ITSAppUsesNonExemptEncryption "$encryption"
check "I4 no CFBundleURLTypes" lacks "$info" CFBundleURLTypes
check "I4 no NSAppTransportSecurity" lacks "$info" NSAppTransportSecurity
check "I1 aps-environment is production" is "$ents" aps-environment production
check "I1 get-task-allow is false" is "$ents" get-task-allow false
check "I1 no ?mode=developer domain" eval 'valid_plist "$ents" && hasala_absent "mode=developer" "$ents"'
check "I1 entitlements equal golden/app.release.entitlements.plist" ents_match_golden
check "I1w widget extension entitlements equal golden/widgets.release.entitlements.plist" ents_match "$appex_golden" "$appex_ents"
check "I3w widget extension is app.hasala.ios.widgets with the app's two versions" widget_versions_match
check "I5 PrivacyInfo.xcprivacy valid; collects exactly UserID, DeviceID, EmailAddress, Name, OtherFinancialInfo" privacy_manifest_ok
check "I5w widget extension PrivacyInfo.xcprivacy valid; tracks and collects nothing" widget_privacy_manifest_ok
check "I6 no mail, fixtures, databases or keys" no_forbidden_files
bundle_ok() { "$here/check-bundle.sh" "$app" >/dev/null; }
check "I6b sample seed is golden/maya-v1.sha256; no test data or oversized resources (check-bundle.sh)" bundle_ok
check "I7 no secrets in any file" in_no_file "GOCSPX-|BEGIN (EC |RSA )?PRIVATE KEY|AuthKey_|HASALA_[A-Z_]*KEY="
check "I8 no JavaScriptCore" no_javascriptcore
check "I9 no third-party crypto symbols in any Mach-O" no_third_party_crypto
check "I10 icon compiled" icon_compiled
check "I11 minos 26.0" minos_26
check "I12 no dev hosts in any file, in any case" in_no_file_i "localhost|127\.0\.0\.1|sandbox\.push|mode=developer"
check "I12 HasalaAPIBaseURL is $RELEASE_API_BASE_URL" is "$info" HasalaAPIBaseURL "$RELEASE_API_BASE_URL"
check "I12 HasalaAssistBaseURL is $RELEASE_ASSIST_BASE_URL" is "$info" HasalaAssistBaseURL "$RELEASE_ASSIST_BASE_URL"
mock_terms="HasalaMocks|HasalaScenario|HasalaScreen|HasalaMotion|HasalaJackpot|Maya Rahman"
mock_terms+="|ScreenLaunch|MotionLaunch|JackpotLaunch|MockGraph|MockMailbox|AuthScenario|MockAccountService"
check "AT-REV-4 no mock data (HasalaMocks) in any file" in_no_file "$mock_terms"

size="$(/usr/bin/stat -f '%z' "$ipa" 2>/dev/null || echo '?')"
echo "ipa: $ipa ($size bytes)"
if ((total > 0 && pass == total)); then
	echo "PASS $pass/$total sha256=$sha"
	exit 0
fi
exit 40
