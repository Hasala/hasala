# Op log reads, the op reference model and operator notices: decisions from the code (2026-11-21)

These decisions were code comments under `server/internal/oplog`,
`server/internal/oplog/opref` and `server/internal/opsnotify`. Code comments are
not permitted (`scripts/comment-lint.ts`), thus the decisions are here.

## The v3 op wire model is frozen reference code

Package `opref` is the op wire model of ledgerd (op schema 3). It is reference and
fixture code only (spec 02 §2.3). It reads and writes the fixture sets `conformance/op`,
`conformance/blob` and `conformance/ts`, and the Swift port must agree with them. The
server never encodes, decodes or opens an op, because a blob is ciphertext. The build
graph of `cmd/hasalad` must not reach this package (spec 02 §4.4, fence 1). The op
schema 4 of Hasala is in specs 03a to 03c and in Swift.

Two executors must fold one log into one state. The second executor was the ledgerd
TypeScript client. It is now the Swift port, which keeps the limits of the TypeScript
client for a log below v4. Thus each shape that two languages can read differently is
fixed here:

- Money and counters are JSON strings that hold decimal integers. A JSON number becomes
  a float in JavaScript, and a float cannot hold each 64-bit value.
- `writer_checkpoint.heads` is an array sorted by writer id and stream, not a map. Each
  head names a stream, because a chain belongs to one writer and one stream. A decoder
  refuses an unsorted array: two devices that agree on the heads must get the same
  bytes.
- `parent_version` is present on each op, and it is `null` on a create and on a
  parent-free op. The type tells the two apart, not the absence of the field. `entity`
  is absent on a parent-free op.
- A decoder refuses each thing that its encoder refuses: a zero time, and a raw body
  that is not strict standard base64. A looser decoder accepted records that the other
  executor refused.

The model does not claim the same JSON bytes from the two encoders. Go trims the zeros
at the end of a timestamp, and Go escapes some characters that JavaScript writes
literally (`docs/decisions/code/ios-domain-to-mail.md`). This is safe only because each
blob is encoded one time, by its author, and the chain hashes the bytes as stored.
Nothing in the code enforces that property. If a later feature encodes an op again
(compaction, a snapshot rewrite, a migration), the bytes change and the chain breaks.
Before such a feature, make the op encoding the same byte for byte in each language, or
start the chain again on purpose at the rewrite. A reprocess adds a new supersede op and
rewrites nothing.

Order: the server gives each blob a seq, and replay folds by seq. `authored_at` is a
client clock. It decides a fork between two ops with the same parent version, and
nothing else reads it. FX resolution never reads it (spec §3.7).

Parent-free ops: `rate_set`, `rate_unset`, `home_currency_set` and `writer_checkpoint`
name no entity and carry no `parent_version`. They cannot fork. `Op.Validate` enforces
this. If rates were versioned entities, fork resolution would decide FX, and the two
executors could give different amounts.

Configuration ops (`bank_declared`, `budget_split_set`, `category_defined`, schema v3)
are parent-free facts. The last write for a key wins, by position.

- They are ops and not server tables, because a server table stays plaintext. The names
  of a person's categories must not be readable by the operator.
- Each op carries one key, never a list. Two devices that each add a different bank
  offline would lose one bank with a whole-list replace, and nothing would show it
  (spec §3.3 forbids last-write-wins on a collection). A removal is `active: false`.
- Go does not validate their payloads. A payload shape belongs to the executor that
  folds it. Two validators become two opinions on what a valid op is.
- A new optional payload key is not a vocabulary change and needs no version bump. A
  reader that does not know the key ignores it. A new op type needs a bump.

A cold blob (a raw body record) is not an op blob (invariant I16). `DecodeBlob` refuses a
raw body and `DecodeRawBody` refuses an op blob. Hasala has no cold stream, but the
fixtures keep the two kinds.

The server validates no op, and a bad op stays in the log permanently. The owner accepts
this (`CLAUDE.md`, "The server is blind" and "Core principles"). The guard is on the
client: each author examines its ops before it queues them.

Do not change the behaviour of this package to make a test pass. The fixtures then
change, and the Swift port is held to the fixtures.

Applies to: `server/internal/oplog/opref/op.go` (package `opref`, `Op.Validate`,
`DecodeRawBody`, `EncodeCheckpointPayload`, `DecodeCheckpointPayload`).

## The op vocabulary is closed for each schema version, and a newer version stops the reader

The set of op types is closed at each `SchemaVersion`. A new type comes only with a
version bump. A reader that finds a version above its own returns
`ErrUnknownNewerVersion` and stops the fold. It does not fold a log that it understands
in part into money (spec §3.3:68). The stop applies to the blob header and to each op
in the blob, because a blob of a known version can carry an op of a newer version. The
blob is refused whole. The reader does not skip the ops that it cannot read.

Each type also has a minimum version (`OpType.MinVersion`). A configuration op must
declare v3. If a v3 writer stamped it v1, an older reader would see a v1 op of an
unknown type. It would refuse that one op and fold the remainder of the log. The bump
gives a stop only if the new ops declare the new version.

The stop is narrow. Each other decode error means that one blob cannot be read. That
blob is set aside with a warning, and the remainder of the log is folded. A caller of
`DecodeBlob` must separate the two cases with `errors.Is(err, ErrUnknownNewerVersion)`.
A bad timestamp is a set-aside, never a stop.

`conformance/op/manifest.json` pins the type set, the parent-free set and the minimum
versions, because each executor has its own copy of these tables. The rule of the phone
for a next-version row is in `docs/decisions/op-version-ceiling.md`.

Applies to: `server/internal/oplog/opref/op.go` (`SchemaVersion`, `OpType`,
`OpType.MinVersion`, `DecodeBlob`), `server/internal/oplog/opref/op_test.go`
(`TestConfigurationOpsAreParentFreeV3Facts`),
`server/internal/oplog/opref/conformance_test.go` (`opManifest.MinVersions`).

## Wire timestamps have one strict grammar, millisecond precision and a canonical form that can be read again

`authored_at` decides a fork, so two executors that read one timestamp differently give
different money from one log. Three rules prevent this.

**One grammar.** `parseWireTime` accepts a four-digit year, an upper-case `T`, an
optional fraction that is not empty, and `Z` or an offset from `-23:59` to `+23:59`. It
does not use `time.Parse` alone. The JSON reader of `time.Time` is lenient
(go.dev/issue/47353), and JavaScript's `Date.parse` is lenient in other places. These
values were measured on the two runtimes:

| Timestamp | Go (`time.Parse`, RFC 3339) | JavaScript (`Date.parse`) |
| --- | --- | --- |
| `2026-06-05T24:00:00Z` | refuses | accepts, as the next day at 00:00 |
| `2026-02-30T10:00:00Z` | refuses | accepts, as 2 March |
| `2026-06-05T10:00:00+24:00` | accepts | refuses |
| `2026-06-05T10:00:00+24:60` | accepts, as an offset of -25 h | refuses |
| `2026-06-05T10:00:00+00:60` | accepts, as an offset of -1 h | refuses |
| `2026-06-05t10:00:00z` | refuses | accepts |

Each executor refuses all of these. The two sides are strict in the same way; neither
side copies the quirks of the other. `time.Parse` already examines the date and the
time, so `parseWireTime` adds only the check of the offset. No legitimate value is
refused, because each encoder writes `Z`. `Op.UnmarshalJSON` and `RawBody.UnmarshalJSON`
send their time fields through `parseWireTime`, so the lenient reader never sees them.

**Milliseconds.** `canonicalTime` changes a time to UTC and cuts it to milliseconds. It
cuts and does not round. The encoder and the decoder both apply it. A JavaScript date
holds milliseconds, so a finer value would make two ops a tie in one executor and not in
the other, and a tie goes to the writer id. The cut on decode is necessary because a
blob can come from a writer that this code does not control. Only the reader can
enforce the rule against such a writer.

**A canonical form that can be read again.** The grammar permits
`9999-12-31T23:59:59-23:59` and `0000-01-01T00:00:00+00:01`. In UTC they are in year
10000 and in year -1. The grammar cannot express those years, and the two languages
write them differently (measured):

| Wire value | Go `Format(RFC3339Nano)` | JavaScript `toISOString` |
| --- | --- | --- |
| `9999-12-31T23:59:59-23:59` | `10000-01-01T23:58:59Z` | `+010000-01-01T23:58:59.000Z` |
| `0000-01-01T00:00:00+00:01` | `-0001-12-31T23:59:00Z` | `-000001-12-31T23:59:00.000Z` |

Go once accepted the two wire values and the other executor refused them. Thus an op
could be in the log of one executor and of no device. These values are not malformed. A
bank does not send year 10000, but a hostile or broken `Date` header can.

The rule: the canonical form of an accepted timestamp must itself be an accepted
timestamp, for the same instant. The check is that round trip, not a comparison of the
year, so it cannot disagree with the renderer. Each executor refuses the two boundary
values and each expanded-year spelling. If an executor learns to write an expanded year,
it must not learn to read one: the other executor sets that blob aside.

- The check is in three places on purpose: `parseWireTime` (decode), `Op.Validate`
  (a hand-built op) and `EncodeBlob` (through `Validate`). Each one looks redundant
  beside the others. A mutation run once deleted the `Validate` check with all tests
  green; `TestTheExpandedYearRangeIsRefusedByBothExecutors` now calls each path.
  Without the check, the encoder fails inside `time.Time.MarshalJSON` (it refuses a
  year outside 0 to 9999) with an error that names no op and no field.
- `CanonicalWireTime` is the only renderer. A second renderer in another package is a
  second spelling, without the check.
- `conformance/op/manifest.json` pins instants, not strings, because the two encoders
  write different bytes for one instant. The one exception is `expect_canonical_wire`:
  the string that Go writes. The other executor must read it to the same instant, and
  Go must still produce it. The test asserts closure and idempotence over the published
  cases. It has no assertion that the canonical string agrees with the grammar regex:
  `parseWireTime` starts with that regex, so such an assertion cannot fail.
- `authored_at_rejects` is one shared list for the executors. It includes the two
  boundary values and the expanded-year spellings.

Applies to: `server/internal/oplog/opref/op.go` (`canonicalTime`, `CanonicalWireTime`,
`parseWireTime`, `rfc3339Shape`, `Op.Validate`, `DecodeBlob`),
`server/internal/oplog/opref/op_test.go`
(`TestWireTimeAcceptsExactlyWhatTypeScriptAccepts`),
`server/internal/oplog/opref/conformance_test.go` (`timeCase.ExpectCanonicalWire`,
`timeAcceptCases`, `timeRejectCases`, `TestCanonicalTimeIsClosedOverTheWireGrammar`,
`TestTheExpandedYearRangeIsRefusedByBothExecutors`).

## A parent_version above 2^53 is a pinned difference between the executors

`parent_version` is a JSON number on the frozen wire. Go reads an int64 above 2^53
exactly. The TypeScript executor could not: `JSON.parse` rounds the number before any
code sees it. This is a property of the format and not a defect of a port. The manifest
holds one blob with such a value (`parent_version_overflow_base64`). Go must accept it,
and the other executor must set it aside. The Swift port keeps the refusal.

The manifest gives the value as a decimal string, because a JSON number in the manifest
would have the same loss.

Do not change `parent_version` to a string on the wire. Old logs carry the number.

Applies to: `server/internal/oplog/opref/conformance_test.go`
(`opManifest.ParentVersionOverflowBase64`, `opExpect.ParentVersion`).

## Conformance fixtures are written on request and checked on every run

`conformance_test.go` writes `conformance/blob` and `conformance/op` from the Go
encoders, and reads them again on every run. The Swift port reads the same files.

- **The writer is opt-in** (`HASALA_WRITE_CONFORMANCE=1`, `TestWriteConformanceFixtures`).
  A test that writes its reference again on every run accepts each change of the code.
  The fixtures are committed.
- **A missing manifest is a failure, not a skip.** A skip switches the gate off without
  a sign.
- **The writer is in `opref`, not in `blob`.** `opref` imports `blob`. A writer in `blob`
  would need a second literal copy of the op JSON. `goldenOps` is the one literal, for
  the fixture and for `TestGoldenOpBytes`.
- **`conformance/ts` is frozen.** The ledgerd TypeScript client wrote it, and its
  generator was removed after commit `9b4aae2`. It cannot be written again. It is the
  only set that an executor other than Go sealed, thus it is the only proof that Go
  opens the bytes of another writer. A device uploads blobs that it sealed itself, so
  this is the direction that the server sees. The ops in it are compared by value.
- **A fixture is sealed again and compared byte for byte**
  (`TestConformanceFixturesReSealToTheCommittedBytes`). The read-only checks pass when
  the writer changes in a way that `Open` still accepts (another compression level,
  another pad byte, a wider bucket), and the `.bin` files and the manifest are written
  by one command, so they change together. The comparison is exact because
  `blobtest.PlaintextSealer.Seal` is deterministic: a zero nonce, zero padding and a gzip
  writer with no modification time. It does not replace the checks across executors: a
  defect in the two executors gives the same wrong bytes two times.
- **A new Go release can fail that test with no defect.** Gzip output is a property of
  the compressor, not of the format. If Go changes `compress/flate`, each stored blob
  still opens. Then confirm that the fixtures still open in Go and in Swift, and write
  the fixtures again.
- **Fixture input is the same on each machine.** The bytes that gzip cannot make smaller
  come from a SHA-256 chain, not from `math/rand`. The algorithm of `math/rand` is not a
  contract, and its global source has a random seed since Go 1.20.
- **A generated list is also counted, and its boundary entries are named in the test.**
  The manifest lists (the parent-free types, the accepted timestamps, the refused
  timestamps) come from lists in the test. If somebody deletes an entry and writes the
  fixtures again, the two executors stay green together. Thus the test compares the
  counts with the lists of this build, and names the entries that must stay: the
  year-0000 and year-9999 cases and the expanded-year refusals. It also examines the
  parent-free set in each direction, because a new op type arrives from the side of the
  build.

Applies to: `server/internal/oplog/opref/conformance_test.go` (`writeFixturesEnv`,
`TestWriteConformanceFixtures`, `readBlobManifest`, `readOpManifest`,
`incompressibleBytes`, `TestConformanceFixturesReSealToTheCommittedBytes`,
`TestOpConformanceManifestMatchesThisBuild`, `TestTypeScriptSealedBlobsOpenInGo`).

## Log reads: gaps belong to the writer chain, there is no watermark, and a clean pull is not proof

**Cursor.** The cursor of a client is the largest seq that it got for the stream. A hole
in the seqs that a reader follows is not a gap: seq is one order for each user, and the
rows of one writer are not contiguous in it. Gap detection is the job of the writer
chain (spec §3.3:65). A chain belongs to one writer and one stream, and its counters are
contiguous.

**No watermark.** An append takes the row lock of the user's counter as its first
statement and holds it until the commit. Thus commit order is seq order, and a committed
seq N means that each seq below N is committed. A reader always sees a complete prefix,
never a prefix with holes that fill later. Do not add a published watermark: the counter
row already gives that guarantee. If an append stops taking that lock first, a reader
can pass a seq that commits later, and a device loses that row.

**What a read does not prove.** The server serves these rows from bytes that it holds.
`VerifyChain` on the result proves only that the rows continue the head that the client
gave. A truncated log, an interior drop with a new chain, a different history and two
different answers to two devices all verify. To find those, a client needs a head that it
pinned independently of the answer: its own stored head, or a `writer_checkpoint` op
(spec §3.3(c), I11; `docs/decisions/sync-writer-checkpoints.md`). No caller can present a
clean pull as proof that the server served all rows.

Applies to: `server/internal/oplog/read.go` (`Read`, `Hashes`, `StreamMaxSeq`).

## The hash list carries prev_hash, ends on a batch boundary and is weaker than a chain check

The hash list (spec §3.3:72) gives the hashes of a stream with no blob body. Each entry
has `prev_hash` and `blob_hash`. With `prev_hash`, a client can examine the links
offline: for each writer, the `prev_hash` of an entry is the `blob_hash` of the entry
before it, and the first entry links to `blob.ZeroHash`. Without `prev_hash`, the list
cannot be examined without the bodies. The cost is 32 bytes for each entry.

This check is weaker than `VerifyChain`. The hashes are the server's, not computed from
bytes. A server that rewrites a body and its hash together gives a list with correct
links. The list finds an entry that is missing or out of order, and it gives the client a
value to compare with a later body.

A hash page ends on a batch boundary, as a pull page does (spec 02 §11.3;
`docs/decisions/code/server-api-3.md`). The query reads `limit + maxBatchTail` rows and
cuts the page at the first head-signed row at or after the limit.

Applies to: `server/internal/oplog/read.go` (`HashRow`, `Hashes`).

## The byte budget of a page is applied in the database, and the first row always goes

A blob can be 1 MB (`blob.MaxBucket`), so a row limit alone bounds nothing. A page also
has a byte budget (`maxBytes`), and the HTTP layer sets it from the answer that it will
write.

- **The budget is in the SQL** (`readPageSQL`). A `LIMIT` in SQL with a budget in Go
  bounds only what the process keeps. pgx reads a result set to its end when the caller
  stops the scan, so Postgres still sends each row that `LIMIT` selected: possibly half a
  gigabyte, of which the process discards almost all.
- **The window sum is over `size_bucket`**, a plain integer column. A row that the outer
  `WHERE` discards is never read from TOAST and never sent. The sum only grows with seq,
  so the budget always selects a prefix. A page with a hole would be much worse than a
  page that is too large.
- **The first row is always in the page** (`rn = 1`), whatever its size. If not, one blob
  larger than the budget gives an empty page each time, and the cursor of the client
  never passes it.
- **`Read` applies the budget again in Go.** The database did it already. The second
  check stays, so an edit of the query cannot make the process keep more than it
  promised.
- **The extension to the end of a batch is at most 7 rows** (`maxBatchTail`), because a
  batch holds at most 8 blobs (spec 01 §6.8). Change the two values together. The
  extension can exceed the byte budget (`docs/decisions/code/server-api-3.md`).
- A caller cannot know from the row count if the budget or the end of the stream ended
  the page. It must ask `StreamMaxSeq` (`docs/decisions/code/server-api-3.md`).

Applies to: `server/internal/oplog/read.go` (`readPageSQL`, `Read`, `maxBatchTail`).

## An operator notice names no person, and a notice that fails is dropped

`opsnotify` posts a notice for the operator to an ntfy topic. A notice has a fixed title
and a fixed message, and optionally a click URL (the operator console). It never carries
an email address, a bank, an account id or other data about a person. The topic and its
subscribers learn only that something occurred. Do not add a field from a request or
from an account to a notice.

One post has a limit of 10 seconds. `Post` reports a failure to its caller, and the
caller writes a log line and drops the notice. There is no retry and no queue. The notice
is only a hint: the early-access request stays on the waitlist in `hasalad console`.

Applies to: `server/internal/opsnotify/opsnotify.go` (package `opsnotify`, `Timeout`).
