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
- `nix-community/cache-nix-action` keeps the Nix store in `gate`, `vuln`,
  `nixos-vm`, `web` and `ios-tools`. Each job has one entry, with the key
  `nix-<runner OS>-<job>-<hash of flake.lock>`.
- Only a push to `main` saves a Nix entry. Pull requests and manual runs only
  restore it. When `flake.lock` changes, a run restores the newest entry with
  the same prefix.
- Before a save, the job collects garbage until the store is at most
  `gc-max-store-size`. After a save, it deletes the older entries of the same
  prefix on `main` (`purge`). For this, these jobs have `actions: write`.
- Do not use `magic-nix-cache-action` again. It saved one entry for each
  store path, with a random suffix, also in the scopes of pull requests. On
  2026-10-20 it had 5300 entries (9.5 GB) for 974 different paths (1.5 GB).

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
