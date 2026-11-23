#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check="$ROOT/scripts/ci-mac-devshell-cached.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0

expect() {
	local name="$1" want="$2" text="$3" rc=0 out
	out="$("$check" --plan "$work/plan" 2>&1)" || rc=$?
	if [[ "$rc" != "$want" ]]; then
		echo "FAIL $name: exit $rc, want $want"
		printf '%s\n' "$out"
		failures=$((failures + 1))
	elif [[ -n "$text" && "$out" != *"$text"* ]]; then
		echo "FAIL $name: the output does not contain '$text'"
		printf '%s\n' "$out"
		failures=$((failures + 1))
	else
		echo "ok   $name"
	fi
}

cat >"$work/plan" <<'EOF'
these 9 derivations will be built:
  /nix/store/sffgrgdhm5s8613gx8vzy1q6xdfryhd3-treefmt.toml.drv
  /nix/store/blvz2wgwqqwf6ak8bw33fqkdlkdhgqd2-treefmt-with-config-2.6.0.drv
  /nix/store/7j3clwg6n18n7rklr62xsky6qcf1za0d-source.drv
  /nix/store/nlqqqvkia70lb7y6p2nagmz8x3m5l104-xcodegen-2.46.0.drv
  /nix/store/k95fjvf4mm4zskppgdxq2s9fhn4fwfz0-version.patch.drv
  /nix/store/xgw3ssymkarpfxrppi54f01ycyvv1qf0-govulncheck-1.3.0.drv
  /nix/store/zjsfya76gfassvfinasj4yrqnazsfx0b-gopls-0.22.0.drv
  /nix/store/whqzqblwh274nazig230z5x2r4p0fyri-nodejs-22.23.5.drv
  /nix/store/cxg1na0qvlxh4ali0r3z06ipwy24x1f5-nix-shell.drv
these 185 paths will be fetched (599.6 MiB download, 2.6 GiB unpacked):
  /nix/store/gfmbipwgbkkby613z66nzf90zb0zp8vj-ICU-76142.3.1.1
  /nix/store/rb7vbbh042pzsx8nq984mg34irvksqfi-bun-1.3.13
EOF
expect "only the flake's own derivations pass" 0 "9 derivation(s) to build"

cat >"$work/plan" <<'EOF'
these 4 derivations will be built:
  /nix/store/9dfr1i41jk2awm0f1viyr8c2jcmhxgby-go-1.27.4.drv
  /nix/store/mv66l3jmzns99x2s6zh3pjssbzwmpm63-nodejs-slim-22.23.5.drv
  /nix/store/whqzqblwh274nazig230z5x2r4p0fyri-nodejs-22.23.5.drv
  /nix/store/cxg1na0qvlxh4ali0r3z06ipwy24x1f5-nix-shell.drv
these 2 paths will be fetched (1.0 MiB download, 2.0 MiB unpacked):
  /nix/store/rb7vbbh042pzsx8nq984mg34irvksqfi-bun-1.3.13
EOF
expect "a nixpkgs package with no Mac build fails" 1 "go-1.27.4"
expect "the Node build with its tests fails" 1 "nodejs-slim-22.23.5"

cat >"$work/plan" <<'EOF'
this derivation will be built:
  /nix/store/1ar2b0f2s9n661z4mv4zyq3hdws4bnhq-postgresql-17.12.drv
EOF
expect "one derivation, singular wording, fails" 1 "postgresql-17.12"

cat >"$work/plan" <<'EOF'
these 2 paths will be fetched (1.0 MiB download, 2.0 MiB unpacked):
  /nix/store/9dfr1i41jk2awm0f1viyr8c2jcmhxgby-go-1.27.4
  /nix/store/rb7vbbh042pzsx8nq984mg34irvksqfi-bun-1.3.13
EOF
expect "a fetched path with a package name passes" 0 "0 derivation(s) to build"

: >"$work/plan"
expect "an empty plan passes" 0 "0 derivation(s) to build"

echo "error: something that is not a plan" >"$work/plan"
expect "text that is not a plan fails" 1 "cannot read the plan"

if ((failures > 0)); then
	echo "ci_mac_devshell_test: $failures failure(s)"
	exit 1
fi
echo "ci_mac_devshell_test: all passed"
