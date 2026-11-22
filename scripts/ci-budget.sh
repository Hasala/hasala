#!/usr/bin/env bash
set -euo pipefail

budget() {
	case "$1" in
	changes) echo 30 ;;
	secrets) echo 75 ;;
	nix-cache) echo 240 ;;
	nix-cache-mac) echo 480 ;;
	nix-eval) echo 30 ;;
	nix-build) echo 180 ;;
	gate) echo 300 ;;
	vuln) echo 100 ;;
	nixos-vm) echo 240 ;;
	web) echo 120 ;;
	web-lighthouse) echo 180 ;;
	swift) echo 960 ;;
	ios-tools) echo 1080 ;;
	*) return 1 ;;
	esac
}
path_budget=480
wait_limit=10
not_measured='^(ci-ok|budget)$'

usage() {
	echo "usage: scripts/ci-budget.sh [--jobs FILE] (--all | JOB...)" >&2
	exit 2
}

file=""
all=0
wanted=()
while (($#)); do
	case "$1" in
	--jobs)
		[[ $# -ge 2 ]] || usage
		file="$2"
		shift 2
		;;
	--all)
		all=1
		shift
		;;
	-*) usage ;;
	*)
		wanted+=("$1")
		shift
		;;
	esac
done
if ((all)) && ((${#wanted[@]})); then usage; fi
if ! ((all)) && ! ((${#wanted[@]})); then usage; fi

fetch() {
	local attempt="repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/attempts/$GITHUB_RUN_ATTEMPT"
	gh api "$attempt" --jq '["run", .run_started_at, .run_attempt] | @tsv'
	gh api "$attempt/jobs?per_page=100" --paginate \
		--jq '.jobs[] | [.name, .status, (.conclusion // "-"), .created_at, (.started_at // "-"), (.completed_at // "-")] | @tsv'
}

if [[ -n "$file" ]]; then
	data="$(cat "$file")"
else
	data="$(fetch)"
fi

epoch() { date -u -d "$1" +%s; }

called=0
if cut -f1 <<<"$data" | grep -q ' / '; then called=1; fi

run_start=""
run_attempt=""
carried=0
last_end=0
failures=0
seen=()
printf 'ci-budget: %-28s %8s %8s %8s\n' job "run s" "budget" "wait s"
while IFS=$'\t' read -r name status conclusion created started completed; do
	if [[ "$name" == run ]]; then
		run_start="$(epoch "$status")"
		run_attempt="$conclusion"
		continue
	fi
	if ((called)) && [[ "$name" != *" / "* ]]; then continue; fi
	base="${name##* / }"
	base="${base%% (*}"
	[[ "$base" =~ $not_measured ]] && continue
	if ! ((all)); then
		hit=0
		for w in "${wanted[@]}"; do [[ "$w" == "$base" ]] && hit=1; done
		((hit)) || continue
	fi
	seen+=("$base")
	if ! limit="$(budget "$base")"; then
		echo "::error::the job '$name' has no time budget; add one to scripts/ci-budget.sh"
		failures=$((failures + 1))
		continue
	fi
	if [[ "$conclusion" == skipped ]]; then
		printf 'ci-budget: %-28s %8s %8s %8s\n' "$name" skipped "$limit" -
		continue
	fi
	if [[ "$status" != completed ]]; then
		echo "::error::the job '$name' is not complete ($status), so its time is not known"
		failures=$((failures + 1))
		continue
	fi
	if [[ "$conclusion" != success ]]; then
		printf 'ci-budget: %-28s %8s %8s %8s\n' "$name" "$conclusion" "$limit" -
		continue
	fi
	begin="$(epoch "$started")"
	end="$(epoch "$completed")"
	ran=$((end - begin))
	waited=$((begin - $(epoch "$created")))
	((end > last_end)) && last_end=$end
	if ((waited < 0)); then
		carried=1
		waited="-"
	fi
	printf 'ci-budget: %-28s %8s %8s %8s\n' "$name" "$ran" "$limit" "$waited"
	if ((ran > limit)); then
		echo "::error::the job '$name' ran $ran s; its budget is $limit s (scripts/ci-budget.sh)"
		failures=$((failures + 1))
	fi
	if [[ "$waited" != - ]] && ((waited > wait_limit)); then
		echo "::warning::the job '$name' waited $waited s for a runner; the limit that we want is $wait_limit s"
	fi
done <<<"$data"

if ! ((all)); then
	for w in "${wanted[@]}"; do
		hit=0
		for s in "${seen[@]:-}"; do [[ "$s" == "$w" ]] && hit=1; done
		if ! ((hit)); then
			echo "::error::the run has no job '$w'"
			failures=$((failures + 1))
		fi
	done
	if [[ -z "$run_start" ]]; then
		echo "::error::the start time of the run is not known"
		failures=$((failures + 1))
	elif ((carried)); then
		printf 'ci-budget: %-28s %8s %8s %8s\n' "run start to these jobs" "-" "$path_budget" -
		echo "::warning::attempt $run_attempt did not run all of these jobs, so the time from the run start is not measured"
	elif ((last_end > 0)); then
		took=$((last_end - run_start))
		printf 'ci-budget: %-28s %8s %8s %8s\n' "run start to these jobs" "$took" "$path_budget" -
		if ((took > path_budget)); then
			echo "::error::the run took $took s from its start to the end of these jobs; the budget is $path_budget s (scripts/ci-budget.sh)"
			failures=$((failures + 1))
		fi
	fi
fi

if ((failures > 0)); then
	echo "ci-budget: $failures failure(s)"
	exit 1
fi
echo "ci-budget: ok"
