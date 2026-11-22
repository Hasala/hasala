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
