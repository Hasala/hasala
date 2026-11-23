# The gate scripts and the hasalad command: decisions from the code (2026-11-21)

These decisions were code comments under `scripts`, `server/cmd/hasalad` and
`server/internal/accounts`. Code comments are not permitted
(`scripts/comment-lint.ts`), thus the decisions are here.

## The gate uses eight Go jobs and does not run the corpus gates

`CHECK_JOBS` sets how many packages `go vet` and `go test` build and run at one time.
The default is 8. The QA host also runs other services, and 8 keeps the gate to about
half of that machine. Do not raise the default. A higher value makes the other services
of the host slow while the gate runs.

The gate does not run the full-corpus diff between the executors, and it does not run
the corpus-equivalence gate. The two need a snapshot of the v1 mailbox of the operator
(`HASALA_CORPUS_DB`, which only `server/oracle` reads). No checkout has this snapshot,
and these tests skip without it. A pass of the gate does not prove these two properties.

Applies to: `scripts/check.sh` (`JOBS`).

## The conformance step reads the record of the Go test step

The gate runs the Go tests one time. The `go test` step writes its `go test -json`
stream to a file (one for `server/`, one for `server/oracle/`). The conformance step
does not run the conformance packages again. That second run was the slowest part of
the step and gave the same result against the same Postgres cluster. Instead,
`go test -list` names each test of each package in the `CONFORMANCE` table, and
`scripts/gotest-ran.ts` fails unless each package passed in the record and each listed
test has a result there. A result is a pass, or a skip of a real-corpus test or of a
`TestWrite*` fixture writer that is switched off.

These rules keep the proof correct:

- The `go test` step must run each test as a run of its own does. Its only flags are
  `-count=1` and the `-skip` of the known failures. A flag that makes tests skip
  themselves (for example `-short`) passes unseen.
- `-count=1` stays. A pass from the test cache is the result of an older Postgres
  cluster, not of this run.
- `go test -list` names only top-level tests, fuzz tests and examples. It does not name
  subtests. Thus a `KNOWN_FAILING` pattern must not contain `/`, and the gate refuses
  one that does. A skipped subtest has no line in the list and nothing can see that it
  did not run.
- `go test -list` also names benchmarks, but `go test` does not run them.
  `gotest-ran.ts` does not count them.
- A package with no listed test fails. A package that the `go test` step left out
  fails. A test that a `-run`, a `-skip` or a `KNOWN_FAILING` pattern removed fails.

The `CONFORMANCE` table is the record of which Go tests make each contract. The sets
`authres`, `categorize`, `extract`, `fx`, `merchant-group`, `norm-dates`,
`outlook-sender`, `replay` and `sms-extract` have no Go package on purpose: the server
never reads mail and never folds ops, thus Go has no reader for them. The Swift
executor writes the `swift` set, and Go does not read it. Spec 01 §15.2 step 2 plans a
Go reader for the crypto half of that set. Go writes `crypto-v3` and `api-v1`
(`cmd/gen-crypto-vectors`, spec 01 §15.1, spec 02 §22), and Swift only reads them.

Applies to: `scripts/check.sh` (`GO_RECORD`, `ORACLE_RECORD`, `GO_LIST`, `CONFORMANCE`),
`scripts/gotest-ran.ts`.

## A known failure must run and still fail

A `KNOWN_FAILING` entry is for a test that fails for a reason that a change cannot
correct. The gate skips it by name in the `go test` step, then runs it alone. In that
run the test must report `--- FAIL:` and must print the recorded failure text. A build
error is not a known failure: the test did not run, thus the gate fails. A pass also
fails the gate, until somebody removes the entry. Thus no healthy test stays skipped.

`go test -skip` applies its pattern in each package. Each name in the table must be
unique in the two modules, or the pattern skips a second test.

The one entry is `TestSelectMonthlyTotals` in `server/oracle/v1ref/store`. The test
puts rows in June 2026 and asks for the totals of the last 3 months, counted from the
clock. June 2026 left that window on 2026-09-01, thus the test fails on each machine
from that date. `server/oracle/v1ref` is reference code whose bytes must not change,
thus nobody corrects the test. Do not correct it and do not delete it.

Applies to: `scripts/check.sh` (`KNOWN_FAILING`).

## The Postgres boot output is captured before it is evaluated

The gate starts one temporary Postgres cluster. The boot command prints shell
assignments (`HASALA_TEST_POSTGRES_URL`, `PG_STOP`). The gate puts this output in a
variable, examines the exit status, and only then runs `eval` on it.

Do not change this to `eval "$(go run ...)"`. When the boot fails, its output is empty,
`eval ""` succeeds, and the failure is lost. Then each test package starts its own
cluster with no message, and the gate is slow and does not use the one cluster that
its cleanup stops.

Applies to: `scripts/check.sh` (`BOOT_OUT`).

## The test summary fails an empty run and lists each skip

`scripts/gotest-summary.ts` exits 1 when a test or a package failed. It also exits 1
when no test ran at all. A run that collected nothing must not look like a pass.

It prints each skipped test with its reason on each run. It does not only count them.
A test that skips because its fixture moved looks the same as a pass in a count.

A test that needs the private real-mail fixtures writes `[real-corpus]` in its output:
in a log line when it runs, and in its skip reason when `HASALA_PRIVATE_FIXTURES` is
not set. The summary counts these tests apart from the others and writes
`<ran> <skipped>` to the file that `REALCORPUS_COUNTS` names. The closing lines of the
gate use this count. Do not remove the marker from a real-corpus test. Without it, a
run with no private fixtures looks like the full gate.

Applies to: `scripts/gotest-summary.ts`, `scripts/check.sh`,
`server/internal/privatefixtures`.

## The fixtures lock publishes only digests

`private-fixtures.lock` is public. It holds the commit of the private fixtures
repository and one SHA-256 for each fixture file. `README.md` and `.gitignore` are not
fixtures and have no digest.

A digest of a whole message is safe to publish: it identifies the file and does not
show its content. Three small expectation files (`deploy-expect.json`, `tamper.json`,
`exit-expect.json`) hold values with low entropy. Their digests cannot be guessed only
because each file also has a long free-text note that is never published. Keep those
notes. Do not copy text from these files into this repository. Without the note,
somebody can find the private values from the public digest by trial.

`check` fails when a pinned file is missing or different, and when the checkout has a
fixture that the lock does not name. Thus an old, partial or edited checkout cannot
pass as the real corpus. A different commit with the same files is only reported (for
example a change of the README). `write` accepts only a clean git checkout with a
commit, because the lock names a commit.

Applies to: `scripts/private-fixtures-lock.sh`, `private-fixtures.lock`.

## The server pins the id of each server key

At the first start with the server keys, `hasalad serve` records the id of the salt key
and of the current auth key in `server_meta` (spec 02 O9, spec 01 D41). At each later
start it refuses to start when a loaded key has a different id. With the auth key
alone, it pins only the auth key id.

The reason: a wrong salt key gives no error by itself. Each password check fails, and
each sign-in looks like a wrong password. The refusal at start makes the wrong key
file visible to the operator. Do not remove the check, and do not replace the stored
id when it differs. A planned key change must be a different, explicit operation.

Applies to: `server/cmd/hasalad/accounts.go` (`checkKeyIDs`, `pinKeyID`),
`server/cmd/hasalad/wire.go` (`wireExtras`).

## Two third-party imports are tolerated by the build-graph fence

The fences of spec 02 §4.4 keep `golang.org/x/text` and `golang.org/x/crypto` out of
hasalad (fences 1 and 5). Two edges are tolerated by name, and only these two:

- `github.com/jackc/pgx/v5/pgconn` imports `golang.org/x/text/secure/precis` (SASLprep
  for SCRAM). hasalad authenticates to Postgres with peer auth and does not use SCRAM,
  but the package is linked.
- `github.com/go-webauthn/x/revoke` imports `golang.org/x/crypto/ocsp` (the attestation
  metadata path of go-webauthn). Thus `x/crypto` stays in `go.mod` as an indirect
  requirement.

This is an accepted deviation from fences 1 and 5. No package of the server module may
import one of these two packages, directly or through a different edge. Do not add a
third tolerated edge to make a new dependency pass. A new edge can bring encryption
code into a server that must stay blind.

Applies to: `server/cmd/hasalad/fence_test.go` (`TestFenceTheBuildGraph`,
`TestFenceGoMod`).

## Operator modes hold no auth key and send no mail

The operator modes of hasalad (`invite`, `purge-user`, `email test` and the others) run
with no auth key, no mail token and no network (spec 05 §5.7). Only `hasalad serve`
holds these.

The results:

- `invite mint --email` only queues a row, with no email tag. The mail worker in
  `serve` adds the tag, mints the code at send time and sends the mail. The CLI never
  shows that code.
- `invite mint` with no address prints its code one time. The database keeps only a
  hash.
- `purge-user` skips the steps that need a tag made from the auth key. It queues the
  goodbye email as the API does, and the worker in `serve` sends it (spec 02 §15.4).

Do not give an operator mode the auth key or the mail token, and do not make it send
mail. These modes run as the operator, and the units that run them have no network.

Applies to: `server/cmd/hasalad/invite.go` (`runInvite`),
`server/cmd/hasalad/purge.go` (`runPurgeUser`).

## An admin audit row carries no address, name or code

Each operator action that changes state writes one `admin_audit` row (spec 07 §2.9,
§8.6), with the actor `cli:<operator>`. The `params` of a row must not contain an email
address, a name or an invite code. They contain only internal ids, flags and counts.

The code does not examine `params`, thus each caller must obey the rule. An account
deletion does not erase the audit log: the purge leaves `admin_audit` alone, because
the log has only internal ids and actions. A trigger keeps the log append-only for
400 days. An address or a code in a row thus stays there after the person left.

Applies to: `server/cmd/hasalad/invite.go` (`audit`).

## The loopback check runs again before the listener opens

`hasalad serve` refuses a listen address that is not loopback. The configuration
loader makes this check. `runServe` makes it a second time, immediately before
`net.Listen`.

The second check is not a duplicate to remove. A `Config` that code builds (not the
loader) does not go through the first check. hasalad has no TLS code, thus a listener
on a different address gives plain HTTP to the network.

Applies to: `server/cmd/hasalad/serve.go` (`runServe`).

## The disk fuse takes its first sample before the first request

`startHeadroom` starts the disk fuse before the listener opens. `Start` takes its first
sample in the calling goroutine. Thus the fuse knows the free space of the database
filesystem before the first request arrives. Below the floor the server refuses each
durable write, sign-in included, and continues to serve reads.

Do not move the first sample to a background goroutine, and do not start the fuse
after the listener. Then the first requests can write to a disk that is already below
the floor.

Applies to: `server/cmd/hasalad/serve.go` (`startHeadroom`).

## A sweep continues after a failure and completes after a stop signal

A sweep runs one time at start and then at its interval (spec 02 §9.7).

A sweep that fails writes a log line, and the loop continues. One failure is usually a
short database problem. If the loop stopped, all later sweeps stopped with no message,
and expired data stayed.

Each run gets a context that the stop signal does not cancel
(`context.WithoutCancel`), with its own limit of 5 minutes. A stop signal in the middle
of a sweep thus does not abort its transaction. The loop ends after that run. Do not
give the run the context of the server.

Applies to: `server/cmd/hasalad/serve.go` (`startSweep`, `startSweepEvery`).

## Without the email group the website routes are not mounted

When the `[email]` group is not configured, the sender is `mail.Unconfigured` and each
send fails permanently. A queued email then ends as `failed` in the mail log, not as
`sent`. The worker runs when the auth key is there.

In this state `serve` does not mount the waitlist routes of the website (spec 02
§14.4, spec 07 §6). A sign-up whose confirmation email can never arrive is worse than
no form. Do not mount these routes without a sender that operates.

Applies to: `server/cmd/hasalad/wire.go` (`wireExtras`, `newSender`).

## The email tag is the same with one server key or two

With the two server key files (spec 01 §4.11), `serve` mounts the account ceremonies,
and the key set makes the email tag. With the auth key alone, `serve` mounts no
account ceremony, but the waitlist and the mail queue get their email tag from an
email tagger made from that key.

The two paths derive `K_tag` from the auth key in the same way, thus a tag made with
one key file agrees with a tag made after the salt key was added. Keep the two
derivations the same. If they differ, a row that was tagged before no longer agrees
with a new tag for the same address, and the server does not find it.

Applies to: `server/cmd/hasalad/wire.go` (`wireExtras`), `server/internal/authkeys`
(`NewEmailTagger`).

## Each Google token verifier has its own audience

The server has two Google token verifiers. The mailbox link verifies the ID token of
the app, and its audience is the iOS client id. The Pub/Sub hook verifies the token of
Pub/Sub, and its audience is the push URL.

`TestWireExtrasFollowsTheConfiguration` asserts the audience of each verifier in the
real wiring. Do not remove this assertion. The API tests use a fake verifier, thus
they all pass when the two audiences are exchanged. With exchanged audiences, a token
that Google made for one purpose is accepted for the other.

Applies to: `server/cmd/hasalad/wire.go` (`wireGmail`),
`server/cmd/hasalad/wire_test.go`.

## The review flag changes only what the account route reports

The review flag marks an account whose data is the sample that a Beta App Review
reviewer can load (spec 02 §14.2, §18.3). A review account is an ordinary account. The
flag changes what `GET /api/v1/account` reports, and nothing that the server does: no
check is skipped and no limit is lifted.

Fence 6 of spec 02 (`server/cmd/hasalad/fence_test.go`) lets only a small set of
packages read or write the flag: `internal/accounts`, `internal/console`,
`internal/invites`, the signup file of `internal/auth` and the account file of
`internal/api`. Do not read the flag in other server code, and do not make a server
decision from it. That is a review bypass.

Applies to: `server/internal/accounts/accounts.go` (`SetReview`, `Review`).
