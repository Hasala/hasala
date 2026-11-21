#!/usr/bin/env bash
set -euo pipefail

want="2.46.0"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pick() {
	for c in "${XCODEGEN:-}" "$(command -v xcodegen 2>/dev/null || true)" /opt/homebrew/bin/xcodegen /usr/local/bin/xcodegen; do
		[[ -n "$c" && -x "$c" ]] || continue
		if [[ "$("$c" --version 2>/dev/null | sed -n 's/^Version: //p')" == "$want" ]]; then
			echo "$c"
			return 0
		fi
	done
	return 1
}

if ! xg="$(pick)"; then
	echo "generate-project: XcodeGen $want not found (set XCODEGEN=/path/to/xcodegen)" >&2
	exit 2
fi

if [[ "${1:-}" == "--check" ]]; then
	tmp="$(mktemp -d)"
	trap 'rm -rf "$tmp"' EXIT
	for d in project.yml Config Hasala HasalaWidgets HasalaTests HasalaUITests HasalaKit/Package.swift HasalaCore/Package.swift; do
		mkdir -p "$tmp/$(dirname "$d")"
		cp -R "$here/$d" "$tmp/$d"
	done
	(cd "$tmp" && "$xg" generate --spec project.yml --quiet)
	mkdir -p "$tmp/committed"
	(cd "$here" && find Hasala.xcodeproj -type f ! -path '*/xcuserdata/*' ! -path '*/xcshareddata/swiftpm/*' -print0 | xargs -0 -I{} rsync -R {} "$tmp/committed/")
	if ! diff -ru "$tmp/committed/Hasala.xcodeproj" "$tmp/Hasala.xcodeproj" >&2; then
		echo "generate-project: ios/Hasala.xcodeproj is stale; run ios/scripts/generate-project.sh and commit" >&2
		exit 1
	fi
	echo "ios/Hasala.xcodeproj matches ios/project.yml (XcodeGen $want)"
else
	(cd "$here" && "$xg" generate --spec project.yml --quiet)
	echo "generated ios/Hasala.xcodeproj with XcodeGen $want"
fi
