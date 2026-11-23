# CI: concurrency, caches and weekly runs

The required checks, the jobs and the path rules are in `CLAUDE.md` ("CI").
This page has the details that only matter when you change the CI.

## Concurrency

- A new push to a pull request cancels the older run of that pull request.
- A push to `main` does not cancel an older run as a whole. But a newer push
  to `main` cancels the Mac jobs (`swift` and `ios-tools`) of an older push, if they are in the
  queue or running. Each of these jobs has a job-level `concurrency` group for
  this.
- The newest push to `main` still runs its Mac jobs, because some pull
  requests merge before their Mac jobs finish.
- A manual run is not cancelled.

## Caches

The repository has 10 GB of Actions cache. Above it, GitHub deletes the
entries that were used least recently.

- `actions/cache` keeps the Go caches (`gate`, `vuln` only reads them), the
  Bun caches (`gate`, `web`) and the SwiftPM caches (`swift`).
- `nix-community/cache-nix-action` keeps the Nix store. There are four entries,
  with the key `nix-<runner OS>-<name>-<hash of flake.lock and flake.nix>`:
  `devshell` (the devShell; `gate`, `vuln` and `web` restore it), `checks`
  (the inputs of the flake checks; `gate`), `vm` (the inputs of `qa-vm`;
  `nixos-vm`) and `ios-tools` (the Mac devShell, XcodeGen and shellcheck).
- The test jobs only restore. They do not save and they do not build the
  tools again, thus their setup time does not change from run to run.
- The jobs `nix-cache` and `nix-cache-mac` save the entries
  (`scripts/ci-nix-seed.sh`). `changes` asks the cache API if each entry
  exists. The seed jobs run only when one is missing: on `main`, and on a
  pull request that changes `flake.nix` or `flake.lock`. A pull request saves
  into its own scope. The test jobs wait for the seed jobs.
- A seed job starts with an empty store. `devshell` and `ios-tools` keep only
  the closure of the devShell and the flake inputs (garbage collection to
  zero, with GC roots). `checks` and `vm` keep all that their build got.
- On `main`, a seed job deletes the older entries with the same prefix
  (`purge`). For this, only the seed jobs have `actions: write`.
- A pull request that saved entries keeps them in its own scope. When it
  closes, `.github/workflows/cache-cleanup.yml` deletes them.
- Do not use `magic-nix-cache-action` again. It saved one entry for each
  store path, with a random suffix, also in the scopes of pull requests. On
  2026-10-20 it had 5300 entries (9.5 GB) for 974 different paths (1.5 GB).

## Time budgets

`scripts/ci-budget.sh` has one budget for each job, in seconds, and one for
the path to the result (the start of the run to the end of the jobs that
`ci-ok` needs). The time of a job is its start to its end: the setup and the
steps, not the wait for a runner.

- The budgets of 2026-11-22 are about 1.3 times the slowest run of each job in
  that day's runs, with empty caches and with full caches. A run with empty
  caches must stay in the budget, or each pull request that changes the flake
  fails.
- `ci-ok` reads the jobs of the run from the GitHub API and compares the jobs
  that it needs. The job `budget` compares all jobs. A job that failed or was
  cancelled is not a budget failure. A job of the run with no budget is one.
- In a second attempt that runs only some jobs, each other job keeps its
  first time, thus a new attempt of `ci-ok` cannot clear a slow job. The path
  to the result is measured only in an attempt that runs all the jobs.
- When `ci.yml` is called from another workflow (`ci-weekly.yml`), the names
  of its jobs start with the name of the calling job. The script reads the
  part after ` / ` and does not measure the jobs of the caller.
- `scripts/tests/ci_budget_test.sh` tests the script with job lists in a
  file (`--jobs FILE`). `scripts/check.sh` runs it.

## Weekly runs

`.github/workflows/vuln-weekly.yml` runs the same govulncheck on `main` each
Monday (job `vuln-weekly`, not required). This is necessary because new Go
advisories occur without new commits. It is a different workflow, thus it
does not record checks on the head of `main` with the required names.

`.github/workflows/ci-weekly.yml` runs each Sunday (not required):

- Job `ci` calls `ci.yml` (`workflow_call`). The event is `schedule`, thus
  `changes` starts all jobs and the path rules do not apply. This finds jobs
  that the path rules skipped for weeks. Its checks have the names
  `ci / <job>`, thus they are not the required names.
- Job `cache-usage` fails when the Actions cache of the repository is more
  than 8 GB (`gh api repos/{repo}/actions/cache/usage`).
- A pull request that changes `ci-weekly.yml` runs only `cache-usage`.

## Timing

`bun scripts/ci-timing.ts` reads the last runs of a workflow with `gh api` and
prints, for each job, the time in the queue (waiting), the time in setup steps
and the time in the other steps (running), at p50 and p95. It also prints the
time from the start of a pull request's run to its `ci-ok` result.

- `--runs N` sets the number of completed runs (default 150).
- `--event pull_request` and `--branch NAME` select runs.
- `--steps` adds a table of the steps.
- `--dir DIR` keeps the downloaded job data for the next call.
- `SETUP_STEPS` in the script names the setup steps: checkout, the Nix
  installer, cache steps, dependency installs and the steps after the job. When
  you add a setup step, give it a name that this list finds.

Measure before and after each change to the CI, and put the two tables in the
pull request.

### Baseline (2026-10-29 to 2026-11-21, 150 runs)

All times are seconds, p50 / p95.

| Measure | Runs | p50 / p95 | Max |
| --- | --- | --- | --- |
| Run created to `ci-ok` done (pull requests) | 54 | 50 / 394 | 575 |
| Run created to the last job done (pull requests) | 54 | 628 / 2704 | 6125 |

| Job | Jobs | Waiting | Setup | Running | Total |
| --- | --- | --- | --- | --- | --- |
| `changes` | 149 | 2 / 2 | 3 / 6 | 0 / 1 | 6 / 9 |
| `ci-ok` | 146 | 2 / 3 | 0 / 1 | 0 / 1 | 3 / 4 |
| `gate` | 44 | 2 / 2 | 67 / 192 | 296 / 340 | 362 / 605 |
| `ios-tools` | 77 | 21 / 1885 | 119 / 142 | 433 / 889 | 553 / 1017 |
| `nixos-vm` | 31 | 2 / 3 | 52 / 368 | 109 / 199 | 167 / 569 |
| `secrets` | 148 | 2 / 3 | 14 / 19 | 25 / 27 | 41 / 46 |
| `swift` | 73 | 4 / 2784 | 20 / 25 | 536 / 634 | 565 / 666 |
| `vuln` | 46 | 2 / 3 | 57 / 94 | 27 / 75 | 87 / 453 |
| `web` | 61 | 2 / 3 | 71 / 154 | 103 / 118 | 176 / 268 |

- `gate` ran in 44 of the 150 runs. The path rules skipped it in 102.
- The Mac jobs wait when more than five Mac jobs are in progress for the
  account. The longest wait was 50 minutes.
- The runs used 5524 minutes of `macos-26` and 883 minutes of `ubuntu-latest`.

## Merge queue

The ruleset of `main` has the rule "Require merge queue" since 2026-11-22,
when the repository moved to the `Hasala` organization (GitHub gives merge
queues only to repositories that an organization owns). A pull request
merges only through the queue, with the squash method. It does not have to
be up to date with `main`: the queue tests it on top of `main` and of the
entries before it.

`ci.yml` runs on the merge group (`merge_group`). The path rules do not apply
to this event, thus each Linux job runs. The Mac jobs (`swift` and
`ios-tools`, and the Mac seed job `nix-cache-mac`) skip on a merge group, by the owner's choice (2026-11-23): the
free plan has five Mac runners, and they made each queue entry wait. The
queue merges when `ci-ok` passes, as on a pull request. The push to `main`
then runs the Mac jobs on the merged commit, with the usual path rules.
