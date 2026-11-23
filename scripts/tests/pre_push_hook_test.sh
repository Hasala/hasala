#!/usr/bin/env bash
set -euo pipefail

while IFS= read -r v; do unset "$v"; done < <(git rev-parse --local-env-vars)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0

for tool in go gofmt nixfmt shellcheck gitleaks; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		echo "FAIL $tool is not on PATH, so the pre-push hook self-test cannot run; run it in the devShell (direnv exec . scripts/tests/pre_push_hook_test.sh)"
		exit 1
	fi
done

: >"$work/gitconfig"
export GIT_CONFIG_GLOBAL="$work/gitconfig"
export GIT_CONFIG_SYSTEM=/dev/null
unset GITHUB_ACTIONS

FULL_PATH="$PATH"
export FULL_PATH
export STUB_LOG="$work/log"

mkdir -p "$work/bin" "$work/bin-ok"
cat >"$work/bin/direnv" <<'STUB'
#!/bin/sh
printf 'direnv refused\n' >>"$STUB_LOG"
echo "direnv: error .envrc is blocked" >&2
exit 1
STUB
cat >"$work/bin/nix" <<'STUB'
#!/bin/sh
printf 'nix refused\n' >>"$STUB_LOG"
echo "error: this stub has no devShell" >&2
exit 1
STUB
cat >"$work/bin-ok/direnv" <<'STUB'
#!/bin/sh
printf 'direnv %s %s\n' "$1" "$2" >>"$STUB_LOG"
shift 2
PATH="$FULL_PATH" exec "$@"
STUB
cp "$work/bin/nix" "$work/bin-ok/nix"
mkdir -p "$work/bin-nix" "$work/bin-js"
cp "$work/bin/direnv" "$work/bin-nix/direnv"
cat >"$work/bin-nix/nix" <<'STUB'
#!/bin/sh
printf 'nix %s\n' "$3" >>"$STUB_LOG"
shift 5
PATH="$FULL_PATH" exec "$@"
STUB
for tool in tsgo oxlint oxfmt; do
	cat >"$work/bin-js/$tool" <<STUB
#!/bin/sh
printf '$tool %s\n' "\$*" >>"\$STUB_LOG"
if [ -n "\${STUB_FAILS_$tool:-}" ]; then
	echo "$tool: the stub found a problem"
	exit 1
fi
exit 0
STUB
done
chmod +x "$work/bin/direnv" "$work/bin/nix" "$work/bin-ok/direnv" "$work/bin-ok/nix" "$work/bin-nix/direnv" "$work/bin-nix/nix" "$work/bin-js/tsgo" "$work/bin-js/oxlint" "$work/bin-js/oxfmt"

SHADOWS=0
path_without() {
	local tool="$1" dir shadow out=""
	local IFS=:
	for dir in $FULL_PATH; do
		if [[ -x "$dir/$tool" ]]; then
			SHADOWS=$((SHADOWS + 1))
			shadow="$work/shadow-$tool-$SHADOWS"
			mkdir "$shadow"
			find "$dir" -mindepth 1 -maxdepth 1 ! -name "$tool" -exec sh -c 'ln -s "$@" "$0"' "$shadow" {} +
			dir="$shadow"
		fi
		out+="${out:+:}$dir"
	done
	printf '%s\n' "$out"
}

t() { git -C "$work/t" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }

commit() {
	t add -A
	t commit -q -m "$1"
}

stub() {
	mkdir -p "$work/t/$(dirname "$1")"
	printf '#!/bin/sh\nprintf "%%s\\n" "%s" >>"$STUB_LOG"\nsleep "${STUB_SLEEP:-0}"\nexit 0\n' "$1" >"$work/t/$1"
	chmod +x "$work/t/$1"
}

fresh() {
	local budget="${1:-120}"
	rm -rf "$work/t" "$work/wt" "$work/old" "$work/remote.git"
	: >"$STUB_LOG"
	git init -q --bare -b main "$work/remote.git"
	mkdir -p "$work/t/.githooks" "$work/t/scripts" "$work/t/server/a"
	sed "s/^BUDGET_SECONDS=.*/BUDGET_SECONDS=$budget/" "$ROOT/.githooks/pre-push" >"$work/t/.githooks/pre-push"
	cp "$ROOT/scripts/pre-push.sh" "$ROOT/scripts/install-hooks.sh" "$work/t/scripts/"
	chmod +x "$work/t/.githooks/pre-push" "$work/t/scripts/pre-push.sh" "$work/t/scripts/install-hooks.sh"
	stub scripts/check.sh
	stub scripts/check-comments.sh
	stub ios/scripts/check-imports.sh
	stub ios/scripts/check-forbidden.sh
	printf '[extend]\nuseDefault = true\n' >"$work/t/.gitleaks.toml"
	printf 'module example.invalid/t\n\ngo 1.24\n' >"$work/t/server/go.mod"
	printf 'package a\n\nfunc A() int { return 1 }\n' >"$work/t/server/a/a.go"
	git -C "$work/t" init -q -b main
	commit first
	t remote add origin "$work/remote.git"
	t push -q origin main
	(cd "$work/t" && scripts/install-hooks.sh) >"$work/install" 2>&1
	: >"$STUB_LOG"
}

ok() { echo "ok   $1"; }

bad() {
	echo "FAIL $1"
	if [[ -f "$work/out" ]]; then
		sed 's/^/     /' "$work/out"
	fi
	failures=$((failures + 1))
}

push() {
	local name="$1" want="$2" dir="$3" rc=0
	shift 3
	(cd "$dir" && PATH="${PUSH_PATH:-$work/bin:$FULL_PATH}" git push "$@") >"$work/out" 2>&1 || rc=$?
	if [[ "$want" == refused && "$rc" -ne 0 ]] || [[ "$want" == accepted && "$rc" -eq 0 ]]; then
		ok "$name ($want, exit $rc)"
	else
		bad "$name: exit $rc, want $want"
	fi
}

says() {
	if grep -qF -- "$1" "$work/out"; then ok "...says '$1'"; else bad "the output does not say '$1'"; fi
}

lacks() {
	if grep -qF -- "$1" "$work/out"; then bad "the output says '$1'"; else ok "...does not say '$1'"; fi
}

on_remote() {
	if git -C "$work/remote.git" rev-parse -q --verify "refs/heads/$1" >/dev/null; then ok "...and the remote has $1"; else bad "the remote does not have $1"; fi
}

not_on_remote() {
	if git -C "$work/remote.git" rev-parse -q --verify "refs/heads/$1" >/dev/null; then bad "the remote has $1"; else ok "...and the remote does not have $1"; fi
}

no_checks_ran() {
	if [[ -s "$STUB_LOG" ]]; then
		bad "checks ran: $(tr '\n' ' ' <"$STUB_LOG")"
	else
		ok "...and no check ran"
	fi
}

if grep -qx 'BUDGET_SECONDS=9' "$ROOT/.githooks/pre-push"; then ok "the hook's budget is 9 seconds"; else
	echo "FAIL .githooks/pre-push does not set BUDGET_SECONDS=9"
	failures=$((failures + 1))
fi
if [[ -x "$ROOT/.githooks/pre-push" ]]; then ok "the hook is executable"; else
	echo "FAIL .githooks/pre-push is not executable, so git does not run it"
	failures=$((failures + 1))
fi

fresh
cp "$work/install" "$work/out"
if [[ "$(t config --get core.hooksPath)" == .githooks ]]; then ok "the installer sets core.hooksPath to .githooks"; else bad "the installer did not set core.hooksPath"; fi
says "core.hooksPath=.githooks"
(cd "$work/t/server" && ../scripts/install-hooks.sh) >"$work/out" 2>&1
if [[ ! -s "$work/out" ]]; then ok "a second install prints nothing"; else bad "a second install printed something"; fi
t config core.hooksPath /somewhere/else
(cd "$work/t" && scripts/install-hooks.sh) >"$work/out" 2>&1
if [[ "$(t config --get core.hooksPath)" == /somewhere/else ]]; then ok "the installer keeps a core.hooksPath that is already set"; else bad "the installer replaced a core.hooksPath that was set"; fi
says "git does not run .githooks/pre-push"
t config --unset core.hooksPath
(cd "$work/t" && GITHUB_ACTIONS=true scripts/install-hooks.sh) >"$work/out" 2>&1
if [[ -z "$(t config --get core.hooksPath || true)" && ! -s "$work/out" ]]; then ok "the installer does nothing in CI"; else bad "the installer did something in CI"; fi
mkdir "$work/plain"
install_rc=0
(cd "$work/plain" && GIT_CEILING_DIRECTORIES="$work" "$work/t/scripts/install-hooks.sh") >"$work/out" 2>&1 || install_rc=$?
if [[ "$install_rc" -eq 0 && ! -s "$work/out" ]]; then ok "the installer does nothing outside a checkout"; else bad "the installer failed or printed something outside a checkout (exit $install_rc)"; fi

fresh
t checkout -q -b clean
printf 'package a\n\nfunc A() int { return 2 }\n' >"$work/t/server/a/a.go"
printf '#!/bin/sh\necho hello\n' >"$work/t/scripts/hello.sh"
printf '{ a = 1; }\n' >"$work/t/x.nix"
commit clean
push "a clean push" accepted "$work/t" origin clean
says "PASS     the working tree is the pushed commit"
says "PASS     real-mail fence"
says "PASS     gitleaks (1 new commit(s))"
says "PASS     gofmt"
says "PASS     go vet server/"
says "PASS     nixfmt --check"
says "PASS     shellcheck"
says "of the 120s budget"
lacks "the push is refused"
on_remote clean

printf '{ a = 2; }\n' >"$work/t/x.nix"
commit second
push "a second push of the same branch" accepted "$work/t" origin clean
says "1 changed path(s)"
says "SKIP     gofmt, go vet (no Go changes)"
says "PASS     nixfmt --check"

fresh
t checkout -q -b unformatted-go
printf 'package a\n\nfunc A() int {\nreturn 1 }\n' >"$work/t/server/a/a.go"
commit unformatted
push "a push with a Go formatting error" refused "$work/t" origin unformatted-go
says "FAIL     gofmt"
says "not gofmt-formatted"
says "server/a/a.go"
says "the push is refused"
not_on_remote unformatted-go

fresh
t checkout -q -b unformatted-nix
printf '{a=1;}\n' >"$work/t/x.nix"
commit unformatted
push "a push with a Nix formatting error" refused "$work/t" origin unformatted-nix
says "FAIL     nixfmt --check"
says "not nixfmt-formatted"
not_on_remote unformatted-nix

fresh
t checkout -q -b lint-shell
printf '#!/bin/sh\nunused=1\n' >"$work/t/scripts/lint.sh"
commit lint
push "a push with a shell lint error" refused "$work/t" origin lint-shell
says "FAIL     shellcheck"
says "SC2034"
not_on_remote lint-shell

fresh
t checkout -q -b lint-go
printf 'package a\n\nfunc A() int {\n\tx := 1\n\tx = x\n\treturn x\n}\n' >"$work/t/server/a/a.go"
commit lint
push "a push with a Go lint error" refused "$work/t" origin lint-go
says "FAIL     go vet server/"
says "self-assignment"
not_on_remote lint-go

fresh
t checkout -q -b type-error
printf 'package a\n\nfunc A() int { return "one" }\n' >"$work/t/server/a/a.go"
commit type
push "a push with a type error" refused "$work/t" origin type-error
says "FAIL     go vet server/"
says "cannot use"
not_on_remote type-error

fresh
t checkout -q -b secret
printf 'token = "ghp_%s"\n' "1234567890abcdefghijklmnopqrstuvwxAB" >"$work/t/notes.txt"
commit secret
push "a push with a secret" refused "$work/t" origin secret
says "FAIL     gitleaks"
not_on_remote secret

fresh
t checkout -q -b doomed
printf '{ a = 1; }\n' >"$work/t/x.nix"
commit doomed
push "the push that makes a branch" accepted "$work/t" origin doomed
: >"$STUB_LOG"
push "a branch deletion" accepted "$work/t" origin :doomed
says "a deletion, nothing to check"
lacks "PASS"
no_checks_ran
not_on_remote doomed

t tag v1
push "a tag push" accepted "$work/t" origin v1
says "a tag, nothing to check"
lacks "PASS"
no_checks_ran

fresh
t checkout -q -b dirty
printf '{ a = 1; }\n' >"$work/t/x.nix"
commit dirty
printf '{ a = 3; }\n' >"$work/t/x.nix"
push "a push of a commit that the working tree does not hold" refused "$work/t" origin dirty
says "FAIL     the working tree is the pushed commit"
says "x.nix"
not_on_remote dirty

fresh
t checkout -q -b needs-shellcheck
printf '#!/bin/sh\necho hello\n' >"$work/t/scripts/hello.sh"
commit hello
reduced="$(path_without shellcheck)"
if PATH="$reduced" command -v shellcheck >/dev/null 2>&1 || ! PATH="$reduced" command -v git >/dev/null 2>&1; then
	echo "FAIL the test could not make a PATH that has git and no shellcheck, so the missing-tool cases cannot run"
	failures=$((failures + 1))
else
	PUSH_PATH="$work/bin:$reduced" push "a push when a tool is missing and no devShell starts" refused "$work/t" origin needs-shellcheck
	says "MISSING  shellcheck (shellcheck is not on PATH)"
	says "could not run, and that is not a pass"
	says "the devShell did not start: direnv:"
	says "the devShell did not start: nix:"
	lacks "PASS     shellcheck"
	not_on_remote needs-shellcheck

	: >"$STUB_LOG"
	PUSH_PATH="$work/bin-ok:$reduced" push "a push outside the devShell" accepted "$work/t" origin needs-shellcheck
	says "PASS     shellcheck"
	on_remote needs-shellcheck
	if grep -qxF "direnv exec $work/t" "$STUB_LOG"; then ok "...and it ran through direnv exec"; else bad "direnv exec did not run: $(tr '\n' ' ' <"$STUB_LOG")"; fi
	lacks "nix develop"

	printf '#!/bin/sh\necho again\n' >"$work/t/scripts/hello.sh"
	commit again
	: >"$STUB_LOG"
	PUSH_PATH="$work/bin-nix:$reduced" push "a push outside the devShell when direnv refuses" accepted "$work/t" origin needs-shellcheck
	says "PASS     shellcheck"
	says "the tools came through nix develop"
	if grep -qxF "nix develop" "$STUB_LOG"; then ok "...and it ran through nix develop"; else bad "nix develop did not run: $(tr '\n' ' ' <"$STUB_LOG")"; fi
fi

js_tree() {
	fresh
	mkdir -p "$work/t/app/src"
	printf '{}\n' >"$work/t/app/tsconfig.json"
	printf 'node_modules/\n' >"$work/t/.gitignore"
	printf '{}\n' >"$work/t/.oxlintrc.json"
	printf '{}\n' >"$work/t/.oxfmtrc.json"
	commit "a TypeScript project"
	t push -q --no-verify origin main
	t checkout -q -b "$1"
	printf 'export const n: number = 1;\n' >"$work/t/app/src/n.ts"
	commit "$1"
	: >"$STUB_LOG"
}

js_tree ts-clean
mkdir "$work/t/app/node_modules"
PUSH_PATH="$work/bin-js:$work/bin:$FULL_PATH" push "a clean TypeScript push" accepted "$work/t" origin ts-clean
says "PASS     oxfmt --check"
says "PASS     oxlint"
says "PASS     typecheck app/ (tsgo)"
for want in "oxfmt --check --threads=1 app/src/n.ts" "oxlint --threads=1 app/src/n.ts" "tsgo --noEmit --pretty false --checkers 2"; do
	if grep -qxF "$want" "$STUB_LOG"; then ok "...and it ran $want"; else bad "it did not run $want: $(tr '\n' ' ' <"$STUB_LOG")"; fi
done

for tool in oxfmt oxlint tsgo; do
	case "$tool" in
	oxfmt) label="oxfmt --check" ;;
	oxlint) label="oxlint" ;;
	tsgo) label="typecheck app/ (tsgo)" ;;
	esac
	js_tree "ts-$tool"
	mkdir "$work/t/app/node_modules"
	export "STUB_FAILS_$tool=1"
	PUSH_PATH="$work/bin-js:$work/bin:$FULL_PATH" push "a TypeScript push that $tool refuses" refused "$work/t" origin "ts-$tool"
	unset "STUB_FAILS_$tool"
	says "FAIL     $label"
	says "$tool: the stub found a problem"
	not_on_remote "ts-$tool"
done

js_tree ts-no-modules
PUSH_PATH="$work/bin-js:$work/bin:$FULL_PATH" push "a TypeScript push with no node_modules" refused "$work/t" origin ts-no-modules
says "MISSING  typecheck app/ (app/node_modules is missing; run: (cd app && bun install --frozen-lockfile))"
says "could not run, and that is not a pass"
not_on_remote ts-no-modules

js_tree ts-no-linter
mkdir "$work/t/app/node_modules"
no_ox="$(path_without oxlint)"
no_ox="$(FULL_PATH="$no_ox" path_without oxfmt)"
PUSH_PATH="$work/bin:$no_ox" push "a TypeScript push when the configured linter is not installed" refused "$work/t" origin ts-no-linter
says "MISSING  oxlint (oxlint is not on PATH)"
says "MISSING  oxfmt --check (oxfmt is not on PATH)"
not_on_remote ts-no-linter

fresh
mkdir -p "$work/t/app/src" "$work/t/app/node_modules/.bin"
printf '{}\n' >"$work/t/app/tsconfig.json"
printf 'node_modules/\n' >"$work/t/.gitignore"
printf '#!/bin/sh\nprintf "tsc %%s\\n" "$*" >>"$STUB_LOG"\nexit 0\n' >"$work/t/app/node_modules/.bin/tsc"
chmod +x "$work/t/app/node_modules/.bin/tsc"
t checkout -q -b ts-unconfigured
printf 'export const n: number = 1;\n' >"$work/t/app/src/n.ts"
commit unconfigured
no_tsgo="$(FULL_PATH="$no_ox" path_without tsgo)"
PUSH_PATH="$work/bin:$no_tsgo" push "a TypeScript push in a tree with no linter set up" accepted "$work/t" origin ts-unconfigured
says "NOT RUN  oxlint (this tree has no .oxlintrc.json"
says "NOT RUN  oxfmt (this tree has no .oxfmtrc.json"
says "PASS     typecheck app/ (tsc; tsgo is not on PATH)"

printf 'export const loose = 1;\n' >"$work/t/scripts/loose.ts"
mkdir -p "$work/t/tools/x"
printf 'package x\n' >"$work/t/tools/x/x.go"
commit "files that no project covers"
PUSH_PATH="$work/bin:$no_tsgo" push "a push with Go outside the known modules" refused "$work/t" origin ts-unconfigured
says "NOT RUN  typecheck of scripts/loose.ts (no tsconfig.json covers it"
says "MISSING  go vet outside server/"

fresh 1
t checkout -q -b slow
printf '{ a = 1; }\n' >"$work/t/x.nix"
commit slow
STUB_SLEEP=2 push "a push that takes longer than the budget" refused "$work/t" origin slow
says "over its 1s budget"
says "every check passed"
says "the push is refused"
not_on_remote slow

fresh
t worktree add -q -b side "$work/wt"
printf 'package a\n\nfunc A() int {\nreturn 1 }\n' >"$work/wt/server/a/a.go"
git -C "$work/wt" add -A
git -C "$work/wt" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -q -m unformatted
push "a push from a second worktree" refused "$work/wt" origin side
says "FAIL     gofmt"
not_on_remote side

t worktree add -q -b old "$work/old"
git -C "$work/old" rm -rq .githooks
git -C "$work/old" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -q -m "no hooks here"
: >"$STUB_LOG"
push "a push from a worktree whose branch has no .githooks" accepted "$work/old" origin old
lacks "pre-push:"
no_checks_ran
on_remote old

fresh
mkdir "$work/cgroup"
printf '%d\n' "$((8192 * 1048576))" >"$work/cgroup/memory.max"
printf '%d\n' "$((7000 * 1048576))" >"$work/cgroup/memory.current"
printf 'anon %d\nactive_file %d\ninactive_file %d\n' "$((6000 * 1048576))" "$((300 * 1048576))" "$((200 * 1048576))" >"$work/cgroup/memory.stat"
t checkout -q -b low-memory
printf 'package a\n\nfunc A() int { return 3 }\n' >"$work/t/server/a/a.go"
printf '#!/bin/sh\necho hello\n' >"$work/t/scripts/hello.sh"
commit low
export HASALA_PRE_PUSH_CGROUP="$work/cgroup"
push "a push when the memory group is nearly full" accepted "$work/t" origin low-memory
says "has 1692 MiB left of 8192 MiB, so the checks ran one at a time"
says "PASS     go vet server/"
says "PASS     shellcheck"
printf '%d\n' "$((3000 * 1048576))" >"$work/cgroup/memory.current"
printf '{ a = 1; }\n' >"$work/t/x.nix"
commit roomy
push "a push when the memory group has room" accepted "$work/t" origin low-memory
lacks "one at a time"
unset HASALA_PRE_PUSH_CGROUP

fresh
git init -q "$work/outer"
git -C "$work/outer" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -q --allow-empty -m outer
outer_state() {
	git -C "$work/outer" for-each-ref
	git -C "$work/outer" status --porcelain
	git -C "$work/outer" config --list --local
	ls -A "$work/outer"
}
t checkout -q -b env
printf 'package a\n\nfunc A() int {\nreturn 1 }\n' >"$work/t/server/a/a.go"
commit unformatted
before="$(outer_state)"
rc=0
(cd "$work/t" && printf 'refs/heads/env %s refs/heads/env %s\n' "$(t rev-parse HEAD)" 0000000000000000000000000000000000000000 |
	PATH="$work/bin:$FULL_PATH" GIT_DIR="$work/outer/.git" GIT_WORK_TREE="$work/outer" GIT_INDEX_FILE="$work/outer/.git/index" \
		.githooks/pre-push origin "$work/remote.git") >"$work/out" 2>&1 || rc=$?
if [[ "$rc" -ne 0 ]]; then ok "the hook with another repository's git variables exported judges its own checkout (exit $rc)"; else bad "the hook passed an unformatted file with another repository's git variables exported"; fi
says "FAIL     gofmt"
if [[ "$before" == "$(outer_state)" ]]; then ok "...and leaves that repository alone"; else bad "the hook changed the repository whose git variables were exported"; fi

if ((failures)); then
	echo "$failures pre-push hook case(s) failed"
	exit 1
fi
