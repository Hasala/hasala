#!/usr/bin/env bash
set -euo pipefail

while IFS= read -r v; do unset "$v"; done < <(git rev-parse --local-env-vars)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$ROOT/scripts/ci-changes.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0
cases=0

NAMES=(gate swift ios ios_scripts web nixos_vm)
ALL="${NAMES[*]}"

wanted() {
	local n
	for n in "${NAMES[@]}"; do
		case " $1 " in
		*" $n "*) echo "$n=true" ;;
		*) echo "$n=false" ;;
		esac
	done
}

bad() {
	echo "FAIL $1"
	shift
	local f
	for f in "$@"; do sed 's/^/     /' "$f"; done
	failures=$((failures + 1))
}

check() {
	local name="$1" want="$2" want_rc="$3" rc=0
	shift 3
	cases=$((cases + 1))
	"$@" >"$work/out" 2>"$work/err" || rc=$?
	wanted "$want" >"$work/want"
	if [[ "$rc" != "$want_rc" ]]; then
		bad "$name: exit $rc, want $want_rc" "$work/out" "$work/err"
	elif ! cmp -s "$work/out" "$work/want"; then
		bad "$name: selected [$(sed -n 's/=true$//p' "$work/out" | tr '\n' ' ')], want [$want]" "$work/out"
	else
		echo "ok   $name"
	fi
}

sel() {
	local name="$1" want="$2"
	shift 2
	printf '%s\0' "$@" >"$work/paths"
	check "$name" "$want" 0 "$script" "$work/paths"
}

says() {
	if grep -qF -- "$1" "$work/err"; then echo "ok   ...says '$1'"; else
		bad "the message does not say '$1'" "$work/err"
	fi
}

sel "a root Markdown file" "" README.md
sel "the licence texts, NOTICE and CLAUDE.md" "" LICENSES/MIT.txt NOTICE CLAUDE.md AGENTS.md
sel "a Markdown file with a space in its name" "" "READ ME.md"
sel "a decision document" "" docs/decisions/bank-texts.md
sel "a runbook that no check pins" "" docs/runbooks/beta-review.md
sel "the gitleaks allowlist" "gate" .gitleaks.toml

sel "a Go file in server/" "gate nixos_vm" server/internal/api/api.go
sel "server/go.mod" "gate nixos_vm" server/go.mod
sel "the oracle module" "gate nixos_vm" server/oracle/gates/tmpl/corpus_writer_test.go
sel "a gate script" "gate" scripts/check.sh
sel "the selection self-test" "gate" scripts/tests/ci_changes_test.sh
sel "the QA module" "gate nixos_vm" infra/qa/nix/module.nix
sel "the tunnel golden file" "gate nixos_vm" infra/qa/cloudflared/config.golden.yml
sel "the assist worker" "gate" infra/assist/src/index.ts
sel "a Nix file in the assist worker" "gate" infra/assist/shell.nix
sel "a conformance fixture" "gate swift" conformance/op/manifest.json
sel "a Go file under docs/" "gate" docs/tools/main.go
sel "a Nix file under web/" "gate web" web/shell.nix
sel "a Go file under design/" "gate ios" design/tools/gen.go
sel "go.mod under ios/" "gate swift ios ios_scripts" ios/tools/x/go.mod
sel "go.sum under web/" "gate web" web/tools/go.sum
sel "go.work.sum under docs/" "gate" docs/go.work.sum
sel "a file named like go.mod" "" docs/notgo.mod

sel "an app source file" "swift ios ios_scripts" ios/Hasala/App/RootView.swift
sel "a HasalaCore source file" "swift ios ios_scripts" ios/HasalaCore/Sources/HasalaCore/Sync/Pusher.swift
sel "a HasalaCore test" "swift ios ios_scripts" ios/HasalaCore/Tests/CoreSyncTests/PusherTests.swift
sel "the Xcode project" "swift ios ios_scripts" ios/project.yml ios/Hasala.xcodeproj/project.pbxproj
sel "a bundled template" "gate swift ios ios_scripts" ios/HasalaCore/Sources/HasalaCore/Resources/templates/dib.card.v1.json
sel "the template manifest" "gate swift ios ios_scripts" ios/HasalaCore/Sources/HasalaCore/Resources/TemplatesManifest.swift
sel "another bundled resource" "swift ios ios_scripts" ios/HasalaCore/Sources/HasalaCore/Resources/merchant-dictionary.json
sel "a design token" "ios" design/tokens/paper-tokens.json
sel "a design asset" "ios" design/logo/hasala.svg

sel "a website page" "web" web/src/pages/index.astro
sel "a legal page" "web" docs/legal/privacy.md
sel "the Lighthouse configuration" "web" web/lighthouse/lighthouserc.json

sel "flake.nix" "gate ios ios_scripts web nixos_vm" flake.nix
sel "flake.lock" "gate ios ios_scripts web nixos_vm" flake.lock
sel "the CI workflow" "$ALL" .github/workflows/ci.yml
sel "another file in .github/" "$ALL" .github/dependabot.yml
sel "the selection script" "$ALL" scripts/ci-changes.sh
sel "the selection script with inert paths" "$ALL" README.md docs/ci.md scripts/ci-changes.sh
sel "a new top-level directory" "$ALL" tools/gen/main.py
sel "a new root file" "$ALL" Makefile
sel "a root dotfile" "$ALL" .editorconfig
sel ".envrc" "$ALL" .envrc
sel ".gitignore" "$ALL" .gitignore
sel ".gitattributes" "$ALL" .gitattributes
sel "go.work" "$ALL" go.work
sel "a root Go file" "$ALL" main.go
sel "a root file named like Markdown" "$ALL" README.md.bak
sel "a directory named like a Markdown file" "$ALL" notes.md/x.txt

sel "one read path among inert paths" "gate nixos_vm" README.md docs/ci.md LICENSES/MIT.txt server/config.example.toml NOTICE
sel "a file that moved from server/ to docs/" "gate nixos_vm" docs/notes/config.toml server/config.example.toml
sel "a file that moved from ios/scripts/ to docs/" "swift ios ios_scripts" docs/old/archive.sh ios/scripts/archive.sh
sel "a file that moved from docs/legal/ to docs/decisions/" "web" docs/decisions/terms.md docs/legal/terms.md
sel "a runbook renamed away from restore.md" "gate" docs/runbooks/restore.md docs/runbooks/restore-qa.md

sel "a non-ASCII name in server/" "gate nixos_vm" "server/internal/api/café.go"
sel "an Arabic name in docs/" "" "docs/decisions/مصرف.md"
sel "a non-ASCII root Markdown file" "" "حصّالة.md"
sel "bytes that are not UTF-8" "gate nixos_vm" "$(printf 'server/caf\351.go')"
sel "a root Markdown name that is not UTF-8" "" "$(printf 'caf\351.md')"
sel "a file named like an output line" "$ALL" "gate=false"
sel "a root Markdown file named like an output line" "" "gate=false.md"
sel "a space in a legal page name" "web" "docs/legal/terms of use.md"
sel "a quote and a backslash" "gate swift" 'conformance/op/a "b"\c.json'
sel "a name that starts with a dash" "$ALL" "-n"
sel "a newline in a docs/ name that ends like a Go file" "gate" "docs/a
server/x.go"
sel "a newline in a docs/ name" "" "docs/a
server/x.txt"
sel "a newline in a server/ name that ends like root Markdown" "gate nixos_vm" "server/x
README.md"
sel "a newline in a root Markdown name" "" "x
README.md"
sel "a newline in a new top-level directory name" "$ALL" "README.md
server/x"
sel "a name that ends in a newline" "$ALL" "README.md
"

sel "gate: a seed template" "gate swift nixos_vm" server/internal/tmpl/seed/dib.card.v1.json
sel "gate: the restore runbook that module-eval pins" "gate" docs/runbooks/restore.md
sel "gate: a Nix file under infra/" "gate nixos_vm" infra/qa/nix/tests/eval.nix
sel "gate: a golden fixture" "gate swift" conformance/extract/vectors.json
sel "swift: a seed template the bundle must equal" "gate swift nixos_vm" server/internal/tmpl/seed/enbd.alert.v1.json
sel "swift: the lock file that marks the repository root" "swift" private-fixtures.lock
sel "swift: the lock file with inert paths" "gate swift" private-fixtures.lock scripts/private-fixtures-lock.sh CLAUDE.md
sel "ios: the Paper tokens" "ios" design/tokens/paper-tokens.json
sel "ios: a release script" "swift ios ios_scripts" ios/scripts/archive.sh
sel "ios_scripts: a release script test" "swift ios ios_scripts" ios/scripts/tests/run.sh
sel "ios_scripts: the version the tests read" "swift ios ios_scripts" ios/Config/Version.xcconfig
sel "ios_scripts: a source file archive.sh scans" "swift ios ios_scripts" ios/HasalaKit/Sources/HasalaDesign/Theme.swift
sel "ios_scripts: the sample seed" "swift ios ios_scripts" ios/HasalaCore/Sources/HasalaCore/Resources/sample/maya-v1.json
sel "ios_scripts: a tool the tests compile" "swift ios ios_scripts" ios/tools/tokens/generate.swift
sel "web: a legal page" "web" docs/legal/support.md
sel "web: the Astro configuration" "web" web/astro.config.mjs
sel "nixos_vm: the VM test" "gate nixos_vm" infra/qa/nix/tests/vm.nix
sel "nixos_vm: hasalad" "gate nixos_vm" server/cmd/hasalad/main.go
sel "nixos_vm: the database setup" "gate nixos_vm" infra/qa/db/setup.sql

: >"$work/paths"
check "an empty list" "$ALL" 0 "$script" "$work/paths"
says "no changed path"
max="$(sed -n 's/^MAX_PATHS=\([0-9][0-9]*\)$/\1/p' "$script")"
for ((i = 0; i <= max; i++)); do printf 'docs/decisions/%d.md\0' "$i"; done >"$work/paths"
check "more inert paths than the script examines" "$ALL" 0 "$script" "$work/paths"
says "more than $max"
for ((i = 0; i < 300; i++)); do printf 'docs/decisions/%d.md\0' "$i"; done >"$work/paths"
check "300 inert paths" "" 0 "$script" "$work/paths"
check "--all" "$ALL" 0 "$script" --all
check "a file that does not exist" "$ALL" 2 "$script" "$work/missing"
says "cannot read"
check "a directory" "$ALL" 2 "$script" "$work"
check "no argument" "$ALL" 2 "$script"
check "two files" "$ALL" 2 "$script" "$work/paths" "$work/paths"
check "an unknown option" "$ALL" 2 "$script" --none
check "--log with --all" "$ALL" 2 "$script" --log --all
printf 'README.md' >"$work/paths"
check "a last path with no NUL" "$ALL" 2 "$script" "$work/paths"
says "no NUL terminator"
printf 'README.md\0docs/ci.md' >"$work/paths"
check "a list cut off in its last path" "$ALL" 2 "$script" "$work/paths"
printf 'README.md\0\0NOTICE\0' >"$work/paths"
check "an empty path" "$ALL" 2 "$script" "$work/paths"
says "empty path"
printf 'README.md\n' >"$work/paths"
check "a newline-separated list" "$ALL" 2 "$script" "$work/paths"

for broken in "s|^SELECTOR=.*|SELECTOR='('|" "s|^SHARED=.*|SHARED='[z-a]'|" "s|^LEAKS=.*|LEAKS='a{2,1}'|"; do
	sed "$broken" "$script" >"$work/broken.sh"
	chmod +x "$work/broken.sh"
	printf 'README.md\0' >"$work/paths"
	check "a malformed pattern ($broken)" "$ALL" 2 "$work/broken.sh" "$work/paths"
	says "not a valid regular expression"
done

sed 's|^rule web .*|exit 0|' "$script" >"$work/broken.sh"
printf 'README.md\0' >"$work/paths"
check "a script that stops before it prints" "$ALL" 2 "$work/broken.sh" "$work/paths"
sed 's|^rule web .*|false|' "$script" >"$work/broken.sh"
check "a script whose command fails" "$ALL" 1 "$work/broken.sh" "$work/paths"

printf '%s\0' "::set-output name=gate::false" "::error::x" README.md >"$work/paths"
check "--log keeps the outputs on stdout" "$ALL" 0 "$script" --log "$work/paths"
cases=$((cases + 1))
token="$(sed -n 's/^::stop-commands::\(.*\)$/\1/p' "$work/err")"
if [[ "$token" =~ ^[0-9a-f]{32}$ ]] && [[ "$(cat "$work/err")" == "::group::3 changed path(s)
::stop-commands::$token
::set-output name=gate::false
::error::x
README.md
::$token::
::endgroup::" ]]; then
	echo "ok   ...and prints the paths between ::stop-commands:: and its token"
else
	bad "--log does not guard the path listing" "$work/err"
fi
"$script" --log "$work/paths" >/dev/null 2>"$work/err2"
cases=$((cases + 1))
if [[ "$(sed -n 2p "$work/err")" != "$(sed -n 2p "$work/err2")" ]]; then echo "ok   ...with a new token in each run"; else
	bad "--log used the same token twice" "$work/err" "$work/err2"
fi
printf 'README.md\0' >"$work/paths"
check "--log on an inert list" "" 0 "$script" --log "$work/paths"
: >"$work/paths"
check "--log on an empty list" "$ALL" 0 "$script" --log "$work/paths"
says "::group::0 changed path(s)"

cases=$((cases + 1))
links="$(git -C "$ROOT" ls-files -s | awk '$1 == "120000" || $1 == "160000"' | cut -f2-)"
if [[ "$links" == AGENTS.md ]]; then echo "ok   AGENTS.md is the only symbolic link or submodule in the tree"; else
	echo "FAIL the tree has a symbolic link or submodule that the path rules do not know:"
	sed 's/^/     /' <<<"$links"
	echo "     The rules see only the path of a link, not its target: a job that reads through the link is not started when the target changes."
	echo "     Examine the rules in scripts/ci-changes.sh for the link and its target, then add the link to this check."
	failures=$((failures + 1))
fi

if ((failures)); then
	echo "$failures of $cases CI path selection case(s) failed"
	exit 1
fi
echo "$cases CI path selection cases passed"
