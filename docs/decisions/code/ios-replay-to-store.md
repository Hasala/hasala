# iOS replay, soft auth and store: decisions from the code (2026-11-21)

These decisions were code comments under `ios/HasalaCore/Sources/HasalaCore/Replay/`,
`ios/HasalaCore/Sources/HasalaCore/SoftAuth/` and `ios/HasalaCore/Sources/HasalaCore/Store/`.
Code comments are not permitted (`scripts/comment-lint.ts`), thus the decisions are here.

## The fold has four convergence rules and two stops

Each device folds the same op log, and each device must reach the same state. Four rules
give this result (spec 04 §2.2 CoreReplay; 03c §2 and §10 for the v4 dispatch):

1. `seq` is the order. The fold refuses to go backwards.
2. `authored_at` decides the forks of a versioned entity and nothing else.
3. A version is a function of the total order. A fork advances the version, whichever side
   wins.
4. Nothing is dropped silently. Each refusal goes into `anomalies` or `forks` with its seq.
   An anomaly or a fork does not stop a sync.

The fold stops for two reasons only. `ReplayStop.order` is a position that the fold cannot
use, and it is a bug of the caller. `ReplayStop.newerVersion` is a log that this build must
not interpret. Each fault of an op becomes an anomaly, and a payload that the fold cannot
read is `invalid_payload`. It is a data condition, not a stop.

Swift arithmetic in the fold never traps. Money goes through `Int128` or through the
overflow-reporting operations (spec 04 §2.4 R9).

The log is append-only. If a bad op stops the fold or traps, sync stops or the app
crashes on each device that reads the log, at each start, and nobody can remove the op.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Replay/Fold.swift` (`Replay.apply`,
`ReplayStop`).

## The fold reads only the log

Each field of `State` is a function of the ops and their positions and of nothing else
(spec 04 §2.4 R2 and R3; 03c §1.11 rules 1 and 2). CoreReplay is a byte-exact module:

- No clock and no randomness.
- No Foundation JSON, no `Double`, no `Calendar`.
- No iteration over an unordered collection. Each map is an `OrderedDictionary` and each
  set is an `OrderedSet`.
- Money is `Int64` minor units, and each product goes through `Int128`.
- Each grammar check of a v4 payload is a hand-written predicate over bytes or scalars. It
  uses no regex engine, no case folding and no lookup in a Unicode table.

The reason for the last rule: the regex engine and the Unicode tables come from the OS.
Two iPhones on different OS versions must fold the same log to the same state. A check
that uses an OS table can accept a string on one iPhone and refuse it on another, and then
the two states are different with no error.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Replay/CoreReplay.swift`,
`ios/HasalaCore/Sources/HasalaCore/Replay/State.swift` (`State`),
`ios/HasalaCore/Sources/HasalaCore/Replay/V4/Base.swift` (`Grammar`).

## A refused payload consumes no version

The causal fold reads the payload of a versioned op before it makes a causal decision. An
op with a payload that cannot be read does not advance a version and does not resolve a
fork. The same applies to a refusal at the payload level that needs the state: a bill edit
that inherits its lists from a bill that is not there, and a split that names no
transaction, names an unparsed row or does not sum to the amount (`precheck`).

Keep this order: decode, then the parent checks, then the payload-level checks, then the
version. Later ops name the version of their parent. If a refused op takes a version, the
versions move, and builds with the two orders fold the same log to different states.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Replay/Causal.swift` (`applyCausal`,
`precheck`).

## The causal fold unwraps what validateOp guarantees

`Replay.apply` runs `OpCodec.validateOp` on each op before the dispatch. The causal fold
then force-unwraps two fields: `op.entity` on each versioned op, and `op.ingestID` on the
two transaction creates. `validateOp` requires them.

Do not relax these two checks in `validateOp` without a change to the causal fold. An op
that passes with no entity or no ingest id traps the fold, and the op stays in the
append-only log, so the app crashes on each device at each start.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Replay/Causal.swift` (`applyCausal`, the
transaction create), `ios/HasalaCore/Sources/HasalaCore/Wire/OpCodec.swift` (`validateOp`).

## An unparsed row cannot leave Review

The fold refuses an edit that clears `needs_review` on an unparsed row. It records
`unsupported_edit_field`. The review queue is the only place that shows an unparsed row.
If the flag is cleared, the row is on no screen, and the message that the app could not
read is lost without a notice. This is the core principle "Do not drop data silently".

Applies to: `ios/HasalaCore/Sources/HasalaCore/Replay/Causal.swift` (`setNeedsReview`).

## A v4 edit cannot set the category

At v4, a `txn_edited` op that names `category` gets the anomaly `unsupported_edit_field`
for that key. A category changes only through `txn_categorized`, which carries its
`source` (03c §3.4). One path for categories keeps `category_source` correct. An edit
that sets a category has no source, and the row then shows a rule, a dictionary or a model
as the origin of a category that the person chose.

The decoder accepts the key, and the fold refuses it. Thus the other fields of the same
op apply. Do not move the refusal into the decoder: the whole op then becomes
`invalid_payload` and its other fields are lost. Below v4 an edit sets the category, as
the oracle did.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Replay/Causal.swift` (the edit path),
`ios/HasalaCore/Sources/HasalaCore/Replay/CausalDecode.swift` (`decodeEditPayload`).

## A log below v4 folds as the ledgerd oracle folded it

The decoders switch on `op.v`. An op of v1 to v3 is decoded with the rules of the ledgerd
TypeScript oracle, so a v1 to v3 log folds to the state of the oracle, and its witness has
the same bytes. The v3 readers keep the distinctions of the oracle exactly:

- An absent key (Swift `nil`, JavaScript `undefined`) is not the same as JSON `null`.
- An integer field accepts each JSON number that is a JavaScript safe integer. `1.0` and
  `1e2` are accepted.
- A currency code is changed to upper case. At v4 the fold does not normalize, and it
  accepts only three upper-case ASCII letters.
- A row from the writer id `ingest` has the provenance `ingest`. That id was the writer of
  the server ingest pipeline of ledgerd. Hasala has no such writer, but the rule stays.

There is one class of exception. Where an op below v4 would give a state that
`Invariants.check` refuses, the v4 rule applies at each version. Today this is the limit of
16 parts in a split (I20).

Do not make a v3 reader stricter and do not remove the `ingest` rule as dead code. The
`conformance/replay` set and each old log then fold to another state.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Replay/Payloads.swift` (`P`, `intFieldV3`),
`ios/HasalaCore/Sources/HasalaCore/Replay/CausalDecode.swift` (`decodeParts`),
`ios/HasalaCore/Sources/HasalaCore/Replay/State.swift` (`ingestWriterID`).

## The writer of an op comes from its frame, not from its payload

`LogEntry.writerID` is the writer of the blob. The frame binds it in its AAD, so it is
authenticated. The fold takes the writer only from there. The provenance of a row
(`ingest` or `user`), the owner of a head and the per-writer records all use this value.

Do not read a writer id from a payload field. A payload is free text of its author, and a
device could name another writer in it.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Replay/Fold.swift` (`LogEntry`),
`ios/HasalaCore/Sources/HasalaCore/Replay/State.swift` (`Txn.provenance`).

## A blob that cannot be read still consumes its seq

One blob is one row and one seq. `foldBlob` advances the cursor before it decodes the
body. A blob that does not decode, or that the reader set aside (spec 01 §6.6 R7 to R10),
still consumes its seq. It goes into `unreadable`, and the reason from the reader has no
content. An op or a blob of the next version stops the fold.

Keep the advance before the decode. If a set-aside blob does not move the cursor, the
cursor of the state and the cursor of the store disagree, and the next blob is refused as
out of order or the bad blob is read again without end.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Replay/Fold.swift` (`foldBlob`,
`foldSetAside`, `advance`).

## An author checks each op with the fold's own decoder

`Replay.payloadProblem` runs the payload decoder of the fold on one op and returns the
text that the fold would record as `invalid_payload`. Each author runs it on each op
before the op goes into the outbox (03c §2, AT-30), after `OpCodec.validateOp`.

The reason: the log is append-only. An op that the fold refuses stays in the log and is
lost on each device. A fault of the envelope is worse, because the codec sets the whole
blob aside (R10), with the good ops in it.

The check cannot predict a causal refusal (a stale parent, a fork). Those depend on the
ops of other devices.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Replay/Fold.swift` (`payloadProblem`).

## The state witness has one canonical form, and a new field does not change old bytes

`State.serialized` is the witness: the canonical JSON of a state. Two replicas converge
when their witness bytes are the same. The form:

- A map is an array of `[key, value]` pairs, sorted by the UTF-8 bytes of the key.
- The keys of an object are sorted the same way. A set is a sorted array.
- Each 64-bit integer that the oracle held as a bigint is a decimal string.
- An array keeps its order, because its order has a meaning.
- `appliedAtCursor` (delivery bookkeeping) and `maxAuthored` (a derived value) are not in
  the witness.

On a v1 to v3 log the bytes are those of the ledgerd TypeScript oracle. The v4 additions
follow 03c §1.9:

1. A field added to a v3 record is written only when it is not at its default.
2. A new top-level map is written only when it is not empty.
3. A record that a v4 op wrote is written in its v4 shape.

When you add a field to the state, obey these three rules. A field that is written at its
default changes the witness of each v3 log, the golden files of `conformance/replay` and
the fold print.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Replay/Serialize.swift` (`witness`),
`ios/HasalaCore/Sources/HasalaCore/Replay/State.swift`.

## The fold print invalidates saved snapshots, and the canary must reach each fold rule

`FoldCanary.foldPrint` is the first 32 hex digits of SHA-256 of the line
`schema <SchemaVersion.current>` and the witness of the folded canary log. A saved fold
snapshot carries the fold print of the build that wrote it. A build with another fold
print refuses the snapshot, folds the log from the start and reads the set-aside rows
again (spec 04 §5.3; 03c §11).

Thus a change of fold semantics must change the fold print. It does so only if the canary
log has an op that the change affects.

- The v3 half of the canary is the `canary-canary-v3` log of `conformance/replay`, byte
  for byte. A conformance test pins the copy.
- The v4 half has one op of each v4 type (a test examines this) and one case for each rule
  that has no type of its own: a keyed overwrite at a later position with an older
  `authored_at`, an annotation carried through a supersede, an un-split, the copy and merge
  rules, the bill rules, the ops below v4 on current rows, the undo of a budget move, the
  mailbox retirement and the possible-duplicate notices.

When you change a fold rule, add a canary op that the change affects. If you do not, a
device keeps a snapshot from the old rule, and its state is not the state of a device that
folded from the start.

The snapshot is the LZFSE-compressed JSON of `StateSnapshot`. It holds the whole state,
the fields outside the witness included, and each ordered map keeps its insertion order.
Thus a start from a snapshot gives the projection the same `ord` columns as a fold from
the start. The checks of the stored row (`bound_tip`, digest, cursor) belong to the store.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Replay/Snapshot.swift` (`FoldCanary`,
`StateSnapshot`).

## A keyed record takes the last write by position

A keyed record (`Keyed`) holds a value and the op that installed it. The fold installs it
with no condition. The fold visits the ops in position order (the seq of the blob, then the
index of the op in the blob), so the last write by position wins (03c §1.8.1; 03a §3.0.1
for the plan records).

The fold never compares `authored_at`, writers or op ids to decide a keyed value. This is
different from a versioned entity, where `authored_at` decides a fork. Annotations,
merchant names, sender trust and the plan records are keyed. A plan record also adds an
overwrite notice (P-11) when another writer replaces a value that has a later stamp. The
notice does not change the value.

A device clock can be wrong. If a stamp decided a keyed value, a device with a clock in
the future would win each write until the other clocks pass it.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Replay/V4/Base.swift` (`Keyed`),
`ios/HasalaCore/Sources/HasalaCore/Replay/V4/Keyed03c.swift`,
`ios/HasalaCore/Sources/HasalaCore/Replay/V4/Plan.swift`.

## An op installs nothing until all of it is valid

An op that sets more than one value is examined completely before the first write.
`txn_annotated` validates each key of `set` first. `budget_moved` computes the new value of
each cell with checked arithmetic first. An invalid key or an overflow then leaves the
state as it was, and the fold records one anomaly.

Do not merge the validation loop and the write loop. An op that applied its first half
before its refusal leaves a state that no op describes.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Replay/V4/Keyed03c.swift`
(`applyTxnAnnotated`), `ios/HasalaCore/Sources/HasalaCore/Replay/V4/Plan.swift` (the budget
move).

## The plan family folds in CoreReplay and reads only its own ops

Spec 04 §2.2 and 03a §4.2 fold the plan family (`budget_set`, `budget_moved`,
`income_source_set`, `category_plan_role_set`) through a `FoldFamily` that CoreDomain
registers. The code does not do this. The family folds in `Replay/V4/Plan.swift`. The
rules and the shape of the witness are those of 03a. Only the place is different.

The reason: `State` stays a plain `Codable` value, which the fold snapshot needs, and the
fold path has no existential box for a family.

The plan fold never reads the taxonomy, the transactions or a clock (03a §4.1). Each rule
that needs another record is a read-time rule in `PlanEngine`. Do not add such a check to
the fold: its result would depend on the order in which the other records arrived.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Replay/V4/Plan.swift`,
`ios/HasalaCore/Sources/HasalaCore/Domain/Plan/PlanEngine.swift`.

## A home amount freezes at the position of its row

This is the FX snapshot rule (spec §3.7):

- A row freezes its home amount at its own position, against the rate head that is live
  there.
- A later `rate_set` fills only the rows that are still null. It does not change a frozen
  row.
- `rate_unset` does not thaw a row.
- The home currency has the implicit rate 1.000000.

The conversion is `(amount * rate + 500000) / 1000000` in `Int128`: half-up, with positive
operands. A result that does not fit `Int64` cannot be stored. The row stays null and
pending, and the fold records `money_overflow` (03c §1.3).

Do not make a new rate change the rows that are frozen. The totals of past months would
then change each time a rate changes, and the `conformance/fx` set pins the rule.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Replay/FX.swift`.

## CoreSoftAuth is test support and uses CryptoKit for P-256 only

CoreSoftAuth holds a software approval key and a software passkey for tests. The app
target never links it (`ios/project.yml`).

The software approval key exists because `SecureEnclave.isAvailable` is false in the
simulator. The tests sign with a `P256.Signing.PrivateKey` that has the byte formats of the
Secure Enclave key: a 65-byte X9.63 public key and a 64-byte raw `r ‖ s` signature. There
is no user presence.

The specs disagree here, and the decision is recorded. Spec 04 §2.2 and spec 01 §12.1 give
this module a software signer over `P256.Signing.PrivateKey`, which needs CryptoKit. The
import table of spec 04 §2.3 does not list CryptoKit for CoreSoftAuth. `imports.allow`
follows §2.2. The module uses CryptoKit only for P-256 signing, SHA-256 and HMAC. The
AT-C11 calls (`AES.GCM`, `HKDF`, `Curve25519.Signing`, `SecRandomCopyBytes`) and
`SecureEnclave` are not used. Do not add one of them, and do not link the module into the
app: a software key in the app would replace the hardware key that the approval depends
on.

Applies to: `ios/HasalaCore/Sources/HasalaCore/SoftAuth/SoftwareApprovalKey.swift`,
`ios/HasalaCore/Sources/HasalaCore/SoftAuth/SoftPasskey.swift`,
`ios/HasalaCore/imports.allow`.

## The account directory is protected and is not in a backup

The directory `<Application Support>/accounts/<user_id>/` holds financial data in
plaintext (spec 04 §4.1; spec 01 §11.2). Thus:

- The directory is made with the protection class `completeUntilFirstUserAuthentication`.
- The directory is excluded from the iCloud backup and the Finder backup.
- The app sets the two again at each launch, before the database pools open.

The directory is the guarantee. SQLite makes and removes companion files (`-wal` and
`-shm` for a WAL database after its first write, `-journal` only during a rollback-journal
write). A companion that did not exist when the marks were set gets its protection and its
exclusion from the directory. The marks on the database files are a second layer only.

Do not put a database of an account outside this directory, and do not rely on the
per-file marks. Plaintext ledger data would then go into a backup.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Store/FileHygiene.swift`.

## The fold snapshot row is bound to the log and commits with its page

The `fold_snapshot` row (spec 04 §4.2, §5.3) holds a saved fold and two values that bind
it:

- `bound_tip` is SHA-256 of `seq ‖ 0x00 ‖ "hot" ‖ 0x00 ‖ writer_id ‖ 0x00 ‖ writer_counter ‖
  0x00 ‖ blob_hash ‖ prev_hash`, over the `wire_rows` row at `cursor_hot`. Integers are
  decimal ASCII, and hashes are their 32 raw bytes.
- `digest` is SHA-256 of the payload.

The snapshot is written in the transaction of the page that it follows. Thus its cursor
and the cursor of the store agree after each commit.

A load examines the row in the order of §5.3, the cheapest check first: version, fold
print, bound tip, digest, decode, cursor. The first failure is reported and written to
`fold_events`, the row is deleted, and the caller folds from the start. Do not use a
snapshot that failed a check. A snapshot from another log or another fold gives a state
that the log does not give.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Store/LedgerStore+FoldSnapshot.swift`.

## Each sync step is one transaction in the ledger store

Each transaction boundary that spec 04 §5 names is one method of `LedgerStore`:

| Method | Step | In one transaction |
| --- | --- | --- |
| `persistPage` | §5.2 step 6 | The rows of the page, the new heads, the cursor and the fold snapshot. |
| `enqueue` | §5.4 | The pending ops. They are durable when the call returns. |
| `persistBatch` | §5.5 step 4 | The sealed, signed batch (R-OUT-2). |
| `acknowledge` | §5.5 step 6 | The in-flight blobs and their pending ops leave, and the authored head moves. |

The heads that `persistPage` gets come only from verified bodies.

Do not divide one of these steps into two calls. A crash between them leaves, for example,
rows with no cursor or an acknowledged batch with its ops still pending, and the next run
authors or folds them again.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Store/LedgerStore.swift`.

## persistBatch examines the batch again inside its transaction

`persistBatch` refuses a batch (`staleBatch`) unless its first blob continues the authored
head (counter and hash), its blobs chain to each other, and each op in it is still pending
and occurs one time. It makes these checks inside the write transaction.

The sync engine already runs one upload at a time. The check is a second defence. A batch
that was sealed from a stale read would put an op into the shared log two times, and the
log is append-only.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Store/LedgerStore.swift` (`persistBatch`).

## The in-flight batch is discarded only after a refusal that stored nothing

`discardInflight` removes the in-flight batch and does not acknowledge it. Its ops stay
pending and are sealed again. Use it only after a definitive refusal from the server that
stored nothing (`409 stale_epoch`, R-OUT-4).

Do not use it after a timeout or an error with no answer. The server can have the batch.
The ops would then be sealed again at the same counters with other bytes, and the chain of
the writer breaks. For such a failure the device sends the same bytes again.

No code calls `discardInflight` at this time. Epoch rotation is not in the beta, and the
pusher stops on `409 stale_epoch`.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Store/LedgerStore.swift`
(`discardInflight`).

## Reads of pending ops depend on the canonical op JSON

Two reads of `pending_ops` search the stored op JSON as text and do not decode it:

- `hasPendingIngest` answers the question of the mail lane "was this message already
  authored here?" (spec 04 §7.5). An ingest id in `pending_ops` was authored on this device
  and must not be authored again, also before the op is uploaded and folded.
- `latestPendingAuthoredAt` gives the author rule its `own_last_ms` (03c §1.8.2; spec 04
  §5.4).

They are correct only because a pending op is canonical op JSON from the CoreJSON writer.
It has no whitespace, so a member is exactly `"name":"value"`. `authored_at` is always the
canonical instant of 24 bytes, and this form sorts as text.

`hasPendingIngest` puts the ingest id into a `LIKE` pattern with no escape. It first
requires 64 lower-case hex characters, so the id cannot hold a `LIKE` wildcard. Keep that
check before the query.

If pending ops are stored in another form (other spacing, another instant format), the two
reads find nothing and give no error. The mail lane then authors a message two times, and
a new op can get a stamp that is not after the last one.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Store/LedgerStore+Pending.swift`.

## A database error keeps only its result code

`StoreError.database` carries the result code of a GRDB error and nothing else. The
message of a database error can contain values from the statement, and the ledger database
holds financial data. Thus the message is never kept and never logged.

Do not add the message or the SQL to the error or to a log line.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Store/LedgerStore.swift` (`StoreError`).

## The op of a message and its accounting row commit together

One step of the mail lane writes all its rows in one transaction (`MailboxWrite`): the
`pending_ops` row of the message, its accounting row, and the set-aside, staging and
health rows (spec 04 §7.5 step 7f). The `pending_ops` insert is in the mailbox store for
this reason.

If the op and the accounting row commit apart, a crash between them loses a message (it is
accounted with no op) or authors it two times (it has an op and is not accounted).

The store works on rows and does not know their content. CoreMailbox maps its values to
these rows and does not import GRDB (R6). The op JSON arrives already authored by
`OpAuthor` in CoreDomain (R5).

Applies to: `ios/HasalaCore/Sources/HasalaCore/Store/MailboxTables.swift` (`MailboxWrite`,
`MailboxTableStore`).

## A Keychain read that fails is not an absent item

`SecretStore.read` returns `nil` only when the item is absent. Each other failure throws.
The usual one is a read before the first unlock after a restart
(`errSecInteractionNotAllowed`), which is `notNow`. A caller treats a throw as "not now"
and never as "absent".

The reason: before the first unlock the Keychain cannot give an item that is there. A
caller that reads this as "absent" signs the person out, makes new keys or asks them to
connect their mailbox again, although nothing was lost.

Each case of `SecretItem` names exactly one Keychain item. Its service, account and
accessibility are the table of spec 04 §4.4, so the adapter decides nothing.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Store/SecretStore.swift` (`SecretStore`,
`SecretStoreError`).

## The Gmail token keeps its Keychain service name

The Gmail refresh token is stored under the service `app.hasala.gmail.refresh`. The name
is older than `SecretItem.mailRefresh(provider:)`, and it did not change when the provider
became a parameter. Thus a link that an older build made needs no migration.

Do not rename the service of an existing item. The item of each tester stays under the
old name, the app does not find it, and the person must connect the mailbox again. A new
item must also be in `SecretItem.allServices`, which the purge of a fresh install uses. A
test examines that list.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Store/SecretStore.swift`
(`SecretItem.gmailRefresh`, `SecretItem.allServices`).

## The Keychain items are the only secrets at rest, and they stay on this iPhone

The app stores no secret other than the items of `SecretItem` (spec 01 §11.1, "Never at
rest"; spec 04 §4.4). The first four have these formats:

- The session: a JSON record with the token, the user id, the pending-logout flag, the
  expiry and a local tag.
- The account binding: a JSON record with ids and the salt of the account. It holds no
  secret.
- The epoch key: the 32 bytes of the key.
- The writer key: one byte for the algorithm, then the key bytes. `0x01` is Ed25519 with a
  32-byte seed.

Each item is not synchronizable, is in the data-protection Keychain and is in the access
group of the app only. There are two accessibility classes, and the two are "this device
only": after first unlock for each item, except the approval key handle, which needs a
passcode on the device.

Do not store another secret in a file, in `ledger.sqlite` or in the defaults. Do not make
an item synchronizable. A key or a token would then leave the iPhone through iCloud
Keychain or a backup.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Store/SecretRecords.swift`,
`ios/HasalaCore/Sources/HasalaCore/Store/SecretStore.swift` (`SecretAccessibility`).
