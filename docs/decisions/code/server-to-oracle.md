# Verify, the waitlist and the oracle tools: decisions from the code (2026-11-21)

These decisions were code comments under `server/internal/verify`,
`server/internal/waitlist` and `server/oracle`. Code comments are not permitted
(`scripts/comment-lint.ts`), thus the decisions are here.

## The usage audit counts the padded stored bytes, reads no content and never repairs

`hasalad verify usage` compares the usage ledger of each account (`account_usage`) with
the bytes that the op log stores (spec 02 §18.3). Admission compares a write with this
ledger (`internal/budget`). Nobody reads the number, thus a wrong value shows nowhere. A
ledger that is too high refuses writes that an honest account was permitted to make. A
ledger that is too low gives an account budget that it already used. Drift is the known
failure of accounting in application code, so the ledger ships together with this check
(account isolation design, P1, ledgerd design archive). A finding gives the two numbers
and says which direction the ledger is wrong.

The audit obeys three rules:

- It counts `octet_length(blob)`: the framed and padded bytes in the column. The appender
  charges the same quantity. A comparison with a plaintext length reports the padding as
  drift on each account of a healthy database.
- It reads no content. Postgres answers `octet_length()` of a `bytea` from the length
  header of the stored value. It does not fetch, decompress or open a blob. Thus the
  audit can run on the data of real people.
- The report never writes. `hasalad verify` does not apply migrations and does not change
  the database that it measures. A check that corrects the ledger on each run removes the
  evidence of the bug that it must find: a ledger that heals itself each night looks the
  same as a correct ledger. The repair is a different operation that an operator types
  (`hasalad verify usage --repair`). No report calls it. A scheduled run reports, and it
  fails loudly.

Some drift is expected. Migrations are applied before the new binary starts. A binary
that does not charge a write path can write between the migration and the restart. The
first audit after such a deployment finds that drift, and the operator repairs it.

Applies to: `server/internal/verify/usage.go` (`UsageLedger`, `UsageLedgerFor`,
`RepairUsageLedger`), `server/cmd/hasalad/verify.go`.

## An empty account list means all accounts in the usage audit

In Postgres, `cardinality(NULL)` is NULL. The scope clause of the usage queries puts it
in `coalesce(..., 0)`, so a nil list and an empty list both select all accounts. Without
the `coalesce`, a nil list selects no rows. The audit then reports nothing, and a report
of nothing reads as a healthy database.

Applies to: `server/internal/verify/usage.go` (`usageScope`).

## The usage drift query is one statement with a FULL JOIN

The query computes the stored total and compares it with the ledger in one statement.

- One statement. An append writes its op row and its ledger increment in one transaction,
  so the two agree only in one snapshot. Two statements are two snapshots. A healthy
  append that commits between them shows as drift of its own size. The busiest accounts
  then get false findings, and nobody trusts the check.
- A FULL JOIN. A ledger row with no stored bytes (the data went away below it) is drift.
  Stored bytes with no ledger row (a write path that did not charge them) are also drift.
  A join in one direction drops one of the two. A zero row and an absent row are the same
  only when the account stores nothing, and such an account gives no finding.
- The resource name is made in SQL from the stream name (`'oplog_' || stream ||
  '_bytes'`). `TestTheReconciledResourceNamesAreTheLedgersOwn` compares that spelling
  with the constants of `internal/budget`. A wrong spelling reports the full log of each
  account as drift, and a repair then writes a second row.

Applies to: `server/internal/verify/usage.go` (`usageDriftSQL`),
`server/internal/verify/usage_test.go`.

## The usage repair writes only a closed set of resources

`RepairUsageLedger` writes only the resources in `repairable`. The column
`account_usage.resource` has a CHECK, and an INSERT of a different resource aborts the
repair transaction. A resource outside the set can come only from a stream that the
constraint of the op log does not permit. That is a finding for the operator to read. It
is not a row to write. When the ledger gets a new resource, add it to the CHECK, to
`repairable` and to `usageTruth` together.

Applies to: `server/internal/verify/usage.go` (`repairable`, `RepairUsageLedger`,
`usageTruth`).

## The usage repair locks one row in each transaction, then recomputes

- The lock comes first. The repair locks the ledger row `FOR UPDATE` and then computes
  the stored total in the same transaction. The total includes each append that committed
  before the lock, and each later append waits for the lock. Thus the written value is
  exact while the service runs. A total that is computed before the lock is only a
  snapshot.
- One row in each transaction. `budget.Admit` locks all rows of a resource family in one
  statement. A repair that holds two rows of a family can take them in the opposite
  order, and that is a deadlock. A transaction that holds one lock cannot be part of a
  cycle.
- The row can be absent. A write path that did not charge its bytes leaves no row, and an
  absent row is correct only when the account stores nothing. The repair makes the row
  first (`ON CONFLICT DO NOTHING`) and then locks it.
- A row that is correct when its turn comes is not written and not reported. An append
  that corrected it after the survey is the ledger at work. A repair that writes correct
  rows changes `account_usage` on each run and reports a correction where nothing was
  wrong. The report of a repair then has no meaning.

Applies to: `server/internal/verify/usage.go` (`RepairUsageLedger`, `repairOne`,
`usageTruth`).

## The usage repair does not make a row for a purged account

The usage rows of an account go away with the account (cascade). When an account is
purged between the survey and its repair, the insert of its row fails on the foreign key
(`23503`). The repair skips that account and reports no error.

- Do not make the row again. It is a record of how much a deleted person stored.
- Do not fail the run. One deletion then stops the repair of every other account.

Applies to: `server/internal/verify/usage.go` (`repairOne`),
`server/internal/verify/usage_test.go`
(`TestRepairSkipsAnAccountThatWasPurgedMidRun`).

## Verify reads no content, and a finding names only a position

Each blob is ciphertext that the server cannot open, and `hasalad verify` does not try.
`Structural` hashes the stored bytes and reads only the cleartext framing (the v3 header:
the key epoch and the AAD). The `Detail` of a finding is for an operator with a `psql`
session. It gives the position that the row claims (seq, writer, counter) and the name of
the check that failed. It never gives a value that came from a blob.

The AAD check is the case that matters. On a malformed blob, the bytes at the place of
the AAD can be any bytes of a person's data. A finding that shows them puts them in an
operator log. Thus `checkAAD` says only that the framing and the row disagree. Do not add
a blob value to `Detail`.

Applies to: `server/internal/verify/verify.go` (`Finding`, `checkSealed`, `checkAAD`).

## The seq counter is a locked row, so S1 and S5 are exact

The seq counter of an account (`oplog_seq`) is a locked row. It is not a Postgres
sequence. A rolled-back append gives its value back, and no production path deletes an
op row. Thus two checks are exact equalities with no tolerance:

- S1: `count(*) == max(seq)` and `min(seq) == 1`. The seq space has no holes.
- S5: `oplog_seq.next_seq == max(seq) + 1`.

S5 is the only check that sees a log whose tail is gone, or a log that is fully deleted.
S1 looks for holes between the rows that remain. Rows 1 to N-1 are dense, and an empty
log has nothing to compare. A restore from a short backup gives the first case, and a bad
repair gives the second. These are the most probable real losses.

If the counter becomes a sequence, or a production path starts to delete op rows, the
equalities need a tolerance, and a truncated tail goes through that tolerance.

S5 reads the counter and `max(seq)` in one statement. An append updates the counter row
in its own transaction. Two statements are two snapshots, and an append that commits
between them shows an old counter with a new head. That is a false finding on the busiest
accounts.

Applies to: `server/internal/verify/verify.go` (`S1SeqDense`, `S5CounterMatchesHead`,
`structuralUser`).

## The chain check recomputes each hash, reads a stream in seq order and resynchronizes

- S2 computes `SHA256(blob_hash[n-1] ‖ blob[n])` from the stored bytes and compares it
  with the stored `blob_hash` (spec 01 §7). It does not accept the hash column as the
  truth. Thus an operator who changes a blob cannot keep the chain correct with a change
  to the hash column of that row only.
- The check reads one stream in seq order. Seq order is commit order, and the counters of
  a chain only increase. Thus each (writer, stream) chain comes in counter order, and one
  pass examines all chains of the stream without the full log in memory. Each writer has
  its own chain, because the rows of two devices alternate by seq.
- After a finding, the check continues from the stored counter and the stored hash.
  Without this step, one changed blob gives a finding on each later row. The operator
  then cannot tell one edit from a full rewrite, and that is the difference between a
  restore and an investigation.

Applies to: `server/internal/verify/verify.go` (`structuralStream`, `checkChain`).

## Verify repeats the checks that database constraints make

Some checks cannot fail on a database with its constraints: S6 (`blob.LooksSealed`, spec
01 §8.1) repeats the CHECK `op_log_blob_is_sealed`, and the hash length repeats
`op_log_hashes_are_sha256`. Verify keeps them. On a stored hash of the wrong length it
continues from the zero hash and does not panic.

The reason: the tool is for a damaged database. A restore into a schema that somebody
made by hand has no constraints, and that is the database an operator points this tool
at. Do not remove a check because a constraint already makes it.

Applies to: `server/internal/verify/verify.go` (`S6Sealed`, `checkSealed`,
`checkChain`).

## A verify run is bounded, and its output has a stable order

- A page of rows ends at 512 rows or at 8 MiB (`pageRows`, `pageBytes`). One blob can be
  a megabyte, so a row count alone does not limit memory. Without the byte limit, a
  verify of a large account can use all the memory of the operator's machine.
- A run stops after 2000 findings (`maxFindings`) and adds a `truncated` finding. A
  restore from a truncated backup can break each chain of each account, and nobody reads
  a report of a million lines.
- Structural findings are in order of account, then seq. Usage findings are in order of
  account, then resource. Two runs on an unchanged database give the same bytes, so a
  diff of two runs shows only real changes.

Applies to: `server/internal/verify/verify.go` (`pageRows`, `pageBytes`, `maxFindings`,
`StructuralFor`), `server/internal/verify/usage.go` (`UsageLedgerFor`).

## A waitlist leave link gives one answer for each well-formed token

`Leave` (spec 07 §5.5) gives the same result for each token of the correct shape: a live
token, an expired token, a used token and a token that never existed. It returns an error
only for a cause that is not the token (a malformed request, a database fault). A
different answer for a live token tells a caller which tokens exist.

Applies to: `server/internal/waitlist/waitlist.go` (`Leave`),
`server/internal/api/routes_waitlist.go`.

## The has-account mail uses a name only for an address that an account verified

The `waitlist_has_account` mail greets a person by name only when an account has verified
the address that gets the mail (spec 07 §6.2, review 2 F-18). The renderer reads the
display name of the account whose `email_norm` is the recipient. Each other case gets
"Hi,". A name in a mail to an address that no account proved gives a person's name to
somebody else.

Applies to: `server/internal/waitlist/waitlist.go` (`Register`).

## The dictionary export drops nothing silently, and its CSV is not committed

`export-dictionary` writes the v1 categorization rules of the operator as the CSV that
the dictionary generator of the app reads (`ios/tools/dictionary`; spec 02 §2.3 and §4.3,
spec 03c §8.5). The dictionary ships in the app, not on the server.

- `corpus.Rules` returns inactive rules and duplicates. It does not filter them and does
  not merge them. The export counts them in its report, and the numbers of the report add
  to the number of rules read. A count that does not add is a silent drop.
- The export reports each rule that it cannot use (a regex, a pattern out of range) and
  each conflict (one pattern with two categories) on stderr, and exits 1.
- All rows of a conflict go into the CSV. The choice between them is the operator's. The
  generator refuses a duplicate (match, pattern), so the operator must edit the CSV
  before the build.
- The rows are in order of match, then pattern. Two exports of one snapshot have the same
  bytes.
- The export reads the rules through the `corpus` package, not through its own
  `sql.Open`. Thus it gets the refusal of the live database (the next section). A person
  runs this command by hand, and that is when a tool gets the path of the live directory.
- The CSV is operator data. Do not commit it to this repository.

Applies to: `server/oracle/cmd/export-dictionary/main.go`,
`server/oracle/corpus/corpus.go` (`Rule`, `Rules`).

## The corpus reader refuses the live v1 database and keeps each message byte-exact

The `corpus` package reads a copy of the v1 ledger database. That database holds the
byte-exact RFC822 of the mail that v1 received, and it is the only source of real bank
mail with DKIM and ARC signatures for the oracle gates.

- `Open` refuses each path below `/var/lib/ledger` (`ErrLiveDatabase`). It also examines
  the absolute path and the target of a symlink. A reader of the database file of a
  running service takes locks and reads pages that a writer can change, also with
  `mode=ro`, and a corrupt production database cannot be recovered. The permitted source
  is a `.backup` snapshot that root makes. `HASALA_CORPUS_DB` gives its path. No test
  opens the live database.
- `Message.RawBody` is the message as it was delivered: the header order, the folding and
  the CRLF line ends stay. DKIM and ARC verify offline only on these bytes. Do not
  normalize the body in the reader.
- v1 changed its storage format during its life, so one snapshot has gzip bodies and
  plain bodies. The reader decompresses only a body that starts with the gzip magic.

Applies to: `server/oracle/corpus/corpus.go` (`Open`, `checkNotLive`, `Message`,
`gunzip`).
