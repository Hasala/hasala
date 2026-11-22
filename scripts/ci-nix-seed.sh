#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

roots="${HASALA_NIX_ROOTS:-$HOME/.cache/hasala-nix-roots}"
mkdir -p "$roots"
system="$(nix eval --raw --impure --expr builtins.currentSystem)"

keep_flake_inputs() {
	local n=0 path
	while IFS= read -r path; do
		nix-store --realise --add-root "$roots/input-$n" "$path" >/dev/null
		n=$((n + 1))
	done < <(nix eval --raw --impure --expr \
		'builtins.concatStringsSep "\n" (map (i: i.outPath) (builtins.attrValues (builtins.getFlake (toString ./.)).inputs)) + "\n"')
	echo "kept $n flake input(s)"
}

case "${1:-}" in
devshell)
	nix develop --profile "$roots/devshell" --command true
	keep_flake_inputs
	;;
checks)
	mapfile -t checks < <(nix eval --raw ".#checks.$system" --apply \
		'cs: builtins.concatStringsSep "\n" (builtins.attrNames (removeAttrs cs [ "qa-vm" "module-eval" ])) + "\n"')
	nix build --out-link "$roots/check" --print-build-logs "${checks[@]/#/.#checks.$system.}"
	;;
vm)
	nix build --out-link "$roots/vm" --print-build-logs ".#checks.$system.qa-vm.driver"
	;;
ios-tools)
	nix develop --profile "$roots/devshell" --command true
	nix build --out-link "$roots/xcodegen" .#xcodegen
	nix build --out-link "$roots/shellcheck" --inputs-from . nixpkgs#shellcheck
	keep_flake_inputs
	;;
*)
	echo "usage: scripts/ci-nix-seed.sh devshell|checks|vm|ios-tools" >&2
	exit 2
	;;
esac
