#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

own='^((gopls|govulncheck|xcodegen|nodejs|treefmt-with-config)-[0-9][0-9.]*|source|treefmt\.toml|version\.patch|nix-shell)$'
target=".#devShells.aarch64-darwin.default"

case "${1:-}" in
"")
	rc=0
	plan="$(nix build --dry-run "$target" 2>&1)" || rc=$?
	if [[ "$rc" != 0 ]]; then
		printf '%s\n' "$plan"
		echo "ci-mac-devshell-cached: nix build --dry-run $target failed (exit $rc)" >&2
		exit "$rc"
	fi
	;;
--plan)
	[[ $# == 2 ]] || {
		echo "usage: scripts/ci-mac-devshell-cached.sh [--plan FILE]" >&2
		exit 2
	}
	plan="$(cat "$2")"
	;;
*)
	echo "usage: scripts/ci-mac-devshell-cached.sh [--plan FILE]" >&2
	exit 2
	;;
esac

if [[ -n "$plan" ]] && ! grep -q -E 'will be (built|fetched)' <<<"$plan"; then
	printf '%s\n' "$plan"
	echo "ci-mac-devshell-cached: cannot read the plan of nix build --dry-run" >&2
	exit 1
fi

mapfile -t builds < <(awk '
	/will be built:$/ { on = 1; next }
	/will be fetched/ { on = 0 }
	on && $1 ~ /\.drv$/ { print $1 }
' <<<"$plan" | sed -E 's#^/nix/store/[a-z0-9]+-##; s#\.drv$##')

missing=()
for name in "${builds[@]}"; do
	[[ "$name" =~ $own ]] || missing+=("$name")
done

if ((${#missing[@]} > 0)); then
	echo "ci-mac-devshell-cached: the binary cache has no aarch64-darwin build of:" >&2
	printf '  %s\n' "${missing[@]}" >&2
	echo "A Mac builds these from source before the devShell starts. Move the nixpkgs pin to a commit that has them." >&2
	echo "If the flake builds one of them on purpose, add its name to 'own' in scripts/ci-mac-devshell-cached.sh." >&2
	exit 1
fi

echo "ci-mac-devshell-cached: ok, ${#builds[@]} derivation(s) to build, all of them the flake's own"
