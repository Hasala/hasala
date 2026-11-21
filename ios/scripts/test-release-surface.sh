#!/usr/bin/env bash
set -euo pipefail

if (($# < 1 || $# > 2)); then
	echo "usage: test-release-surface.sh <simulator udid> [derived data directory]" >&2
	exit 2
fi
udid="$1"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ios="$(cd "$here/.." && pwd)"
if (($# == 2)); then
	dd="$2"
else
	dd="$(mktemp -d "${TMPDIR:-/tmp}/hasala-release-surface.XXXXXX")"
	trap 'rm -rf "$dd"' EXIT
fi

classes=(
	ReleaseSurfaceTests ReleaseSurfaceJoinTests ReleaseSurfaceSetupTests ReleaseSurfaceMailboxTests
	ReleaseSurfaceSignInTests ReleaseSurfaceHomeTests ReleaseSurfaceInsightsTests ReleaseSurfaceActivityTests
	ReleaseSurfacePlanTests ReleaseSurfaceProfileTests ReleaseSurfaceRecurringTests ReleaseSurfaceBankTextsTests
)
only=()
for c in "${classes[@]}"; do only+=("-only-testing:HasalaUITests/$c"); done

/usr/bin/xcodebuild test \
	-project "$ios/Hasala.xcodeproj" -scheme Hasala -configuration Release \
	-destination "id=$udid" -derivedDataPath "$dd" \
	"${only[@]}" \
	CODE_SIGNING_ALLOWED=NO \
	SWIFT_ACTIVE_COMPILATION_CONDITIONS=HASALA_MOCKS \
	EXCLUDED_SOURCE_FILE_NAMES= \
	ENABLE_TESTABILITY=YES
