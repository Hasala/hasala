# iOS core test support, text, time and wire: decisions from the code (2026-11-21)

These decisions were code comments under `ios/HasalaCore/Sources/HasalaCore/TestSupport/`,
`ios/HasalaCore/Sources/HasalaCore/Text/`, `ios/HasalaCore/Sources/HasalaCore/Time/`,
`ios/HasalaCore/Sources/HasalaCore/Wire/` and `ios/HasalaCore/Tests/`. Code comments are
not permitted (`scripts/comment-lint.ts`), thus the decisions are here.

## The fakes copy what the client can observe of each provider

`FakeGmail`, `FakeGraph` and `FakeServer` (spec 04 §2.2, CoreTestSupport) answer
`HTTPExchange`. Thus the tests run the production request builders and response parsers.
Each fake copies the behaviour of the real system that the client can observe. Do not make
a fake more helpful than the real system: the client would start to depend on something
that production does not give, and the tests would stay green.

Gmail and Google OAuth:

- The token endpoint gives a refresh token only on the `authorization_code` grant. A
  refresh does not give it again.
- The `id_token` is a real three-part JWT with `email` and the `nonce` of the last
  authorize URL.
- Raw messages are base64url with no padding.
- `messages.list` gives the newest message first.
- A listing with no sender filter gets a 400. The phone must list only the bank senders,
  and this makes a test fail if the client sends an unfiltered listing.

Microsoft Graph and the consumers token endpoint:

- Each refresh gives a new refresh token, because Microsoft rotates them.
- A subscription answer does not give `clientState` back (it is `null`).
- `expirationDateTime` has seven fractional digits. The client parser must accept this
  form.
- A `$filter` with `endswith` gets 400 `ErrorInvalidUrlQueryFilter`, as Outlook.com
  answers (`docs/decisions/outlook-mailbox.md`). A listing with no filter gets a 400.
- A second `created` subscription on the same resource gets a 409.

`FakeServer` copies the paths, JSON names, error codes and check order of `02` §7, and the
checks that keep the server blind (`02` §11.1). It is simple where the client cannot
observe a difference:

- It compares the password verifier as `SHA256(S)`. The real server runs PBKDF2 under a
  pepper.
- It has no rate limiters and sends no email. A test reads the email code from the fake.
- Its WebAuthn check examines only the type, the challenge, the origin, the RP ID hash,
  UP/UV, the ES256 signature and the sign count.

A test against `FakeServer` does not prove a property of `hasalad`. The Go tests prove
those.

Applies to: `ios/HasalaCore/Sources/HasalaCore/TestSupport/FakeGmail.swift`,
`ios/HasalaCore/Sources/HasalaCore/TestSupport/FakeGraph.swift`,
`ios/HasalaCore/Sources/HasalaCore/TestSupport/FakeServer.swift`.

## Stored text is ordered and matched by bytes

Swift compares two `String` values by Unicode canonical equivalence over grapheme
clusters. The NFC and NFD spellings of a text compare equal, and the order is not byte
order. Go's `strings.Compare` uses byte order, and the conformance fixtures were written
with byte order (spec 04 §2.4 R2).

All code that orders or matches stored text must use the helpers in `Text/Compare.swift`
(`compareUTF8`, `utf8Equal`, `ExactKey`, `runeCount`, `ASCII`). Do not use `String <`,
`String ==` on content, `Character` or a locale-aware API there. If a device orders or
matches text differently from Go, the two give different output for the same log. The
grep lint (`ios/scripts/check-forbidden.sh`) cannot see `String <`, thus review must.

`compareScalars` orders by Unicode scalar value. For well-formed text this is the same
order as `compareUTF8`. It is not the UTF-16 code-unit order of JavaScript's `<`, which
puts a supplementary-plane scalar below U+E000. Do not use one in place of the other.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Text/Compare.swift`.

## Whitespace and trim sets are fixed lists

Each whitespace set and each trim set is a fixed list of scalars, written out in
`ScalarSet` (spec 03c §1.6). None of them is Foundation's `CharacterSet.whitespaces` or
`whitespacesAndNewlines`, which are different from all of them and can change with the OS.
There is one named set for each set that the Go code or the reference client used, so a
port uses the set that it means.

The sets are not the same as each other. Go's `unicode.IsSpace` (`goSpace`, 25 scalars)
contains U+0085 and does not contain U+FEFF. JavaScript's `\s` and `trim` (`jsTrim`) do
the reverse. `conformance/dict/matching.json` pins Go's answers.

Do not replace a named set with a Foundation set, and do not merge two sets. The result
would be output that does not agree with Go or with the golden files.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Text/ScalarSet.swift`.

## The fold uses no Unicode table of the OS

Every device and every OS version must fold the same log to the same state (spec 03c
§1.11). Thus the fold can run only checks that do not depend on the Unicode tables of the
OS.

- `TextRules` (the `Label`, `Note` and `Token` grammars of spec 03c §1.6) does structural
  checks only: lengths in scalars and in UTF-8 bytes, a fixed list of forbidden scalars
  and a fixed list of edge spaces. It does no NFC check and no category lookup. NFC
  normalization and trimming are the work of the author, before these checks.
- `GoCase.lower` gives Go's `unicode.ToLower` (the simple case mapping). Swift has only
  the full mapping, and the function takes its first scalar. This depends on the Unicode
  tables of the OS. Use it only for the categorization canon. Do not use it in the fold.
- The forbidden list contains the bidi embeddings, overrides and isolates. It does not
  contain LRM, RLM and ALM (U+200E, U+200F, U+061C). Arabic text needs them. Do not add
  them to the list: labels that are already in the log would become invalid.

If the fold uses an OS table, two iPhones on different iOS versions can give different
states for one log.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Text/TextRules.swift`,
`ios/HasalaCore/Sources/HasalaCore/Text/ScalarSet.swift` (`forbidden`),
`ios/HasalaCore/Sources/HasalaCore/Text/Compare.swift` (`GoCase`).

## Dates use integer arithmetic, not Foundation

Each date computation that reaches the wire or the fold uses the integer arithmetic of
`Civil` (the proleptic Gregorian calendar, with the `days_from_civil` and
`civil_from_days` algorithms of Howard Hinnant). It does not use Foundation.

The reasons: Foundation's Gregorian `Calendar` changes to the Julian calendar before
1582-10-15, and `DateFormatter` and `ISO8601DateFormatter` bring a locale, a time zone and
rounding. With them, two devices can give different dates for one instant, and the result
would not agree with Go.

The raw functions have limits. `daysFromCivil` is defined for a year below 2^53 in
absolute value, and `civilFromDays` for a day count below 2^62. Each caller must bound its
input first. `CivilDate` holds only the years 0 to 9999, and the wire parser reads four
year digits. A new caller that does not bound its input can trap on overflow.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Time/Civil.swift`,
`ios/HasalaCore/Sources/HasalaCore/Time/CivilDate.swift`.

## The local clock is UTC+04:00 on every device

The local clock is one fixed offset, UTC+04:00 (Asia/Dubai, no daylight saving time), on
every device (spec 03c §1.5). It does not use the time zone of the device. The reason: two
devices in different time zones must put a transaction in the same budget month.

`today` is read one time for each query or render. It is never read in the fold or in the
projection, because their output must depend only on the log.

The v3 duplicate fingerprint is the exception to the local day. It uses the UTC day of
the instant (`Civil.utcDay`), as it did before the local clock. Do not change it to the
local day: the fingerprints of rows near midnight would change, and copies would not be
found.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Time/CivilDate.swift` (`LocalClock`),
`ios/HasalaCore/Sources/HasalaCore/Time/Civil.swift` (`utcDay`).

## The chain hashes the stored frame, and linkage needs a pinned head

The hash chain (spec 01 §7) is `blob_hash[c] = SHA256(blob_hash[c-1] ‖ frame[c])`, with 32
zero bytes before counter 1, for each user, writer and stream. It hashes the stored bytes:
the frame with its padding, not the plaintext. Thus the server can compute the chain again
without a key. Do not change the input to the plaintext or to a part of the frame.

What the linkage proves is limited:

- In a fetched range, it shows a dropped row, a changed order, a substituted row and a
  forged `prev_hash`.
- It does not show a cut at the end of the chain, and it does not show a history that was
  chained again from the start. For these, the device must compare with a head that it
  pinned. The associated data of a v3 frame also binds `prev_hash`, so a history that was
  chained again fails AEAD at the first changed frame.
- A hash list with no bodies proves the linkage only. It does not prove that a hash
  belongs to any bytes. The bodies must be examined against the pinned hashes when they
  are fetched (`verifyFetchedRange`).

Applies to: `ios/HasalaCore/Sources/HasalaCore/Wire/Chain.swift`.

## A checkpoint payload has one byte form

The `writer_checkpoint` payload is the one payload whose bytes all executors must agree
on. Thus it has one canonical form: the heads are sorted by `(writer_id, stream)` in UTF-8
byte order, each pair occurs one time, and the keys of each head are in the order of Go's
struct (`writer_id`, `stream`, `counter`, `hash`). The encoder sorts and refuses a
duplicate. The decoder refuses a payload that is not in this order.

Do not relax the decoder and do not change the order. Devices would then disagree on a
checkpoint. The beta writes no checkpoints (`docs/decisions/sync-writer-checkpoints.md`).

Applies to: `ios/HasalaCore/Sources/HasalaCore/Wire/Checkpoint.swift`.

## HeadCheck is in CoreCrypto, not in CoreWire

This is a deviation from spec 01 §12.1 and spec 04 §2.2, which put `HeadCheck` (R2b) in
CoreWire. It is in CoreCrypto (`Crypto/DeviceKeys.swift`). `HeadCheck` builds the head
signing message, and all signing messages are built in CoreCrypto (spec 01 §10.1). CoreWire
cannot import CoreCrypto. One builder for each signed byte string is more important than
the module placement.

CoreWire is a byte-exact module (spec 04 §2.4 R2). It hashes and verifies only. All code
that needs a key is in CoreCrypto. Do not add a key or a second builder of a signing
message to CoreWire.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Wire/`,
`ios/HasalaCore/Sources/HasalaCore/Crypto/DeviceKeys.swift` (`HeadCheck`).

## The v1 frame code only reads fixtures

`FrameV1Reader` reads the ledgerd v1 frame and the v1 raw-body record. It exists only to
read the fixtures in `conformance/blob` and `conformance/ts`. It cannot write a v1 frame,
and no Hasala server accepts one (`LooksSealed` refuses version 1). Do not add a v1
writer, and do not use the reader on data from the server.

The v1 code and the v3 code stay separate. The v1 layout has `aad_len` at bytes 1 and 2.
In a v3 frame these bytes are part of the key epoch. A v1 helper on a v3 frame would read
a wrong length. `FrameV1Reader` refuses version 3. The v1 associated data is
`user|stream|writer|counter` with any writer id and either stream, so the v1 envelope is
not the v3 envelope.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Wire/FrameV1Reader.swift`,
`ios/HasalaCore/Sources/HasalaCore/Wire/FrameV3.swift`.

## An op comes only from a decoder or from OpAuthor

The memberwise initializer of `Op` is `package`, not `public` (spec 04 §2.4 R5). Outside
HasalaCore, an op can come only from a decoder or from `CoreDomain.OpAuthor`. Do not make
the initializer public. The op log is append-only, and an op that the app or an extension
builds by hand would go around the rules of the author and stay in the log permanently.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Wire/Op.swift` (`Op`).

## The op codec's bytes and messages are fixed

Three properties of `OpCodec` must not change.

**The bytes.** `encodeBlobOps` writes the bytes that the reference client's
`JSON.stringify` wrote for the same ops. The keys of the envelope are in the order of Go's
struct: `v`, `type`, `op_id`, `authored_at`, `entity`, `parent_version`, `ingest_id`,
`payload`. The payload uses JavaScript's key order and number spelling (the defaults of
`CoreJSON.JSONWriter`). Each `authored_at` is made canonical (`.sssZ`). The conformance
suite compares the output with the sealed blobs of `conformance/ts`, and
`conformance/swift/op-manifest-v4.json` has the bytes for the other executors. The number
tables in `CoreJSONTests` are the output of `JSON.stringify(JSON.parse(literal))` under
Bun. Do not change them by hand.

**The messages.** The reason of a blob that was set aside is written to
`state.unreadable[].reason`, and the serialized state contains it. Thus two executors must
give the same message for the same bytes. Each message of the decoder is the text of the
reference, with the rendering of the bad value by `showValue`. The order of the checks is
also the order of the reference, because the first failure gives the message: `validate`
examines the fields in that order, a bad `authored_at` is reported without the `op i:`
prefix, and the parts of a timestamp are examined in a fixed order with the offset last. A
changed text or a changed order changes the state that the conformance fixtures pin.

**The blob is the unit of decode** (spec 01 §6.6 R10). An envelope failure of one op sets
the whole blob aside, its valid ops included. An op or a blob with `v` exactly one above
`SchemaVersion.current` is the result "newer version", which stops sync ("Update Hasala")
under the rule of `docs/decisions/op-version-ceiling.md`. A larger `v` sets the blob
aside. Do not mix these two results.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Wire/OpCodec.swift`,
`ios/HasalaCore/Tests/CoreJSONTests/CoreJSONTests.swift`.

## A pulled row with a bad shape is tampering

Reader check R0 (spec 01 §6.6) examines the shape of a pulled row before the row is hashed
or opened: the stream, the writer id grammar, the decimal counter, the size bucket and the
two 32-byte hashes. A failure is a hard stop (`tampered`, `rowShape`), not a set-aside.

The reason: the CHECK constraints of the server's database already enforce each of these
rules. An honest server cannot serve a row that breaks one. Thus the rules of R0 and the
CHECK constraints must stay the same. If the server starts to accept a new shape (for
example a new stream or a new size bucket), builds with the old R0 stop sync on it.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Wire/RowShape.swift`.

## The model tier timeout test has no wall-clock bound

The test of a hung model call (`modelTimeouts`) uses a call timeout of 200 ms. It does not
measure how long the sweep took. It examines that the sweep returned while the hung call
was still pending. A bound on elapsed time fails on a busy CI runner. Do not add one.

Applies to: `ios/HasalaCore/Tests/CoreCategorizeTests/CoreCategorizeTests.swift`
(`modelTimeouts`).
