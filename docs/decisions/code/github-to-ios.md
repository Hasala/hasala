# CI, the flake, the QA module and the app shell: decisions from the code (2026-11-21)

These decisions were code comments under `.github/workflows/`, `.gitleaks.toml`,
`flake.nix`, `infra/qa/`, `ios/Config/` and `ios/Hasala/App/`. Code comments are
not permitted (`scripts/comment-lint.ts`), thus the decisions are here.

The required checks, the path rules and the concurrency rules of the CI are in `CLAUDE.md`
("CI") and `docs/ci.md`. They are not repeated here.

## CI: required job ids, pinned actions and trusted caches

A required job has no `name:` and no matrix. Thus its job id is its check name, and the
ruleset finds it by that name. A `name:` or a matrix changes the check name, and the
ruleset then waits for a check that never reports.

Each action is pinned to a full commit SHA. A tag can move to other code, a commit cannot.

A cache is trusted because of its key and its scope:

- Each `actions/cache` key is the hash of the files that pin the contents (`flake.lock`
  for Go, `go.sum`, `bun.lock`, `Package.resolved`). A run saves an entry only when that
  exact key is missing.
- A run of a pull request saves only into its own scope. It reads its own scope and the
  scope of `main`, never the scope of another pull request. `main` reads only its own.
- The Go build cache is content-addressed. SwiftPM checks out the revision that
  `Package.resolved` pins, from the cache or from the network.
- `scripts/check.sh` runs each Go test with `-count=1`. Thus no test result comes from a
  cache.

Only `gate` saves the Go caches. `vuln` restores them and does not save. If `vuln` also
saved, it could write the key first with a smaller cache, and `gate` would then compile
all dependencies in each run.

Applies to: `.github/workflows/ci.yml` (jobs `gate`, `vuln`, `swift`, `web`).

## The changed-path list is the diff of the merge commit, with no rename detection

On a pull request, the checkout is the merge commit, with depth 2. Thus
`git diff HEAD^1 HEAD` is exactly the change that a merge makes on the base as it is now.

The diff uses `--no-renames`. A move then shows as a deleted path and an added path, so a
file that moves out of an area still starts the jobs of that area. With rename detection,
only the new path shows, and the job of the old area is skipped.

The diff uses `-z`. Without it, git quotes a path that has special or non-ASCII characters,
and no anchored pattern agrees with that line.

Applies to: `.github/workflows/ci.yml` (job `changes`).

## The secrets job repeats the fence and the HasalaCore lints

`gate` runs the real-mail fence and the HasalaCore lints, but CI skips `gate` when a pull
request changes nothing that `gate` reads (for example a change in `ios/` only). `swift` is
not a required check. Thus `secrets`, which always runs, does these checks again. They use
only bash, grep and awk, and take some seconds.

Do not remove them from `secrets` as a duplicate. A pull request that changes only `ios/`
then merges with no fence and no import lint.

Applies to: `.github/workflows/ci.yml` (job `secrets`).

## gitleaks scans only the history of the checked-out commit

`secrets` runs gitleaks with `--log-opts=HEAD`: each commit that the checked-out commit can
reach, examined with the `.gitleaks.toml` of that commit. The checkout has the full
history, because a secret that a later commit deletes is still published.

Without `--log-opts=HEAD`, gitleaks runs `git log --all`, and the full fetch brings each
branch. The allowlisted test vectors of one open branch then failed each other run, whose
`.gitleaks.toml` did not have them yet. Each branch with a pull request still gets a full
scan in the run of its pull request. A branch with no pull request is not scanned here.

The revision must be one that always resolves. gitleaks 8.30.1 exits 0 with "0 commits
scanned" when `git log` fails, so a revision that does not resolve gives a pass with no
scan.

`--redact` stays, because the log is public.

Applies to: `.github/workflows/ci.yml` (job `secrets`).

## The swift job pins its tools and also builds for iOS

HasalaCore has the platforms iOS 26 and macOS 26 and tools version 6.2. The job pins the
runner image to macOS 26 and selects Xcode by its path (`DEVELOPER_DIR`). It does not use
the default Xcode of the image, which changes without a commit.

`swift test` runs with `--disable-automatic-resolution`. `Package.resolved` is the pin. A
manifest that does not agree with it fails. Without the flag, SwiftPM resolves again and
the run can use versions that the lock does not pin.

`swift test` builds only for macOS. The `xcodebuild` step builds for the iOS simulator and
the device. Only this build finds a module that hides an Apple framework (this is why the
text module is `HasalaText` and not `CoreText`) and code that compiles only on a Mac. Do
not remove it as a duplicate of the tests.

Applies to: `.github/workflows/ci.yml` (job `swift`).

## The weekly scan is a separate workflow and may use a paths filter

New Go advisories occur without a commit, thus `vuln-weekly.yml` scans `main` each week. It
is a different workflow from `ci.yml`, so a scheduled run does not record a `gate`, `vuln`
or `secrets` check on the head of `main`. Its steps must stay the same as the steps of
`vuln` in `ci.yml`.

Its `pull_request` trigger has a `paths:` filter, which `CLAUDE.md` forbids for the CI.
The filter is permitted here because this job is not a required check, so no check can
stay pending.

Two facts about GitHub: a schedule always runs the copy of the file on the default branch,
and GitHub switches off the schedules of a public repository after 60 days with no
activity.

Applies to: `.github/workflows/vuln-weekly.yml`.

## The gitleaks allowlist holds only values that are public by construction

A new entry in `.gitleaks.toml` needs a value that is public by construction. "It is only
for tests" is not a reason. The entries that exist are of these kinds:

- a published test vector of a standard (an RFC key, a BIP-39 vector);
- a public key from the documentation of a library, and the example value that goes with
  it;
- a token that nobody signed and nobody can sign;
- a patterned synthetic key (the hex digits counted out);
- conformance vectors (spec 01 §15.1) that `server/cmd/gen-crypto-vectors` writes from the
  anchor inputs of spec 01 §15.5 or from its labelled SHA-256 stream. None of them is a
  credential or comes from one.

Each entry names one rule, exact files and the exact value, and all three must agree
(`condition = "AND"`). Do not allowlist a directory.

Some entries name files that are not in the tree now (`reference/`, the Web Push tests,
the dictionary tests). Keep these entries. `secrets` scans the full history, and those
files are still in it. If you remove an entry, the scan fails on the old commits.

Applies to: `.gitleaks.toml`.

## XcodeGen is the upstream release binary, pinned by hash

The flake does not build XcodeGen 2.46.0 from source. nixpkgs builds XcodeGen with its
Swift 5.10 toolchain, and 2.46.0 needs XcodeProj 9.14.0, whose manifest needs
swift-tools-version 6.0. Thus the package is the macOS binary of the upstream release,
fetched with a fixed hash. It is for darwin only.

Applies to: `flake.nix` (`xcodegenFor`).

## The hasalad package: static version, not stripped, no check phase

- The `version` of the package is a constant. The fixed-output derivation that holds the Go
  modules has this version in its name. A version for each commit makes Nix fetch all
  modules again for each commit. The commit goes into the binary through `ldflags`
  (`hasalad version` prints it). `ldflags` do not reach the modules derivation.
- The binary is not stripped (no `-s -w`). `govulncheck -mode=binary` needs the symbol
  table to see which packages are linked. On a stripped binary it compares whole modules
  and reports the `openpgp` advisory of `x/crypto` (GO-2026-5932), which has no fix and
  which hasalad does not use.
- `doCheck` is off. The tests need a Postgres cluster, bun and the conformance fixtures
  outside `server/`. `scripts/check.sh` is the gate that runs them.

Applies to: `flake.nix` (`packages.hasalad`).

## The QA host runs the PostgreSQL and the cloudflared that the checks use

`nixosModules.hasala` takes its packages from the `packages.<system>` of this flake. Thus a
host runs exactly the closure that the Hasala CI built, whatever nixpkgs the host follows.

- `packages.postgresql` is the same PostgreSQL that the devShell gives to the test
  clusters (spec 05 §4.2). The tests and the QA host run one major and one minor. Change
  the two together.
- `packages.cloudflared` is the cloudflared of the pinned nixpkgs, built with the pinned
  Go (spec 05 §4.2, R-09). The ingress lint and the host run this same binary. It is the
  only process on the QA host that faces the internet. Releases before 2026.10.2 trust
  eight eMudhra (emSign) intermediates that have weak private keys (Cloudflare advisory,
  2026-10-20). The assertion on the version must stay.

Applies to: `flake.nix` (`packages.postgresql`, `packages.cloudflared`),
`infra/qa/nix/module.nix`.

## The devShell has no C compiler

The devShell is `mkShellNoCC`. On darwin, a shell with the cc-wrapper exports `SDKROOT` and
`DEVELOPER_DIR` with paths in the Nix store, and the toolchain of Xcode then fails.
Nothing in the repository needs cgo (`CGO_ENABLED=0`), so Linux has no C compiler too.

Applies to: `flake.nix` (`devShells.default`).

## The devShell carries Node and libstdc++ for the website tools

- Node is in the devShell for wrangler. wrangler is not reliable on the Bun runtime.
  `bun run deploy` starts the wrangler bin through its `#!/usr/bin/env node` line, and
  that line finds this Node.
- On Linux the devShell sets `LD_LIBRARY_PATH` to libstdc++. `bun run build` uses sharp,
  and its prebuilt libvips needs libstdc++. NixOS has no libstdc++ on the default search
  path. The darwin shell does not get this variable.

Applies to: `flake.nix` (`devShells.default`).

## The tunnel reaches only the API, on an allowlist of paths

The tunnel is the only public ingress of the QA host (spec 05 §7.3, §7.4). Its
configuration routes one thing: the API host name, on the API path allowlist, to the API
port on the literal loopback address. cloudflared answers 404 to all other requests.

- The allowlist is the API (`/api/v1/`), the Gmail Pub/Sub hook and the two Graph hooks.
  cloudflared compares the regex with the URL path only, not with the query. There is no
  bare `/healthz`: the health route is `/api/v1/healthz`.
- The console (spec 07, M16) and each metrics port must not be reachable through the
  tunnel. The lint refuses a service on these ports: 9471 (kept for a metrics listener of `hasalad serve`, which does not exist yet), 9472
  (cloudflared metrics), 8472 and 9473 (the console and its metrics), and the ports of
  known neighbours: 5432 (Postgres), 9090 (Prometheus), 3000 (Grafana), 2586 (ntfy).
- The log level is `info`. At `debug`, cloudflared logs request paths, and the paths carry
  credential ids.

A wider rule here publishes the console or a metrics port to the internet.

Applies to: `infra/qa/cloudflared/lint.sh`, `infra/qa/nix/ingress.nix` (`apiPath`).

## The tunnel configuration is written by hand and compared with a golden file

`ingress.nix` writes the YAML of the tunnel as text. It does not use a YAML generator. The
bytes then stay the same when nixpkgs changes, and each change of them shows as a diff of
`infra/qa/cloudflared/config.golden.yml` in review.

Applies to: `infra/qa/nix/ingress.nix`.

## Infra creates the roles; the migrations give the grants

`infra/qa/db/setup.sql` creates only the roles, the database and the ownership of the
schema (spec 05 §5.3.5). It runs as the bootstrap superuser on each start and is
idempotent. The grants on tables and sequences and the default privileges of
`hasala_runtime` belong to the baseline migration, which runs as `hasala_migrate`. Do not
add a table grant to `setup.sql`: a second place for grants lets the two disagree.

Applies to: `infra/qa/db/setup.sql`.

## hasala_backup may hold four connections

The connection limit of `hasala_backup` is 4. Spec 05 §5.3.5 says 2, and 2 is too low.
`hasalad migrate --pending` (the check before the pre-migration dump, as `hasala_backup`)
opens a pgx pool that starts two idle connections and dials a third for its first query.
A daily `pg_dump` can run at the same time. The limit is set on each run, so a cluster
that exists gets it too. With a lower limit, the pre-migration check fails, and then
`hasalad` does not start.

Applies to: `infra/qa/db/setup.sql`.

## The database uses the builtin collation provider

The cluster and the database use the builtin collation provider of PostgreSQL 17 (`C` and
`C.UTF-8`). The sort order then does not depend on glibc. With a glibc collation, a new
glibc from nixpkgs can change the order and damage the indexes on text.

Applies to: `infra/qa/db/setup.sql`, `infra/qa/nix/module.nix` (`hasala-postgresql`).

## Secrets reach a unit only as credential files

- A secret option is an absolute path as a string, not `types.path` (spec 05 §5.1, M22,
  review 2 F-22). A Nix path literal copies the file into the Nix store, which all users
  can read. The string type makes a path literal a type error, and M22 refuses a string
  that is in the store.
- Each secret reaches exactly one unit through `LoadCredential=`. The process gets a
  `*_FILE` path into its credentials directory. No secret is in `Environment=`.
- A unit that holds a key makes no core dump (`LimitCORE=0`, spec 05 §5.2).

Applies to: `infra/qa/nix/module.nix` (`secretPath`, `hardening`, `fixedEnv`).

## The console and the API share no credential

`hasalad serve` and `hasalad console` are two units with two OS users (spec 05 §5.13,
spec 07 §14.1, fence F7-4, M20). The console gets none of the secrets of `serve` (the auth
key, the email token, the APNs key, the route key, the Turnstile secret). The console has
no secret of its own now: the App Store Connect key that spec 07 planned for it is not
built (`docs/decisions/testflight-manual.md`). `serve` still gets no console, App Store
Connect or TestFlight variable (M20). Each unit also has the credentials directory of the
other in `InaccessiblePaths`.

The console gets `HASALA_RP_ORIGINS`, although the table of spec 07 §14.1 does not have
it. The shared configuration check of the server refuses `HASALA_RP_ID` without
`HASALA_RP_ORIGINS` in all modes. Without it, the console does not start.

Applies to: `infra/qa/nix/module.nix` (`consoleEnv`, `systemd.services.hasalad`,
`systemd.services.hasala-console`).

## Only the tailnet-gated nginx virtual host reaches the console

A kernel rule lets only one OS user (`console.restrictToUser`, the nginx of the host) open
a TCP connection to the console port on loopback. Each other local process, root included,
gets a reset. The rule filters only packets that the host makes for that one port, and it
opens nothing. An ip6tables rule does the same for `::1` (spec 05 §5.14, review 2 F-11).
The console listens only on 127.0.0.1, so the IPv6 rule is defence in depth. The metrics
port has no rule, because it serves no console route.

nginx is thus the one way to the console, so assertion M19 examines each nginx virtual
host. A virtual host "reaches the console" when its proxy text names the console port on
any host spelling (`127.0.0.1`, `localhost`, `[::1]`), or names an upstream that does.
Each such virtual host must be the one behind the tailnet gate. A second virtual host
that is not gated publishes the operator console to the LAN.

Applies to: `infra/qa/nix/module.nix` (`namesConsolePort`, assertion M19,
`networking.firewall.extraCommands`).

## A PostgreSQL major change never starts an empty cluster

The data directory has the major version in its name. When a build with a new major
starts and a directory of an older major exists, `hasala-postgresql` stops with an error.
It starts an empty cluster only after the operator writes the new major to
`ALLOW_MAJOR_CHANGE`, for the dump and restore. Without this guard, a new major of the
PostgreSQL package starts an empty database with no error.

Applies to: `infra/qa/nix/module.nix` (`systemd.services.hasala-postgresql`).

## Migrations run before every start of the server

`hasala-migrate` is a oneshot with no `RemainAfterExit` (spec 05 §5.4). Each start of
`hasalad` or of the console thus starts a new run of the migrations first, as the schema
owner. With `RemainAfterExit`, the unit stays active after its first run, and a restart
with a new binary does not migrate.

Applies to: `infra/qa/nix/module.nix` (`systemd.services.hasala-migrate`).

## A missing backup disk stops the start

`hasala-backup-premigrate` makes an encrypted dump before a migration that has work to do
(spec 05 §5.4). `hasala-migrate` requires it. A failed dump fails the migration, so a new
binary does not start on a schema change that has no backup.

Each backup unit has `RequiresMountsFor` on the backup directory. A backup disk that is
not mounted is a failure. It must not become an empty directory on `/` that looks new or
clean. For the pre-migration unit this has a cost that the owner accepted: with no backup
disk, `hasalad` and the console do not start, also when no migration is pending. The unit
cannot know that before systemd resolves the mount. To fail closed, with an alert, is
better than a migration with no backup. To start without the disk, mount it or set
`backup.enable = false`.

Applies to: `infra/qa/nix/module.nix` (`hasala-backup-premigrate` and the other backup
units).

## PostgreSQL logs no statement, no parameter and no row

Nothing can make the PostgreSQL of Hasala write a statement, a parameter or a failing row
to its log (spec 05 §5.3.2, security C7). `log_statement` is `none`,
`log_min_error_statement` is `panic`, the parameter lengths are 0 and
`log_error_verbosity` is `terse`. `terse` removes DETAIL: the DETAIL of a CHECK violation
prints the full failing row, which can be a plaintext blob that the server refused.

A host cannot change these keys through `database.settings` (M9). The forbidden keys are
the socket, the auth files and each `log_*` key.

Applies to: `infra/qa/nix/postgresql.nix` (`forbiddenSetting`, the settings).

## Warnings become errors through a build setting, not the command line

A build makes warnings errors for the app targets with `HASALA_WARNINGS_AS_ERRORS=YES`
(spec 04 §1.3). Do not put `SWIFT_TREAT_WARNINGS_AS_ERRORS` on the `xcodebuild` command
line. A command-line setting also reaches the package dependencies (GRDB,
swift-collections). SwiftPM builds them with `-suppress-warnings`, and the two flags
conflict. At this time no script in the repository passes `HASALA_WARNINGS_AS_ERRORS`.

Applies to: `ios/Config/Shared.xcconfig`, `ios/Config/Widgets.xcconfig`.

## HasalaMocks leaves the link by its object file name

XcodeGen and Xcode cannot link a package product for one configuration only. Thus
`ios/project.yml` links HasalaMocks in all configurations, and `Shared.xcconfig` sets
`EXCLUDED_SOURCE_FILE_NAMES = HasalaMocks.o`. Xcode links a static package product as one
object file with that name, and it drops a file of the Frameworks phase whose name agrees
with this setting. `Debug.xcconfig` sets the value to empty, so only Debug links the mock
(spec 04 §1.4, AT-REV-4).

This depends on how Xcode names the object file. If a new Xcode changes it, Release links
the mock data. The inspection of `archive.sh` (AT-REV-4) then refuses the .ipa, because
its binary names HasalaMocks.

Applies to: `ios/Config/Shared.xcconfig`, `ios/Config/Debug.xcconfig`.

## The build settings hold only public identifiers, and no redirect scheme is registered

Nothing in `ios/Config/` is a secret. The team id, the bundle id and the topic name are
public. The Google iOS OAuth client and the Entra app (personal Microsoft accounts only)
are public clients: their ids are in each binary and they have no secret. The server must
have the same Entra client id in its `[outlook]` group, or the link fails. The value
`unset` stops the offer of Outlook.

The OAuth redirect schemes (the reversed Google client id, and `msauth.app.hasala.ios`)
are not in `CFBundleURLTypes`, on purpose (spec 06 DV-2). `ASWebAuthenticationSession`
gets the redirect itself, so the app registers no URL scheme. `inspect-ipa.sh` check I4
refuses an .ipa that registers a URL type.

The Pub/Sub topic stays `unset` in the build. The app gets the watch topic from the server
(`gmail_watch_topic` in `GET /meta`) and does not call `users.watch` while the topic is
absent. Thus the build does not publish the cloud project id.

Applies to: `ios/Config/Shared.xcconfig`.

## Background task handlers are registered before launch ends

`HasalaApp.init` registers the `BGTaskScheduler` handlers (spec 04 §7.9). iOS requires the
registration before the launch ends. `Info.plist` lists the two task identifiers, and a
task that fires with no handler stops the app with a crash. Thus the registration cannot
wait for an account. Only the work of the handlers is installed later, when an account
opens (`BootController`).

Applies to: `ios/Hasala/App/HasalaApp.swift`.

## One live graph for each process

SwiftUI evaluates the initial value of a `@State` property on each `init` of the view, not
only one time. `LiveRootView` uses `AppGraph.live()` as such a value, and `AppDelegate`
calls it too. Thus `AppGraph.live()` must return the one graph of the process and make it
only on first use. If it makes a new graph for each call, the app gets more than one boot
controller.

Applies to: `ios/Hasala/App/RootView.swift` (`LiveRootView`),
`ios/Hasala/Live/Runtime/BootController.swift` (`AppGraph`).
