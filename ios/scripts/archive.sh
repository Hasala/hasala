#!/usr/bin/env bash
set -euo pipefail

NON_EXEMPT_ENCRYPTION=false

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ios="$(cd "$here/.." && pwd)"
repo="$(cd "$ios/.." && pwd)"
# shellcheck source=asc-env.sh
source "$here/asc-env.sh"
# shellcheck source=release-common.sh
source "$here/release-common.sh"

allow_dirty=0
allow_branch=0
for a in "$@"; do
	case "$a" in
	--allow-dirty) allow_dirty=1 ;;
	--allow-branch) allow_branch=1 ;;
	*)
		echo "usage: archive.sh [--allow-dirty] [--allow-branch]" >&2
		exit 2
		;;
	esac
done
if ! build_root="$(hasala_build_root "$ios")"; then
	echo "archive: refusing to run with HASALA_BUILD_DIR set outside test mode" >&2
	exit 2
fi

trial=()
tree="$(git -C "$repo" status --porcelain)"
if [[ -n "$tree" ]]; then
	if [[ "$allow_dirty" == 1 ]]; then
		echo "archive: WARNING the tree is dirty; HasalaGitCommit names HEAD, not what was built" >&2
		trial+=("dirty tree")
	else
		echo "archive: the working tree is dirty; commit first (or --allow-dirty for a local trial)" >&2
		exit 10
	fi
fi
branch="$(git -C "$repo" branch --show-current)"
if [[ "$branch" != "main" ]]; then
	if [[ "$allow_branch" == 1 ]]; then
		echo "archive: WARNING on branch '${branch:-detached HEAD}', not main" >&2
		trial+=("branch ${branch:-detached HEAD}")
	else
		echo "archive: on branch '${branch:-detached HEAD}'; releases are archived from main (or --allow-branch for a local trial)" >&2
		exit 11
	fi
fi
stubs_rc=0
stubs="$(git -C "$repo" grep -l --untracked -e IntegrationStub -- ios ':(exclude)ios/scripts')" || stubs_rc=$?
if [[ "$stubs_rc" != 1 ]]; then
	if [[ "$stubs_rc" == 0 ]]; then
		echo "archive: IntegrationStub is still used under ios/; finish these first:" >&2
		sed 's/^/  /' <<<"$stubs" >&2
	else
		echo "archive: cannot search ios/ for IntegrationStub (git grep exit $stubs_rc)" >&2
	fi
	exit 13
fi
if ! "$here/privacy-lint.sh" >&2; then
	echo "archive: privacy-lint.sh failed; declare the API in ios/Hasala/PrivacyInfo.xcprivacy or stop using it" >&2
	exit 13
fi
if ! hasala_sample_pinned "$ios"; then
	echo "archive: the sample seed and its two pins disagree, so this build would fail inspection (I6b)" >&2
	exit 13
fi
if ((${#trial[@]} == 0)); then
	author="$(sed -nE 's/^[[:space:]]*public static let author = ([0-9]+)$/\1/p' "$ios/HasalaCore/Sources/HasalaCore/Wire/Op.swift")"
	if [[ ! "$author" =~ ^[0-9]+$ ]]; then
		echo "archive: cannot read SchemaVersion.author from ios/HasalaCore/Sources/HasalaCore/Wire/Op.swift" >&2
		exit 13
	fi
	if ! meta="$(curl --fail --silent --show-error --proto =https --max-time 20 "$RELEASE_API_BASE_URL/api/v1/meta")"; then
		echo "archive: cannot read op_version_ceiling from $RELEASE_API_BASE_URL/api/v1/meta" >&2
		exit 13
	fi
	if [[ ! "$meta" =~ \"op_version_ceiling\"[[:space:]]*:[[:space:]]*([0-9]+) ]]; then
		echo "archive: cannot read op_version_ceiling from $RELEASE_API_BASE_URL/api/v1/meta" >&2
		exit 13
	fi
	ceiling="${BASH_REMATCH[1]}"
	if ((10#$ceiling < 10#$author)); then
		echo "archive: this build writes op schema $author, but $RELEASE_API_BASE_URL reports op_version_ceiling $ceiling; raise OpVersionCeiling and deploy hasalad first" >&2
		exit 13
	fi
fi
asc_resolve_key || exit 14
xcode="$(xcodebuild -version 2>/dev/null || true)"
xcode="${xcode%%$'\n'*}"
if [[ ! "$xcode" =~ ^Xcode\ 27\. ]]; then
	echo "archive: needs Xcode 27.x (xcodebuild -version says '${xcode:-nothing}')" >&2
	exit 16
fi
if ! MARKETING_VERSION="$(hasala_marketing_version "$ios/Config")"; then
	echo "archive: cannot read MARKETING_VERSION from ios/Config/*.xcconfig" >&2
	exit 2
fi

if ! now="$(hasala_now)"; then
	echo "archive: refusing to run with HASALA_TEST_NOW set outside test mode" >&2
	exit 2
fi
BUILD="$("$here/build_number.sh" "$now")"
SHA="$(git -C "$repo" rev-parse --short=12 HEAD)"
last_file="$build_root/last-build-number"
if [[ -f "$last_file" ]]; then
	last="$(cat "$last_file")"
	if ! hasala_build_newer "$BUILD" "$last"; then
		echo "archive: build $BUILD is not newer than the last upload $last; wait a minute" >&2
		exit 21
	fi
fi

OUT="$build_root/$BUILD"
mkdir -p "$build_root"
if [[ -e "$OUT" ]] || ! mkdir "$OUT"; then
	echo "archive: $OUT exists already: build $BUILD has been archived (one archive per UTC minute); wait a minute" >&2
	exit 21
fi
if ((${#trial[@]})); then
	printf 'local trial, not for upload: %s\n' "${trial[@]}" >"$OUT/$HASALA_TRIAL_MARKER"
fi
auth=(
	-allowProvisioningUpdates
	-authenticationKeyPath "$ASC_KEY_PATH"
	-authenticationKeyID "$ASC_KEY_ID"
	-authenticationKeyIssuerID "$ASC_ISSUER_ID"
)

echo "archive: Hasala $MARKETING_VERSION ($BUILD) at $SHA -> $OUT"

if ! xcodebuild archive \
	-project "$ios/Hasala.xcodeproj" -scheme Hasala -configuration Release \
	-destination 'generic/platform=iOS' \
	-archivePath "$OUT/Hasala.xcarchive" \
	-disableAutomaticPackageResolution \
	"${auth[@]}" \
	CURRENT_PROJECT_VERSION="$BUILD" HASALA_GIT_COMMIT="$SHA" \
	>"$OUT/archive.log" 2>&1; then
	echo "archive: xcodebuild archive failed; the signing errors are:" >&2
	grep -E 'error:|No profiles|No signing|Provisioning|certificate|Automatic signing' "$OUT/archive.log" | sort -u | head -40 >&2 || true
	echo "archive: full log: $OUT/archive.log" >&2
	exit 30
fi

if ((${#trial[@]} == 0)); then
	tree_after="$(git -C "$repo" status --porcelain)"
	sha_after="$(git -C "$repo" rev-parse --short=12 HEAD)"
	branch_after="$(git -C "$repo" branch --show-current)"
	if [[ -n "$tree_after" || "$sha_after" != "$SHA" || "$branch_after" != "$branch" ]]; then
		echo "archive: the checkout changed while xcodebuild was building $SHA on $branch, so this archive is not exported; archive again from a worktree nothing else uses" >&2
		exit 10
	fi
fi

if ! xcodebuild -exportArchive \
	-archivePath "$OUT/Hasala.xcarchive" \
	-exportPath "$OUT/export" \
	-exportOptionsPlist "$here/ExportOptions.plist" \
	"${auth[@]}" \
	>"$OUT/export.log" 2>&1; then
	echo "archive: xcodebuild -exportArchive failed; the signing errors are:" >&2
	grep -E 'error:|No profiles|No signing|Provisioning|certificate|Cloud|distribution' "$OUT/export.log" | sort -u | head -40 >&2 || true
	if grep -qiE "signing certificate|provisioning profile|No profiles for|cloud-managed" "$OUT/export.log"; then
		cat >&2 <<'HINT'
archive: the export signs manually (ExportOptions.plist) and needs, on this Mac:
  - an "Apple Distribution" identity for team 8CFG28JHP3 in a keychain on the
    search list (security find-identity -v -p codesigning), and
  - the App Store profile named "Hasala App Store" for app.hasala.ios and the one
    named "Hasala Widgets App Store" for app.hasala.ios.widgets (App Group
    group.app.hasala.ios), made with that certificate, installed in
    ~/Library/Developer/Xcode/UserData/Provisioning Profiles.
  Create either through the App Store Connect API (POST /v1/certificates,
  certificateType DISTRIBUTION, with a CSR whose key stays in the keychain;
  POST /v1/profiles, profileType IOS_APP_STORE), or in the developer portal.
  When the certificate changes, make new profiles with that certificate and the
  SAME names, and move the old profile files out of
  ~/Library/Developer/Xcode/UserData/Provisioning Profiles (one name, one profile).
The development archive above is fine; only the distribution re-sign failed.
HINT
	fi
	echo "archive: full log: $OUT/export.log" >&2
	exit 31
fi

IPA="$OUT/export/Hasala.ipa"
[[ -f "$IPA" ]] || {
	echo "archive: export reported success but $IPA is missing" >&2
	exit 31
}

summary="$OUT/summary.txt"
inspected=0
"$here/inspect-ipa.sh" "$IPA" "$BUILD" "$MARKETING_VERSION" "$SHA" "$NON_EXEMPT_ENCRYPTION" >"$summary" 2>&1 || inspected=$?
cat "$summary"
if [[ "$inspected" != 0 ]] || ! hasala_summary_passed "$summary" "$IPA" "$BUILD"; then
	echo "archive: the exported .ipa failed inspection; do not upload it" >&2
	exit 40
fi
if [[ -f "$OUT/$HASALA_TRIAL_MARKER" ]]; then
	cat "$OUT/$HASALA_TRIAL_MARKER"
	echo "archive: done (local trial; upload.sh will refuse this build)"
else
	echo "archive: done. To upload (not done here): ios/scripts/upload.sh $IPA"
fi
