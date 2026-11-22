#!/usr/bin/env bash
set -euo pipefail

usage() {
	cat <<'EOF'
usage: scripts/pre-push.sh [--all]
       scripts/pre-push.sh --hook <budget seconds> [<remote> [<url>]]   (.githooks/pre-push; git's ref lines on stdin)

Format, lint and typecheck for what changed.

With no option: the working tree against the merge base of HEAD and
origin/main, with the slow self-tests that the hook leaves to CI.
--all: every file.
--hook: the commits that the push adds, in parallel, within the budget.

A tool that is not on PATH comes from the devShell (direnv exec, then nix
develop). A check that still cannot run fails.

At most JOBS checks run at the same time, and the checks that run together
need at most MEM_CAP_MB by their measured peaks. When the memory group of
this process has less than MEM_LOW_MB left, the checks run one at a time.
EOF
}

JOBS=8
MEM_CAP_MB=1280
MEM_LOW_MB=2048
VET_JOBS=4

STARTED=""
ENTERED=""
VIA=""
if [[ "${1:-}" == --resume ]]; then
	STARTED="$2"
	ENTERED="$3"
	VIA="$4"
	shift 4
	exec 2>&3 3>&-
fi
PASS_ARGS=("$@")

ALL=""
HOOK=""
BUDGET=""
REMOTE="origin"
case "${1:-}" in
"") ;;
--all) ALL=1 ;;
--hook)
	HOOK=1
	BUDGET="${2:-}"
	REMOTE="${3:-origin}"
	if [[ ! "$BUDGET" =~ ^[0-9]+$ ]]; then
		usage >&2
		exit 2
	fi
	;;
-h | --help)
	usage
	exit 0
	;;
*)
	usage >&2
	exit 2
	;;
esac

now_us() {
	local t
	if [[ -n "${EPOCHREALTIME:-}" ]]; then
		t="$EPOCHREALTIME"
		printf '%s\n' "${t/[.,]/}"
	elif command -v perl >/dev/null 2>&1; then
		perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000000'
	else
		printf '%s000000\n' "$(date +%s)"
	fi
}

seconds() { printf '%d.%02d' "$(($1 / 1000000))" "$((($1 % 1000000) / 10000))"; }

T0="${STARTED:-$(now_us)}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

while IFS= read -r v; do unset "$v"; done < <(git rev-parse --local-env-vars)

if [[ -n "$ENTERED" ]]; then
	: >"$ENTERED"
fi

LOG="$(mktemp -d "${TMPDIR:-/tmp}/hasala-pre-push.XXXXXX")"
trap 'rm -rf "$LOG"' EXIT

have() { command -v "$1" >/dev/null 2>&1; }

EMPTY_TREE="$(git hash-object -t tree /dev/null)"
TIPS=()
BASES=()
NOTES=()
GL=()
REFS=""

if [[ -n "$HOOK" ]]; then
	REFS="$(cat)"
	MAIN="$(git rev-parse -q --verify "refs/remotes/$REMOTE/main^{commit}" || git rev-parse -q --verify "refs/remotes/origin/main^{commit}" || true)"
	GL_NOT=()
	while read -r lref lsha rref rsha; do
		[[ -n "$lref" ]] || continue
		if [[ "$lsha" =~ ^0+$ ]]; then
			NOTES+=("$rref: a deletion, nothing to check")
			continue
		fi
		if [[ "$lref" == refs/tags/* || "$rref" == refs/tags/* ]]; then
			NOTES+=("$rref: a tag, nothing to check")
			continue
		fi
		if ! git rev-parse -q --verify "$lsha^{commit}" >/dev/null; then
			NOTES+=("$rref: not a commit, nothing to check")
			continue
		fi
		base=""
		if [[ ! "$rsha" =~ ^0+$ ]] && git merge-base --is-ancestor "$rsha" "$lsha" 2>/dev/null; then
			base="$rsha"
		elif [[ -n "$MAIN" ]]; then
			base="$(git merge-base "$lsha" "$MAIN" || true)"
		fi
		TIPS+=("$lsha")
		BASES+=("${base:-$EMPTY_TREE}")
		if [[ -n "$base" ]]; then
			GL_NOT+=("$base")
		fi
	done <<<"$REFS"
	if [[ -n "$MAIN" ]]; then
		GL_NOT+=("$MAIN")
	fi
	for note in ${NOTES[@]+"${NOTES[@]}"}; do
		echo "pre-push: $note"
	done
	if ((${#TIPS[@]} == 0)); then
		echo "pre-push: no branch commits in this push, nothing to check ($(seconds $(($(now_us) - T0)))s)"
		exit 0
	fi
	GL=("${TIPS[@]}")
	if ((${#GL_NOT[@]})); then
		GL+=(--not "${GL_NOT[@]}")
	fi
	PATHS="$(
		for ((i = 0; i < ${#TIPS[@]}; i++)); do
			git diff --name-only --no-renames "${BASES[i]}" "${TIPS[i]}"
		done | LC_ALL=C sort -u
	)"
	WHAT="${#TIPS[@]} ref(s)"
else
	BASE="$(git merge-base HEAD origin/main 2>/dev/null || true)"
	if [[ -z "$BASE" ]]; then
		echo "pre-push: no origin/main to compare with; running every check" >&2
		ALL=1
		BASE="$EMPTY_TREE"
		GL=(HEAD)
	else
		GL=("$BASE..HEAD")
	fi
	PATHS="$(
		{
			git diff --name-only --no-renames "$BASE"
			git ls-files --others --exclude-standard
		} | LC_ALL=C sort -u
	)"
	WHAT="base ${BASE:0:12}"
fi

changed() {
	[[ -n "$ALL" ]] && return 0
	grep -Eq "$1" <<<"$PATHS"
}

all_files() {
	local f
	if [[ -n "$ALL" ]]; then git ls-files; else printf '%s\n' "$PATHS"; fi | { grep -E "$1" || true; } | while IFS= read -r f; do
		if [[ -f "$f" ]]; then
			printf '%s\n' "$f"
		fi
	done
}

N=0
KIND=()
NAME=()
NOTE=()
TOOLS=()
WEIGHT=()
MEM=()
CMD=()
EARLY=()

plan() {
	KIND[N]="$1"
	NAME[N]="$2"
	NOTE[N]="$3"
	TOOLS[N]="$4"
	WEIGHT[N]="$5"
	MEM[N]=24
	EARLY[N]=0
	shift 5
	CMD[N]="$*"
	N=$((N + 1))
}

early() { EARLY[N - 1]=1; }
needs_mb() { MEM[N - 1]="$1"; }

check() {
	local name="$1" tools="$2" weight="$3"
	shift 3
	plan run "$name" "" "$tools" "$weight" "$@"
}
skip() { plan skip "$1" "$2" "" 0; }
left() { plan left "$1" "$2" "" 0; }
miss() { plan miss "$1" "$2" "" 0; }

slow() {
	local name="$1" took="$2" job="$3" tools="$4" weight="$5"
	shift 5
	if [[ -n "$HOOK" ]]; then
		left "$name" "about $took s, too slow for the hook; CI job $job runs it, and so does scripts/pre-push.sh"
	else
		check "$name" "$tools" "$weight" "$@"
	fi
}

mac_only() {
	local name="$1" job="$2" tools="$3"
	shift 3
	if [[ "$(uname -s)" == Darwin ]]; then
		check "$name" "$tools" 1 "$@"
	else
		left "$name" "macOS only; CI job $job runs it"
	fi
}

tree_check() {
	local i bad rc=0
	for ((i = 0; i < ${#TIPS[@]}; i++)); do
		bad="$(LC_ALL=C comm -12 \
			<(git diff --name-only --no-renames "${TIPS[i]}" | LC_ALL=C sort) \
			<(git diff --name-only --no-renames "${BASES[i]}" "${TIPS[i]}" | LC_ALL=C sort))"
		if [[ -n "$bad" ]]; then
			echo "the checks read the working tree, and it differs from the pushed commit ${TIPS[i]:0:12} in:"
			printf '%s\n' "$bad" | sed 's/^/  /'
			echo "commit or restore these files, or push from a checkout of that commit"
			rc=1
		fi
	done
	return "$rc"
}

gitleaks_check() {
	local out rc=0 patched
	out="$(gitleaks git --config .gitleaks.toml --log-opts="${GL[*]}" --redact --no-banner --no-color . 2>&1)" || rc=$?
	printf '%s\n' "$out"
	if [[ "$rc" -ne 0 ]]; then
		return "$rc"
	fi
	if grep -q ' ERR ' <<<"$out"; then
		echo "gitleaks reported an error and scanned nothing it can vouch for"
		return 1
	fi
	patched="$(git log --no-merges --format= --name-only "${GL[@]}" | grep -c . || true)"
	if [[ "$patched" -gt 0 ]] && grep -q ' 0 commits scanned' <<<"$out"; then
		echo "gitleaks scanned no commit, but the new commits change $patched path(s)"
		return 1
	fi
}

gofmt_check() {
	local out
	out="$(printf '%s\n' "$GOFILES" | xargs gofmt -l)" || return 1
	if [[ -n "$out" ]]; then
		echo "not gofmt-formatted (run nix fmt, or gofmt -w):"
		printf '%s\n' "$out" | sed 's/^/  /'
		return 1
	fi
}

vet_module() {
	cd "$ROOT/$1" || return 1
	go vet -p "$VET_JOBS" ./...
}

nixfmt_check() {
	if ! printf '%s\n' "$NIXFILES" | xargs nixfmt --check; then
		echo "not nixfmt-formatted (run nix fmt)"
		return 1
	fi
}

shellcheck_check() {
	printf '%s\n' "$SHFILES" | xargs -P 3 -n 4 shellcheck -S warning
}

templates_check() {
	local bundled="ios/HasalaCore/Sources/HasalaCore/Resources/templates" seed="server/internal/tmpl/seed" f
	if [[ "$(cd "$bundled" && ls -1 ./*.json)" != "$(cd "$seed" && ls -1 ./*.json)" ]]; then
		echo "the bundled template set differs from $seed; run swift ios/tools/templates/sync.swift"
		return 1
	fi
	for f in "$seed"/*.json; do
		if ! cmp -s "$f" "$bundled/${f##*/}"; then
			echo "${f##*/} differs from the server seed; run swift ios/tools/templates/sync.swift"
			return 1
		fi
	done
}

oxfmt_check() {
	if ! printf '%s\n' "$FMTFILES" | xargs oxfmt --check --threads=1; then
		echo "not oxfmt-formatted (run oxfmt on these files)"
		return 1
	fi
}

oxlint_check() {
	printf '%s\n' "$JSFILES" | xargs oxlint --threads=1
}

astro_types_stale() {
	local stamp=".astro/pre-push.stamp" f
	if [[ ! -f "$stamp" || ! -f .astro/types.d.ts ]]; then
		return 0
	fi
	for f in astro.config.* src/content.config.* package.json bun.lock tsconfig.json; do
		if [[ -e "$f" && "$f" -nt "$stamp" ]]; then
			return 0
		fi
	done
	return 1
}

typecheck() {
	local out
	cd "$ROOT/$1" || return 1
	if ls astro.config.* >/dev/null 2>&1 && astro_types_stale; then
		if ! out="$(node_modules/.bin/astro sync 2>&1)"; then
			printf '%s\n' "$out"
			echo "astro sync failed, so the generated types are missing"
			return 1
		fi
		touch .astro/pre-push.stamp
	fi
	if have tsgo; then
		tsgo --noEmit --pretty false --checkers 2
	elif [[ -x node_modules/.bin/tsc ]]; then
		node_modules/.bin/tsc --noEmit --pretty false
	else
		echo "no tsgo on PATH and no node_modules/.bin/tsc in $1"
		return 1
	fi
}

astro_check() {
	cd "$ROOT/web" || return 1
	bun run check
}

ts_projects() {
	local f d
	if [[ -n "$ALL" ]]; then
		git ls-files -- '*/tsconfig.json' | sed 's|/tsconfig\.json$||'
		return 0
	fi
	printf '%s\n' "$PATHS" | { grep -E '(\.(ts|tsx|mts|cts|js|jsx|mjs|cjs)|(^|/)(tsconfig\.json|package\.json|bun\.lock))$' || true; } | while IFS= read -r f; do
		d="$(dirname "$f")"
		while :; do
			if [[ -f "$d/tsconfig.json" ]]; then
				printf '%s\n' "$d"
				break
			fi
			if [[ "$d" == . || "$d" == / ]]; then
				if [[ "$f" =~ \.(ts|tsx|mts|cts)$ && -f "$f" ]]; then
					printf '!%s\n' "$f"
				fi
				break
			fi
			d="$(dirname "$d")"
		done
	done | LC_ALL=C sort -u
}

tracked() { [[ -n "$(git ls-files -- "$1" "*/$1" | head -n 1)" ]]; }

if [[ -n "$HOOK" ]]; then
	check "the working tree is the pushed commit" "" 1 tree_check
fi

check "real-mail fence" "" 1 scripts/check.sh --fence-only

if changed '^ios/'; then
	check "HasalaCore import lint" "" 1 ios/scripts/check-imports.sh --no-manifest
	check "HasalaCore forbidden-API lint" "" 1 ios/scripts/check-forbidden.sh
else
	skip "HasalaCore import and API lints" "no ios/ changes"
fi

NEW_COMMITS="$(git rev-list --count "${GL[@]}")"
if [[ "$NEW_COMMITS" -eq 0 ]]; then
	skip "gitleaks" "no new commits"
else
	check "gitleaks ($NEW_COMMITS new commit(s))" gitleaks 1 gitleaks_check
	needs_mb 100
fi

GO_PATHS='(\.go|(^|/)go\.(mod|sum|work|work\.sum))$'
if changed "$GO_PATHS"; then
	GOFILES="$(all_files '\.go$' | grep -v '^server/oracle/v1ref/' || true)"
	if [[ -n "$GOFILES" ]]; then
		check "gofmt" gofmt 1 gofmt_check
	else
		skip "gofmt" "no Go file to format"
	fi
	GO_CHANGED="$(grep -E "$GO_PATHS" <<<"$PATHS" || true)"
	GO_ORACLE="$(grep '^server/oracle/' <<<"$GO_CHANGED" || true)"
	GO_SERVER="$(grep '^server/' <<<"$GO_CHANGED" | grep -v '^server/oracle/' || true)"
	GO_OTHER="$(grep -v '^server/' <<<"$GO_CHANGED" || true)"
	if [[ -n "$ALL" || -n "$GO_SERVER" ]]; then
		check "go vet server/" go 4 vet_module server
		early
		needs_mb 350
	fi
	if [[ -n "$ALL" || -n "$GO_ORACLE" ]]; then
		check "go vet server/oracle/" go 4 vet_module server/oracle
		early
		needs_mb 350
	fi
	if [[ -z "$ALL" && -n "$GO_OTHER" ]]; then
		miss "go vet outside server/" "Go files changed outside the modules that this script knows (server/, server/oracle/); add their module to scripts/pre-push.sh"
	fi
else
	skip "gofmt, go vet" "no Go changes"
fi

if changed '\.nix$'; then
	NIXFILES="$(all_files '\.nix$')"
	if [[ -n "$NIXFILES" ]]; then
		check "nixfmt --check" nixfmt 1 nixfmt_check
	else
		skip "nixfmt" "only deleted Nix files changed"
	fi
else
	skip "nixfmt" "no Nix changes"
fi

if changed '^(ios/|design/tokens/)'; then
	if changed '^(design/tokens/|ios/tools/tokens/|ios/HasalaKit/.*(Generated|Tokens))'; then
		mac_only "design tokens are generated" ios-tools swift swift ios/tools/tokens/generate.swift --check
	else
		skip "design tokens" "no token changes"
	fi
	if changed '^ios/(project\.yml|Hasala\.xcodeproj/|scripts/generate-project\.sh)'; then
		if [[ -n "${XCODEGEN:-}" ]]; then
			mac_only "Xcode project matches project.yml" ios-tools "" ios/scripts/generate-project.sh --check
		else
			mac_only "Xcode project matches project.yml" ios-tools xcodegen ios/scripts/generate-project.sh --check
		fi
	else
		skip "Xcode project" "no project changes"
	fi
	if changed '^ios/(HasalaCore/(Package\.resolved|Tools/)|Hasala\.xcodeproj/project\.xcworkspace/xcshareddata/swiftpm/|scripts/check-tool-pins\.sh)'; then
		check "HasalaCore tool pins equal HasalaCore's" jq 1 ios/scripts/check-tool-pins.sh
	else
		skip "HasalaCore tool pins" "no Package.resolved or tool changes"
	fi
else
	skip "design tokens, Xcode project, tool pins" "no ios/ changes"
fi

if changed '^(ios/HasalaCore/Sources/HasalaCore/Resources/(templates/|TemplatesManifest\.swift$)|server/internal/tmpl/seed/|scripts/(tests/templates_manifest_test|check-templates-manifest)\.sh$)'; then
	check "bundled templates equal the server seed" "" 1 templates_check
	check "template manifest check self-test" "" 1 scripts/tests/templates_manifest_test.sh
	check "template manifest matches the seed" "" 1 scripts/check-templates-manifest.sh
else
	skip "bundled templates" "no template or seed changes"
fi

if changed '^scripts/(private-fixtures-lock|tests/private_fixtures_lock_test)\.sh$'; then
	check "private fixtures lock self-test" "" 1 scripts/tests/private_fixtures_lock_test.sh
else
	skip "private fixtures lock self-test" "no lock script changes"
fi

if changed '^scripts/(check\.sh|gotest-(ran|summary)\.ts|tests/(gate_run|gotest_ran|git_env|fence)_test\.sh)$'; then
	check "conformance record self-test" bun 1 scripts/tests/gotest_ran_test.sh
	slow "real-mail fence self-test" 6 gate "" 1 scripts/tests/fence_test.sh
	slow "gate run self-test" 4 gate bun 1 scripts/tests/gate_run_test.sh
	needs_mb 200
else
	skip "gate self-tests" "no gate changes"
fi

if changed '^(\.githooks/|scripts/(pre-push|install-hooks)\.sh$|scripts/tests/pre_push_hook_test\.sh$)'; then
	slow "pre-push hook self-test" 9 gate "go gofmt nixfmt shellcheck gitleaks" 4 scripts/tests/pre_push_hook_test.sh
	needs_mb 400
else
	skip "pre-push hook self-test" "no hook changes"
fi

if changed '^(\.githooks/|scripts/(check|pre-push|install-hooks)\.sh$|scripts/gotest-(ran|summary)\.ts$|scripts/tests/(gate_run|gotest_ran|git_env|fence|pre_push_hook)_test\.sh$)'; then
	slow "self-tests leave the repository alone" 20 gate "bun go gofmt nixfmt shellcheck gitleaks" 4 scripts/tests/git_env_test.sh
	needs_mb 400
fi

if changed '(\.sh$|^\.githooks/)'; then
	SHFILES="$(all_files '(\.sh$|^\.githooks/)')"
	if [[ -n "$SHFILES" ]]; then
		check "shellcheck" shellcheck 3 shellcheck_check
		needs_mb 180
	else
		skip "shellcheck" "only deleted scripts changed"
	fi
else
	skip "shellcheck" "no shell changes"
fi

JS_PATHS='\.(ts|tsx|mts|cts|js|jsx|mjs|cjs|astro)$'
if changed '(^|/)\.ox(lint|fmt)rc\.jsonc?$'; then
	JSFILES="$(git ls-files | { grep -E "$JS_PATHS" || true; })"
else
	JSFILES="$(all_files "$JS_PATHS")"
fi
if [[ -z "$JSFILES" ]]; then
	skip "oxfmt, oxlint" "no TypeScript, JavaScript or Astro changes"
else
	FMTFILES="$(printf '%s\n' "$JSFILES" | { grep -v '\.astro$' || true; })"
	if [[ -z "$FMTFILES" ]]; then
		skip "oxfmt" "only Astro files changed, and oxfmt does not read them"
	elif tracked .oxfmtrc.json || tracked .oxfmtrc.jsonc; then
		check "oxfmt --check" oxfmt 1 oxfmt_check
	else
		left "oxfmt" "this tree has no .oxfmtrc.json, so no formatter is set up for TypeScript"
	fi
	if tracked .oxlintrc.json; then
		check "oxlint" oxlint 1 oxlint_check
	else
		left "oxlint" "this tree has no .oxlintrc.json, so no linter is set up for TypeScript"
	fi
fi

TSFOUND="$(ts_projects)"
TSPROJECTS="$(grep -v '^!' <<<"$TSFOUND" || true)"
TSLOOSE="$(grep '^!' <<<"$TSFOUND" | cut -c2- | tr '\n' ' ' || true)"
if [[ -n "$TSLOOSE" ]]; then
	left "typecheck of ${TSLOOSE% }" "no tsconfig.json covers it, so no job typechecks it"
fi
if [[ -z "$TSPROJECTS" ]]; then
	skip "typecheck" "no change in a TypeScript project"
else
	while IFS= read -r project; do
		if [[ ! -d "$project/node_modules" ]]; then
			miss "typecheck $project/" "$project/node_modules is missing; run: (cd $project && bun install --frozen-lockfile)"
		elif have tsgo; then
			check "typecheck $project/ (tsgo)" node 2 typecheck "$project"
			early
			needs_mb 350
		else
			check "typecheck $project/ (tsc; tsgo is not on PATH)" node 2 typecheck "$project"
			early
			needs_mb 350
		fi
	done <<<"$TSPROJECTS"
fi

if changed '^(web/|docs/legal/)'; then
	if [[ -z "$HOOK" && ! -d web/node_modules ]]; then
		miss "web: astro check" "web/node_modules is missing; run: (cd web && bun install --frozen-lockfile)"
	else
		slow "web: astro check" 10 web bun 2 astro_check
		needs_mb 600
	fi
else
	skip "web: astro check" "no web or legal changes"
fi

missing_tools() {
	local i t tools
	for ((i = 0; i < N; i++)); do
		[[ "${KIND[i]}" == run ]] || continue
		read -r -a tools <<<"${TOOLS[i]}"
		for t in ${tools[@]+"${tools[@]}"}; do
			have "$t" || printf '%s\n' "$t"
		done
	done | LC_ALL=C sort -u
}

DEVSHELL_ERRORS=""
if [[ -z "$ENTERED" && -n "$(missing_tools)" ]]; then
	for how in direnv nix; do
		have "$how" || continue
		rc=0
		case "$how" in
		direnv)
			printf '%s\n' "$REFS" | DIRENV_LOG_FORMAT="" direnv exec "$ROOT" \
				"$ROOT/scripts/pre-push.sh" --resume "$T0" "$LOG/entered" "$how" ${PASS_ARGS[@]+"${PASS_ARGS[@]}"} 3>&2 2>"$LOG/devshell.$how" || rc=$?
			;;
		nix)
			printf '%s\n' "$REFS" | nix --extra-experimental-features 'nix-command flakes' develop "$ROOT" --command \
				"$ROOT/scripts/pre-push.sh" --resume "$T0" "$LOG/entered" "$how" ${PASS_ARGS[@]+"${PASS_ARGS[@]}"} 3>&2 2>"$LOG/devshell.$how" || rc=$?
			;;
		esac
		if [[ -e "$LOG/entered" ]]; then
			exit "$rc"
		fi
		DEVSHELL_ERRORS+="$how: $(tail -n 3 "$LOG/devshell.$how" | tr '\n' ' ')"$'\n'
	done
fi

for ((i = 0; i < N; i++)); do
	[[ "${KIND[i]}" == run ]] || continue
	read -r -a tools <<<"${TOOLS[i]}"
	for t in ${tools[@]+"${tools[@]}"}; do
		if ! have "$t"; then
			KIND[i]=miss
			NOTE[i]="$t is not on PATH"
			break
		fi
	done
done

memory_left_mb() {
	local dir="${HASALA_PRE_PUSH_CGROUP:-}" max current file
	if [[ -z "$dir" && -r /proc/self/cgroup ]]; then
		dir="/sys/fs/cgroup$(sed -n 's/^0:://p' /proc/self/cgroup)"
	fi
	if [[ -z "$dir" || ! -r "$dir/memory.max" || ! -r "$dir/memory.current" || ! -r "$dir/memory.stat" ]]; then
		return 0
	fi
	max="$(<"$dir/memory.max")"
	current="$(<"$dir/memory.current")"
	if [[ ! "$max" =~ ^[0-9]+$ || ! "$current" =~ ^[0-9]+$ ]]; then
		return 0
	fi
	file="$(awk '$1 == "active_file" || $1 == "inactive_file" {s += $2} END {printf "%d", s}' "$dir/memory.stat")"
	echo "$(((max - current + file) / 1048576)) $((max / 1048576))"
}

LOW_MEMORY=""
read -r MEM_LEFT MEM_MAX < <(memory_left_mb) || true
if [[ -n "${MEM_LEFT:-}" ]] && ((MEM_LEFT < MEM_LOW_MB)); then
	LOW_MEMORY="the memory group of this process has $MEM_LEFT MiB left of $MEM_MAX MiB, so the checks ran one at a time"
	JOBS=1
	MEM_CAP_MB=0
	VET_JOBS=1
fi

LAUNCHED=()
USED=0
MEM_USED=0

slots_used() {
	local i
	USED=0
	MEM_USED=0
	for i in ${LAUNCHED[@]+"${LAUNCHED[@]}"}; do
		if [[ ! -e "$LOG/$i.rc" ]]; then
			USED=$((USED + WEIGHT[i]))
			MEM_USED=$((MEM_USED + MEM[i]))
		fi
	done
}

launch() {
	local i="$1"
	while :; do
		slots_used
		if ((USED == 0)) || ((USED + WEIGHT[i] <= JOBS && MEM_USED + MEM[i] <= MEM_CAP_MB)); then
			break
		fi
		sleep 0.02
	done
	(
		start="$(now_us)"
		rc=0
		read -r -a words <<<"${CMD[i]}"
		("${words[@]}") >"$LOG/$i.out" 2>&1 </dev/null || rc=$?
		printf '%s %s\n' "$rc" "$(($(now_us) - start))" >"$LOG/$i.rc.tmp"
		mv "$LOG/$i.rc.tmp" "$LOG/$i.rc"
	) &
	LAUNCHED+=("$i")
}

for first in 1 0; do
	for ((i = 0; i < N; i++)); do
		[[ "${KIND[i]}" == run ]] || continue
		if ((EARLY[i] == first)); then
			launch "$i"
		fi
	done
done
wait

if [[ -n "$LOW_MEMORY" ]]; then
	echo "pre-push: $LOW_MEMORY"
fi
if [[ "$VIA" == nix ]]; then
	echo "pre-push: the tools came through nix develop, because direnv exec did not start the devShell. That is slower: run 'direnv allow .' once in $ROOT."
fi

echo "pre-push: $WHAT$([[ -n "$ALL" ]] && echo ', every file' || echo ", $(printf '%s\n' "$PATHS" | grep -c . || true) changed path(s)")"

PASSED=0
FAILED=0
MISSING=0
SKIPPED=0
LEFT=0
for ((i = 0; i < N; i++)); do
	case "${KIND[i]}" in
	run)
		read -r rc took <"$LOG/$i.rc"
		if [[ "$rc" -eq 0 ]]; then
			printf 'PASS     %s (%ss)\n' "${NAME[i]}" "$(seconds "$took")"
			PASSED=$((PASSED + 1))
		else
			printf 'FAIL     %s (%ss)\n' "${NAME[i]}" "$(seconds "$took")"
			sed 's/^/         /' "$LOG/$i.out"
			FAILED=$((FAILED + 1))
		fi
		;;
	miss)
		printf 'MISSING  %s (%s)\n' "${NAME[i]}" "${NOTE[i]}"
		MISSING=$((MISSING + 1))
		;;
	left)
		printf 'NOT RUN  %s (%s)\n' "${NAME[i]}" "${NOTE[i]}"
		LEFT=$((LEFT + 1))
		;;
	skip)
		printf 'SKIP     %s (%s)\n' "${NAME[i]}" "${NOTE[i]}"
		SKIPPED=$((SKIPPED + 1))
		;;
	esac
done

ELAPSED=$(($(now_us) - T0))
SUMMARY="$PASSED passed, $FAILED failed, $MISSING could not run, $LEFT not run here, $SKIPPED not needed"
if [[ -n "$HOOK" ]]; then
	echo "pre-push: $SUMMARY; $(seconds "$ELAPSED")s of the ${BUDGET}s budget"
else
	echo "pre-push: $SUMMARY; $(seconds "$ELAPSED")s"
fi

STATUS=0
if ((MISSING)); then
	echo "pre-push: $MISSING check(s) could not run, and that is not a pass. The tools come from the devShell: run 'direnv allow .' once in $ROOT, then try again."
	if [[ -n "$DEVSHELL_ERRORS" ]]; then
		printf '%s' "$DEVSHELL_ERRORS" | sed 's/^/pre-push: the devShell did not start: /'
	fi
	STATUS=1
fi
if ((FAILED)); then
	STATUS=1
fi
if [[ -n "$HOOK" ]] && ((ELAPSED > BUDGET * 1000000)); then
	echo "pre-push: the hook took $(seconds "$ELAPSED")s, over its ${BUDGET}s budget."
	if ((STATUS == 0)) && [[ "$VIA" == nix ]]; then
		echo "pre-push: every check passed, but nix develop took most of the time. Run 'direnv allow .' once in $ROOT, then push again."
	elif ((STATUS == 0)); then
		echo "pre-push: every check passed. Push again: the caches are warm now. If it happens again on a quiet machine, fix the slowest check above or move it to CI."
	fi
	STATUS=1
fi
if [[ -n "$HOOK" ]] && ((STATUS)); then
	echo "pre-push: the push is refused."
fi
exit "$STATUS"
