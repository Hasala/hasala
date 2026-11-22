#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
check="$ROOT/scripts/ci-budget.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0

job() {
	local name="$1" conclusion="$2" created="$3" started="$4" completed="$5" status=completed
	[[ "$conclusion" == - ]] && status=in_progress
	printf '%s\t%s\t%s\t2026-11-22T08:%s\t2026-11-22T08:%s\t2026-11-22T08:%s\n' \
		"$name" "$status" "$conclusion" "$created" "$started" "$completed" >>"$work/jobs"
}

start() {
	printf 'run\t2026-11-22T08:%s\t%s\n' "${1:-00:00Z}" "${2:-1}" >"$work/jobs"
}

expect() {
	local name="$1" want="$2" text="$3" rc=0 out
	shift 3
	out="$("$check" --jobs "$work/jobs" "$@" 2>&1)" || rc=$?
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

start
job changes success 00:02Z 00:08Z 00:17Z
job "nix-cache (devshell)" success 00:18Z 00:19Z 01:40Z
job gate success 01:41Z 01:42Z 03:38Z
job vuln success 01:41Z 01:43Z 02:32Z
job ci-ok - 03:39Z 03:40Z 03:40Z
expect "jobs in their budgets pass" 0 "ci-budget: ok" changes gate vuln
expect "the time from the run start is printed" 0 "run start to these jobs" changes gate vuln
expect "all jobs of the run pass" 0 "ci-budget: ok" --all

start
job changes success 00:02Z 00:08Z 00:17Z
job gate success 00:18Z 00:19Z 05:20Z
expect "a job above its budget fails" 1 "the job 'gate' ran 301 s; its budget is 300 s" changes gate

start
job gate success 00:18Z 00:19Z 05:19Z
expect "a job at its budget passes" 0 "ci-budget: ok" gate

start
job "nix-cache (devshell)" success 00:18Z 00:19Z 01:40Z
job "nix-cache (vm)" success 00:18Z 00:19Z 04:30Z
expect "one matrix leg above its budget fails" 1 "the job 'nix-cache (vm)' ran 251 s" --all

start
job "ci / changes" success 00:02Z 00:08Z 00:17Z
job "ci / nix-cache (vm)" success 00:18Z 00:19Z 04:30Z
expect "a job of a called workflow uses the budget of its own name" 1 "the job 'ci / nix-cache (vm)' ran 251 s" changes nix-cache

start
job "cache usage" success 00:02Z 00:08Z 00:17Z
job "ci / changes" success 00:02Z 00:08Z 00:17Z
job "ci / gate" success 00:18Z 00:19Z 03:00Z
expect "in a called workflow, the jobs of the caller are not measured" 0 "ci-budget: ok" --all

start
job changes success 00:02Z 00:08Z 00:17Z
job deploy success 00:18Z 00:19Z 00:40Z
expect "a job with no budget fails" 1 "the job 'deploy' has no time budget" --all

start
job changes success 00:02Z 00:08Z 00:17Z
expect "a named job that the run does not have fails" 1 "the run has no job 'gate'" changes gate

start
job changes success 00:02Z 00:08Z 00:17Z
job gate skipped 00:18Z 00:18Z 00:18Z
expect "a skipped job passes" 0 "ci-budget: ok" changes gate

start
job changes success 00:02Z 00:08Z 00:17Z
job gate success 00:18Z 01:22Z 03:00Z
expect "a long wait for a runner is a warning, not a failure" 0 "::warning::the job 'gate' waited 64 s" changes gate

start
job changes success 00:02Z 00:08Z 00:17Z
job gate success 05:00Z 05:01Z 08:01Z
expect "a slow path to the result fails" 1 "the run took 481 s from its start" changes gate

start 20:00Z 2
job changes success 20:01Z 00:08Z 00:17Z
job gate success 20:01Z 20:02Z 22:00Z
expect "an attempt that ran only some of the jobs does not measure the path" 0 "attempt 2 did not run all of these jobs" changes gate

start 20:00Z 2
job changes success 20:01Z 00:08Z 00:17Z
job gate success 20:01Z 00:19Z 05:20Z
expect "a new attempt does not clear a job above its budget" 1 "the job 'gate' ran 301 s" changes gate

start
job changes success 00:02Z 00:08Z 00:17Z
job web failure 00:18Z 00:19Z 09:00Z
expect "a failed job is not a budget failure" 0 "ci-budget: ok" --all

start
job changes success 00:02Z 00:08Z 00:17Z
job web - 00:18Z 00:19Z 00:19Z
expect "a job that is not complete fails" 1 "the job 'web' is not complete" --all

rc=0
"$check" >/dev/null 2>&1 || rc=$?
if [[ "$rc" == 2 ]]; then
	echo "ok   no job name is a usage error"
else
	echo "FAIL no job name is a usage error: exit $rc, want 2"
	failures=$((failures + 1))
fi

if ((failures > 0)); then
	echo "ci_budget_test: $failures failure(s)"
	exit 1
fi
echo "ci_budget_test: all passed"
