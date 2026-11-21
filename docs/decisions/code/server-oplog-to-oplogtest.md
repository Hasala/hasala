# Op log append and hash chains (oplog): decisions from the code (2026-11-21)

These decisions were code comments under `server/internal/oplog`. Code comments are
not permitted (`scripts/comment-lint.ts`), thus the decisions are here.

## The log has one row type, and the op type stays in the ciphertext

`op_log.type_flag` has one value, `edit`: each row is a device's own encrypted batch.
The `op_log_type_flag_is_edit` CHECK holds this. The server authors no row (spec 02
§2.3, C5). The log also has one stream, `hot` (the `op_log_stream_is_hot` CHECK).

The type of an op is inside the sealed frame. Do not copy it into a column, and do not
add a second `type_flag` value that tells the server what a row contains. A column with
the op type lets the server, and each backup, see what a person did, and the server
must stay blind.

Applies to: `server/internal/oplog/append.go` (`TypeFlagEdit`),
`server/internal/oplog/chain.go` (`AppendClientOutcome`).

## Seq is the only order of the log

`created_at` of a row is `now()` at the insert when the caller gives no time. It does
not rise with `seq`: two appends can commit in one order and carry times in the other.
Replay folds the log by `seq`, and nothing else is a total order.

Use `created_at` only for diagnosis. Do not sort, page or resume a read by it. A read
that orders by time can give two devices different results from the same log.

Applies to: `server/internal/oplog/append.go` (`Row.CreatedAt`).

## Row validation runs before the transaction and again in it

`Row.validate` refuses a row that cannot be stored, or that can be stored and never
read: a wrong size bucket, a frame that does not look sealed (spec 01 §8.1, finding
F1), an AAD for a different position.

It runs two times on purpose (spec 02 §11.2):

- `AppendClient` runs it before the append transaction opens. An invalid batch of a
  client does not reach the counter lock.
- `appendTx` runs it again in the transaction, after the chain check. Thus no append
  path, present or future, can store a row that skipped the plaintext refusal.

The second run costs nothing when it fails: the rollback puts the counter back, so an
invalid batch leaves no hole. Do not remove one of the two because the other exists.

Applies to: `server/internal/oplog/append.go` (`Row.validate`, `appendTx`).

## A blob is bound to the position where it is stored

`Row.validate` compares the AAD in the frame with the AAD of the account, stream,
writer and counter of the row. The `op_log_aad_matches_position` CHECK says the same in
SQL.

Nothing else on the write path makes this check. The hash chain does not: a blob that
was sealed at counter 7, or for a different account, chains correctly at counter 1,
because SHA-256 does not read the meaning of the bytes. Without the check such a row is
stored and passes `hasalad verify`. A phone finds it later, when the frame does not
open, and reports it as tampering.

The server needs no key for this, because the AAD is cleartext framing before the
nonce. The comparison is `bytes.Equal` and not a constant-time compare, on purpose: the
two sides are public framing that the caller supplied. Do not read this as an error to
correct.

Applies to: `server/internal/oplog/append.go` (`Row.validate`),
`server/internal/oplog/chain_test.go`
(`TestAppendClientRejectsABlobSealedForAnotherPosition`).

## Every append goes through the chain check

`Appender.AppendClient` is the one public write path. `appendRows` is not exported, and
the package has no exported function that appends without the chain check. The server
has no writer of its own.

Do not export `appendRows`, and do not add a second public append. A path with no chain
check can store a row that breaks a writer's chain, and each device of that account
then stops sync with a tamper warning. The tests that examine seq allocation call
`appendRows` directly through a helper in the test files; that helper must stay there.

Applies to: `server/internal/oplog/append.go` (`Appender`, `appendRows`).

## An unset budget gate is the default gate

`Appender.Budget` is the storage gate of an account. When the field is nil, the
appender builds a gate over its own pool. Nil does not switch the gate off.

This default is what makes the storage ceiling hold. If an unset field meant "no
accounting", each `Appender` literal in the tree would append with no budget, including
the one in `api.New`, and nobody would see it before production. The field exists only
so that a caller can give a gate with a different clock or pool.

Do not add a way to append with no gate.

Applies to: `server/internal/oplog/append.go` (`Appender.Budget`, `Appender.budget`).

## The counter row is made with the account and is never reset

`EnsureSeqRow` makes the `oplog_seq` row of an account. `auth.UpsertUser` calls it in
the transaction that makes the account.

- It takes a `pgx.Tx`, not a pool. A counter row that is made in a different
  transaction can commit when the account does not, or the account can commit with no
  counter row.
- It uses `ON CONFLICT DO NOTHING`, not `DO UPDATE`. A second call for the same account
  must not put `next_seq` back to 1. After a reset, the next append gets a seq that is
  already in `op_log`. The primary key `(user_id, seq)` refuses it, so nothing is
  overwritten, but all later appends of that account fail.

`appendTx` runs the same insert before it allocates. In normal operation it inserts
nothing, but it is not free. In Postgres, an `INSERT ... ON CONFLICT DO NOTHING` whose
conflicting row is being updated by an open transaction waits for that transaction.
Thus a second append for the same account waits at this statement, one statement
before the counter update. The result is the same, because it waits for the same
transaction. A test that interleaves two appends at a chosen point must know this.

Applies to: `server/internal/oplog/append.go` (`EnsureSeqRow`, `appendTx`),
`server/internal/oplog/chain_test.go`
(`TestAnAppendQueuedBehindAnotherSeesTheCommittedHead`).

## Seq comes from a locked counter row, not from a sequence

The `seq` of an account has no gap and rises in commit order. Spec §3.7 resolves FX
rates by a fold of the log in seq order, so a hole changes the budget totals that a
phone computes. One upload batch also occupies consecutive seqs (spec 01 §7.1).

The guarantee comes from the `oplog_seq` row of the account, not from a Postgres
sequence:

- The `UPDATE` of the counter locks that row until the transaction commits. A second
  append for the same account cannot allocate before the first one is complete. Thus
  commit order is seq order, and a committed seq N means that each seq below N is
  committed. A reader never sees seq 7 while seq 6 is in flight.
- A rollback puts the counter back, so a failed append uses no seq. `nextval()` uses
  its value permanently, and a watermark must then find which values are lost and which
  are only slow.
- A crash makes no hole. The counter update and the row inserts are one transaction
  with one commit record. Recovery replays a prefix of the WAL, so a crash can only cut
  the end of the log. This is also true with `synchronous_commit=off`, which loses the
  last commits and none in the middle.
- No seq is given two times, and this depends on `READ COMMITTED`. An `UPDATE` that
  waited evaluates `next_seq + n` again against the row version that the winner
  committed. Thus the append pins its isolation level (`pgtx.BeginReadCommitted`) and
  does not use the default, which can be set for each database, for each role and by a
  pooler. Measured under `repeatable read`: 41 of 60 concurrent appends failed with
  SQLSTATE 40001, the first at the `EnsureSeqRow` insert. No hole occurred, because
  such a failure is a rollback. It is a loss of availability that depends on
  configuration outside this repository.
- One call appends for one account. A call for two accounts must lock two counter rows,
  and two such calls in opposite order deadlock.

Do not replace the counter row with a sequence and a published watermark.

An error from an append does not always mean "not appended". When the deadline ends or
the connection drops during the commit, the rows can be stored while the caller gets an
error. The gap-free property is not affected. The answer to a retry is in "What
AppendClient checks, and how it answers a batch that is sent again".

Accepted cost: the row lock is held during the blob inserts, so a large upload makes
the other appends of that one account wait. The wait has a bound, it touches one
account, and it costs less than a second mechanism for the gap-free property. This is a
deliberate trade (Decision 3 of the ledgerd design archive).

Applies to: `server/internal/oplog/append.go` (`appendRows`, `allocSeq`),
`server/internal/oplog/append_test.go`
(`TestAppendPinsReadCommittedRegardlessOfTheDatabaseDefault`), `server/internal/pgtx`.

## The counter lock comes before the chain check

In `appendTx`, `allocSeq` runs first. The chain check (`prepare`) runs after it, and
the inserts come last. Thus the head of a writer's chain is always read under the
counter lock.

With the other order, two uploads of one writer at the same time both read head 5 and
both try counter 6. The unique key on `(user_id, writer_id, stream, writer_counter)`
stops the second, but as a constraint violation and not as a chain break. That is the
wrong answer for a client, and the correct order makes the case impossible.

The chain check can fill or examine the fields of the rows, but it must not change the
number of rows. The seq block is reserved before it runs, so a dropped row leaves a
hole. An error from it stops the whole append, and the rollback puts the counter back.

Two tests hold the order. `TestTheChainCheckRunsAfterTheCounterLockIsTaken` reads
`oplog_seq` in the chain check and finds `next_seq` already moved; it needs one
connection and no timing. `TestConcurrentDoubleAppendFromOneWriterIsACleanChainBreak`
holds the result: with the order reversed, the loser gets SQLSTATE 23505 and not
`ErrChainBreak`.

Applies to: `server/internal/oplog/append.go` (`appendTx`, `prepareFunc`),
`server/internal/oplog/chain_test.go`.

## The storage ceiling is charged in the append transaction

The account's storage ceiling (`internal/budget`) is charged in `appendTx`, the one
place that no append can go around. It is not charged at an endpoint. A ceiling
"for each upload" binds only the endpoints that call it, and the next path that
appends does not.

- The charge runs after `allocSeq` and after the chain check. The counter lock is then
  held, so the appends of one account are already serialized before the usage row is
  touched. There is one lock order, and two appends cannot deadlock.
- The charge uses the transaction of the append, not a connection of its own. When the
  append rolls back (for example on a taken position), the charge rolls back with it.
  With a separate connection, each failed append stays charged, and an honest account
  is locked out of its own log in time.
- The bytes charged are `len(Blob)`: the framed, padded bytes that go into the column.
  These fill the disk, and `internal/verify` reconciles the ledger against
  `sum(octet_length(blob))`. A different measure makes `hasalad verify` report a
  difference for each account.

Applies to: `server/internal/oplog/append.go` (`appendTx`, `admit`),
`server/internal/oplog/budget_test.go`
(`TestTheLedgerIsUnchangedAfterARolledBackAppend`).

## Seq allocation uses two statements

`appendTx` first makes sure that the counter row exists (`INSERT ... ON CONFLICT DO
NOTHING`), then `allocSeq` updates it with `RETURNING next_seq - n`, which is the first
seq of the reserved block. `allocSeq` is the only place that allocates a seq.

Do not fold the two into one `INSERT ... ON CONFLICT ... RETURNING`:

- With `DO NOTHING`, Postgres returns no row on the conflict path. The row exists for
  each append after the first, so the usual case returns nothing and the scan fails
  with `pgx.ErrNoRows`.
- With `DO UPDATE`, the statement works, but each append is then an insert attempt on
  a row that it did not need to insert.

Applies to: `server/internal/oplog/append.go` (`allocSeq`, `appendTx`).

## MaxSeq reads the log, not the counter

`Appender.MaxSeq` reads `max(seq)` from `op_log`. It does not read
`oplog_seq.next_seq`. The counter includes an allocation that an open transaction can
still roll back. The log has only what a reader can see. A sync cursor needs the second
answer. With the counter, a pull can report rows that do not exist yet, or never will.

Applies to: `server/internal/oplog/append.go` (`Appender.MaxSeq`).

## The per-writer hash chain rule is frozen

For each `(writer_id, stream)` independently (spec 01 §7):

    blob_hash[n] = SHA256(blob_hash[n-1] || frame[n]),  blob_hash[0] = 32 zero bytes

The hash is over the stored bytes: the sealed, padded frame. Thus each holder of the
stored blob can compute it again, including a server that cannot read the frame. The
first hash links to 32 zero bytes, not to an empty input. `blob.Hash` is the one
implementation, and the golden steps in `conformance/blob/manifest.json` hold the bytes
that each implementation must give.

A change of this rule is a data migration, not a code change: each stored chain and
each phone's pinned head depend on it. For that reason the Go test compares against
constants and not against a second implementation of the same formula.

What the chains prove: each row is authored by a device, over frames sealed under a key
that the server does not hold (frame v3: the AEAD binds the header and `prev_hash`). A
server that drops, reorders or splices a device's ops is found by that device and by
the account's other devices. The links alone do not prove that nothing was cut from the
end or that the history was not chained again from the start. Those need a pinned head:
the device's stored head and the signed batch heads of spec 01 §7.1.

Applies to: `server/internal/oplog/chain.go`, `server/internal/oplog/chain_test.go`
(`TestChainRuleIsPinnedByAGoldenVector`).

## A chain break is only for a real break of a chain

`ErrChainBreak` is a hard stop for a client (spec §3.3:68). The app shows a warning
that the server may have changed the person's data, and the person cannot dismiss it.
It is in the same class as `ErrUnknownNewerVersion`, and not in the class of
`blob.ErrSetAside`, which is a warning about one blob. Return it only when a writer's
chain does not line up: a counter that skips, a `prev_hash` that is not the hash of the
row before, a `blob_hash` that is not SHA256(prev || bytes), or different bytes at a
counter that is already stored.

Two other cases have their own errors, and they must not wrap `ErrChainBreak`:

- `ErrPartiallyApplied`: the batch straddles the stored head. This is a protocol
  mistake with a simple remedy. The text of the error is the client contract: the API
  puts it in the response body, and a test reads it.
- `ErrPositionTaken`: the database refused a position that the chain check approved.
  This cannot occur while the counter lock comes before the chain check. It is a broken
  server invariant, and it must not look like proof that the operator dropped data. It
  also keeps the order rule testable: if this case gave `ErrChainBreak`, the reversed
  order and the correct order would give the same error. When `resolveAppendErr`
  reports it, it formats the inner error with `%v` and not `%w`, because the inner
  error can be `ErrChainBreak`.

`resolveAppendErr` translates SQLSTATE 23505 on `op_log_position_uniq`. That branch is
not reachable in a correct build: the head is read under the counter lock, so a taken
position is seen as a replay before an insert. The branch stays, for two reasons. A
client cannot act on a raw duplicate-key error, and a change that reverses the order
must fail loudly and corrupt nothing. It is a separate function so that a test can
drive it with no test hook in the production path.

`isPositionTaken` is narrow on purpose. It accepts only a unique violation on
`op_log_position_uniq`. A 23505 on `op_log_pkey` is a corrupted seq counter, a
different failure, and it must never be answered as "already applied".

Applies to: `server/internal/oplog/chain.go` (`ErrChainBreak`, `ErrPositionTaken`,
`ErrPartiallyApplied`, `resolveAppendErr`, `isPositionTaken`).

## VerifyChain proves a continuation of a trusted head, not a complete log

`VerifyChain` is the check of a reader of rows. It computes each hash again from the
stored bytes and does not read the hash from the row. Thus a server that replaces a
blob cannot keep the chain whole by a change of the hash column.

It finds each break relative to the head that the caller gives: an op missing from the
middle, two ops out of order, a replaced or edited blob, a false `prev_hash`, a run
that does not continue the head, and rows of more than one `(writer, stream)` together.

It does not find a server that chains again what it serves. A log of 1..5 served as
1..3 passes. A whole different history, chained correctly from the start, passes. These
are found only when the head at the end is compared with a head that the verifier
already trusts: the stored head of a device that comes back, and the signed batch
heads. The comparison between devices (`writer_checkpoint`, I11) is not in the beta
(`docs/decisions/sync-writer-checkpoints.md`). A caller must not read "VerifyChain
passed" as "the server served everything". This limit is accepted.

Each failure wraps `ErrChainBreak`, including rows that are not all from one writer and
stream. A caller that mixed them has a bug, but a server that returned them has done
wrong: two writers with continuous counters and honest hashes pass each other check.
The input is ambiguous, and the function fails closed.

Applies to: `server/internal/oplog/chain.go` (`VerifyChain`),
`server/internal/oplog/chain_test.go`
(`TestVerifyChainDetectsRowsSplicedFromTwoChains`).

## What AppendClient checks, and how it answers a batch that is sent again

The client authored the blobs and their hashes. The server checks only arithmetic that
it can do again from the stored bytes, and one signature over it. That is all it can
check with no key, and all it is trusted to check.

The writer. The caller must establish that the writer is the one bound to the session.
That check is in the sync handler and not in this package: it needs `auth`, and `auth`
imports `oplog` (account creation calls `EnsureSeqRow`), so it would be an import
cycle. `AppendClient` reads the writer row `FOR SHARE` in the append transaction and
refuses a writer that is not enrolled or is revoked. A revocation holds that row `FOR
UPDATE` (spec 02 §9.5), so a revocation that commits between the handler's check and
the append cannot let a row in. The `op_log_writer_fk` foreign key is the database's
part.

The signed head. `head_sig` is the device's signature over `HeadMessage(user_id,
last counter, last blob_hash, writer_id)` (spec 01 §7.1, R-02). The server verifies it
against the last row as the server computed it again, not as the client claimed it. It
is stored on the last row of the batch only.

The epoch (spec 01 §8.3). Each row above the stored head must carry
`account_keys.current_epoch`, read `FOR SHARE` after the head. Else the answer is
`ErrStaleEpoch`.

A batch that is sent again. An append whose commit got no answer can be stored while
the client got an error, and the client sends it again. A batch whose counters are at
or below the stored head is a replay, not a gap:

- When each row is stored at its position with the same `blob_hash`, the call returns
  the seqs that the rows already have and appends nothing. It does not verify the
  signature again, and it never refuses a replay for its epoch or its head (spec 01
  §8.3). The same bytes are the whole test.
- Different bytes at a stored counter are a forked writer: two devices with one writer
  id, or a device that lost its state and used its counters again. That is
  `ErrChainBreak`.
- A batch that straddles the head is refused with `ErrPartiallyApplied`. The server
  does not trim it. The client sends only the rows above the head, with the same
  `head_sig`, because the batch ends at the same last row.

The unique key on `(user_id, writer_id, stream, writer_counter)` is what makes the
lost answer detectable. Do not answer a replay with an error that tells the client to
try again: the client then repeats the same batch with no end.

Applies to: `server/internal/oplog/chain.go` (`AppendClient`, `AppendClientOutcome`,
`appliedSeqs`), `server/internal/oplog/heads_test.go`.
