# iOS core, money to projection: decisions from the code (2026-11-21)

These decisions were code comments under `ios/HasalaCore/Sources/HasalaCore/Money/`, `Norm/`,
`Outbox/`, `Primitives/` and `Projection/`. Code comments are
not permitted (`scripts/comment-lint.ts`), thus the decisions are here.

## Money arithmetic is checked and never traps

Money in storage and in the fold state is `Int64` minor units. Each sum, product and ratio
is computed in `Int128`, and the result comes back as an optional or as a thrown
`MoneyError.overflow` (spec 03c §1.3; spec 04 §2.4 R9).

The reason: plain Swift integer arithmetic stops the process on an overflow. An op in the
log can hold any amount that fits `Int64`. If the fold used `+` or `*` on such amounts, one
op could stop the app at each start. An overflow must be an answer that the caller handles
(`money_overflow`), never a crash. Do not use the plain operators on money in the fold or
in the projection. Use `MoneyMath`.

`SignedMinor` refuses `Int64.min`. Thus the negation of a signed amount cannot overflow.

Money on the wire is a JSON string of decimal digits. It is not a JSON number.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Money/Minor.swift` (`Minor`, `SignedMinor`),
`ios/HasalaCore/Sources/HasalaCore/Money/MoneyMath.swift` (`MoneyMath`).

## Money wire grammars are read over bytes, and v3 fields keep leading zeros

`MoneyGrammar` examines the UTF-8 bytes of a money string. It does not use a regular
expression. A regex `$` can match before a last newline, and `\d` can match Arabic-Indic
digits. Each of these would accept a string that another reader of the same op refuses.

There are two grammars, and both must stay:

- Fields that are new in v4: `^(0|-?[1-9][0-9]{0,18})$`, with the sign only where the field
  permits it, and a value in `Int64`. A leading zero, `-0`, `+1` and `1.0` are refused.
- Fields that come from v3 (`amount_minor`, `amount_home_minor`, the split amounts):
  `^[0-9]+$`, thus leading zeros are accepted, with the `Int64` limit that Go has
  (spec 03c §1.3).

The reason for the second grammar: the op log is append-only, and ops with the v3 form are
in it. If `parseV3` becomes strict, those ops and the v3 fixtures stop reading.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Money/Minor.swift` (`MoneyGrammar.parseV4`,
`MoneyGrammar.parseV3`).

## Minor-unit exponents are for display, never for the fold

`MinorExponent.v1` gives the number of minor digits of a currency. Only display and the
reading of typed amounts use it (spec 03c §1.4). The fold does not use it.

The table has a version and changes with the app. A change of the table is an app update,
not an op. If the fold used the table, two builds with different tables would fold the same
log to different states.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Money/Minor.swift` (`MinorExponent`).

## Money text uses integer arithmetic and no NumberFormatter

`MoneyFormat` makes and reads money text with integer arithmetic only. It uses no `Double`
and no `NumberFormatter`. A `NumberFormatter` takes its grouping and its rounding from the
locale. Money text must be the same on each device, and it must never round.

A typed amount becomes minor units exactly, or it is refused. It is never rounded or
clamped to a different amount from the one that the person typed.

A refusal is a code (`DraftRefusal`), not a sentence. The text that the person sees is in
the string catalogue of the app.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Money/MoneyFormat.swift` (`MoneyFormat`).

## A charset that needs a multi-byte codec is refused, not guessed

A declared charset label has one of four results:

- `passthrough`: the bytes go to stage 3 with no decoding.
- `unresolved`: the same, with an unknown-charset error. The top-level entity tolerates
  this error. In a sub-part it stops the walk.
- `singleByte`: the bytes are decoded through one generated table of 256 entries.
- `unsupported`: the normalizer throws `unsupportedCharset`.

`unsupported` is each charset that Go decodes with a stateful or multi-byte codec (UTF-16,
Shift_JIS, GB*, ISO-2022-*). No other implementation gives the same bytes as those Go
codecs. Thus Swift refuses these charsets, and the caller sends the message to Review.
Nothing is dropped.

Do not decode such a message with a Foundation encoding. The text would differ from the
text of Go, and a template could then match text that the oracle never saw.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Norm/Charset.swift` (`CharsetKind`,
`Charset.classify`), `ios/HasalaCore/Sources/HasalaCore/Norm/MIME.swift`
(`MIMEFailure.unsupportedCharset`), `ios/HasalaCore/Sources/HasalaCore/Norm/Normalizer.swift`
(`NormalizeError.unsupportedCharset`).

## The normalizer pins each platform-dependent text operation

The output of the normalizer (spec 04 §2.2) must be the same, byte for byte, as the output
of the Go normalizer (`server/internal/norm`) for the same input. The reason: a template
match on the phone and a template match in the oracle must be the same match. The fixtures
in `conformance/normalizer` and the real-corpus set in the private fixtures prove it.

Thus no text operation uses a platform default (spec 04 §2.4 R2):

- No `lowercased()`, no `trimmingCharacters`, and no `String` comparison or search. Swift
  `String` equality is canonical equivalence: U+037E is equal to `;`. A charset label is
  first examined for ASCII, and a label that is not ASCII is unresolved.
- All text work is on bytes or on Unicode scalars, never on `Character`. Header values stay
  bytes until `decodeWords` makes them text.
- The trim sets are written in full.
- The charsets come from tables that are generated from the registry of Go
  (`CharsetTables.swift`).
- The entity decoder knows exactly six entities. It makes one pass from left to right and
  does not read its own output again: `&amp;lt;` becomes `&lt;`, not `<`.
- A forwarded date must agree with one of four closed layouts.
- A match that ignores case follows the `(?i)` of Go. ASCII letters fold. U+017F folds to
  `s` and U+212A folds to `k`, because these two are the only other members of the simple
  fold of an ASCII letter.
- `NormText.decodeUTF8` keeps a U+FEFF at the start, and the trim of stage 8 removes it
  where it is. `UTF8Text.decode` in CorePrimitives removes it. Do not use `UTF8Text` in the
  normalizer.
- `NormText.jsLower` does not apply the Final_Sigma rule. The rule changes only U+03A3.
  `jsLower` is used only on charset labels and media-type values, and these cannot usefully
  contain that letter. Do not use `jsLower` on other text.

A change that replaces one of these with a standard library call can change the normalized
text for some mail. Then a template stops matching, or it matches different text from the
oracle.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Norm/Normalizer.swift`,
`ios/HasalaCore/Sources/HasalaCore/Norm/NormText.swift` (`NormText.decodeUTF8`,
`NormText.jsLower`), `ios/HasalaCore/Sources/HasalaCore/Norm/Charset.swift`
(`Charset.classify`), `ios/HasalaCore/Sources/HasalaCore/Norm/Unwrap.swift` (`Unwrap.foldCI`).

## The MIME reader reproduces Go's reader, with its leniencies and its error classes

`MIME.swift` implements again the part of Go that the Go normalizer uses:
go-message/textproto, `mime.ParseMediaType`, `mime/quotedprintable`, strict base64,
`mime.WordDecoder`, the address cascade and the multipart reader. It works on bytes.

It reproduces the leniencies of Go. Do not correct them to the RFC. For example, the
quoted-printable decoder has the four deviations of Go: a soft `=` before a bare LF; a bare
CR or LF passes through; a last `=` at the end of the input after content is dropped; and
an `=` without two hex digits is literal unless CR or LF follows. White space is removed
before a hard break and kept before a soft break.

It also reproduces which error occurs at which place. The class of the error decides the
result:

- `leafDecode`: the body of one leaf did not decode. The leaf is skipped.
- `walkAbort`: a sub-part could not be made. The walk stops, and the text that was already
  collected stays.
- `parse`: the header block did not parse. The normalizer uses the raw body.

`MIME.Entity` decides at its creation if a transfer decoder exists. An unknown encoding is
an error there, and in a sub-part it stops the walk. The entity decides if the decoder
succeeds only when the text is read, and a failure there skips the leaf. Do not move one of
these checks to the other place. That changes a skipped leaf into a stopped walk, or the
reverse, and the phone then reads a different part of the mail from Go.

There is one accepted difference. Where Go keeps invalid UTF-8 from an encoded word with a
wrong `utf-8` label, `decodeWords` gives U+FFFD.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Norm/MIME.swift` (`MIMEFailure`,
`MIME.decodeQuotedPrintable`, `MIME.decodeWords`, `MIME.Entity`),
`ios/HasalaCore/Sources/HasalaCore/Norm/Normalizer.swift` (`Normalizer.Walker.walk`).

## A normalized subject and From are content, never identity

`subject` and `from` in a `NormalizeResult` are the effective values. For an inline
forward, they are the inner values, and the normalizer reads them from the body text.
Anybody can write that text.

Thus these fields are content. They are for template matching only. They are not proof of
the sender. Trust comes only from the Authentication-Results verdict of CoreMail, and
nothing in the normalizer gives trust. `forwarded` says only that a forward marker line was
found. It does not say that inner headers were recovered.

If a later change uses the normalized `from` to decide trust, a person can forge a bank
mail with a forwarded block in the body.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Norm/Normalizer.swift` (`NormalizeResult`),
`ios/HasalaCore/Sources/HasalaCore/Norm/Unwrap.swift` (`Unwrap.unwrapForward`).

## A normalizer version is never removed

`Normalizer.versions()` lists each normalizer version that the build can run, oldest first.
A new algorithm gets a new number. An old version stays in the build.

The reason: a template names its normalizer version (`normalizer_version`). A template
that was written for an older version must read the same text as before.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Norm/Normalizer.swift`
(`Normalizer.versions`, `Normalizer.currentVersion`).

## The HTML strip stays linear on a hostile body

Anybody can write a mail body. The normalizer must not take quadratic time on it.

- `ForwardScan` finds the next `>` (and each `</tag>`) with a pointer that only moves
  forward. A body that is full of `<` with no `>` stays linear.
- `collapse` builds its output in an array of scalars, not in a `String.UnicodeScalarView`.
  An append to the view examines the end of the string each time. That made the function
  quadratic on a body with many short lines.

Do not replace these with a search from the current position or with a direct append to a
string.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Norm/Normalizer.swift`
(`Normalizer.ForwardScan`, `Normalizer.collapse`).

## A forwarded header's value can be on the next line

Apple Mail writes an inner header of a forward as a label line, and it puts the value on
the next line that is not empty. `Unwrap.unwrapForward` reads the value there when the
label line has no value. Without this step, a mail that was forwarded from Apple Mail loses
its inner Subject, Date and From.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Norm/Unwrap.swift` (`Unwrap.unwrapForward`).

## The outbox validates before it writes and accepts work while latched

`Outbox.enqueue` (spec 04 §5.4) validates each op (`OpCodec.validateOp`) and refuses an op
whose canonical JSON is larger than 8 KiB (S7), before it writes a row. The reason: ops
travel together in one blob. One bad op in a blob would make each device lose the whole
blob.

Then all the ops become `pending_ops` rows in one transaction. They are durable when
`enqueue` returns. A debounced trigger (1.5 s) then asks for a sync run.

While the outbox is latched, `enqueue` still succeeds and the flush does nothing. The app
shows the latch banner. The reason: local work is never lost. Do not make `enqueue` fail
because of the latch.

Only HasalaCore code can make an `Op` (its initializer is `package`, R5). `OpAuthor` in
CoreDomain is the author.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Outbox/Outbox.swift` (`Outbox.enqueue`).

## AES-GCM takes only a 32-byte key and a 12-byte nonce, and open gives one error

`AESGCM.seal` and `AESGCM.open` examine the lengths themselves: a key of 32 bytes and a
nonce of 12 bytes (spec 01 §1 and §2). CryptoKit also accepts keys of 16 and 24 bytes and
nonces of other sizes. A frame that was sealed with one of those would not open on the
other implementations. Do not remove the checks because CryptoKit "already validates".

The output of a seal is the ciphertext followed by the tag. The framing of the caller
carries the nonce.

When `AESGCM.open` fails, the error is always `PrimitivesError.authenticationFailed`. A
wrong key, nonce, AAD, tag or ciphertext, and an input shorter than the tag, all give this
one error. The error must not say which part was wrong, so that it is not an oracle for a
person who changes bytes. Only a key or a nonce of the wrong length is a different error,
because that is a bug of the caller and not a property of the input.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Primitives/AESGCM.swift` (`AESGCM`),
`ios/HasalaCore/Sources/HasalaCore/Primitives/Hashing.swift`
(`PrimitivesError.authenticationFailed`).

## Text codecs refuse what they cannot read exactly

The hex, base64, base64url and base32 decoders are strict (spec 01 §1). They work on the
UTF-8 bytes of the string, never on `Character`.

The reason: a lenient decoder (`Data(base64Encoded:)` with options, and the usual decoders
of other platforms) skips each character that is not in the alphabet. It returns a result
that is short and looks correct. A damaged hash of 64 characters becomes 20 bytes. Each
decoder here refuses such input. Do not replace one with a Foundation decoder.

The rules that are not obvious:

- Hex is lower case only. The chain hashes are lower case on the wire.
- Standard base64 accepts bits that are not zero in the unused low bits of the last
  character. Go's `StdEncoding` accepts them, and the decoder must agree with the oracle.
- base64url accepts padding or no padding, but only the correct quantity of padding at the
  end. Gmail's `format=raw` sends base64url with no padding. `+` and `/` are refused and
  never changed to `-` and `_`.
- base32 is upper case with no padding, and the unused bits at the end must be zero. Thus
  each byte string has exactly one accepted spelling. The caller normalizes what a person
  typed (hyphens, case) before it decodes.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Primitives/Codecs.swift` (`Hex`, `Base64`,
`Base32`).

## Logs and errors carry counts and states, never user data

`CoreLog` is the only logger of the core (spec 01 §11.6; spec 04 §2.4 R7). Its types permit
only safe calls:

- The event is a `StaticString`. It is written in the source and cannot contain user data.
- A field is a count, a static state name, or a string that is logged `.private`. No field
  takes an arbitrary value. Thus a secret type (`SecureBytes`, a key, a phrase) cannot go
  into a log line, and no `String` goes into the public part of a line.

R7 also applies to the `.private` part. Amounts, merchants, email addresses, Gmail ids,
tokens, keys and phrase words are never logged, not even as private. Diagnostics contain
counts and states only.

Errors obey the same rule. A `CodecError` has the name of the codec and never the input,
because the input can be a key or a message body. A `PrimitivesError` never has key bytes
or payload content. The message of a precondition has no amount.

Do not add a field kind that takes a value, and do not add the input to an error. A device
log or a crash report could then show money data or key material.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Primitives/CoreLog.swift` (`CoreLog`,
`CoreLog.Field`), `ios/HasalaCore/Sources/HasalaCore/Primitives/Codecs.swift`
(`CodecError`), `ios/HasalaCore/Sources/HasalaCore/Primitives/Hashing.swift`
(`PrimitivesError`).

## Gzip is the system zlib at level 9, and compressed bytes are not compared

`Gzip.compress` calls the system zlib with the parameters of spec 01 §2:
`deflateInit2(level 9, Z_DEFLATED, windowBits 31, memLevel 8, Z_DEFAULT_STRATEGY)`.

- It does not use Compression.framework. `COMPRESSION_ZLIB` there is raw DEFLATE at a fixed
  level. It has no gzip header, no CRC and no level control (spec 01 §6.7).
- The level is part of the contract. The sealer compresses at 9, and the compressed length
  decides the size bucket of a frame. A different level gives a different bucket.
- The gzip header that zlib writes is deterministic (mtime 0, no name), but its OS byte is
  the `OS_CODE` of the build: 19 on Apple and 3 on the Linux builds that sealed
  `conformance/ts`. Thus a test must compare the decompressed payloads. It must not compare
  the compressed bytes.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Primitives/Gzip.swift` (`Gzip.compress`,
`Gzip.level`).

## Gunzip enforces its cap during inflation and reads one member

`Gzip.decompress` refuses output that is larger than `maxOutputBytes`, and it does this
while it inflates. It never inflates all the data and then measures. The reason: an
attacker can influence a blob, and the largest bucket (1 MiB) can hold a stream that
inflates to about one gigabyte. Memory use stays at the cap plus one chunk. Output of
exactly `maxOutputBytes` is accepted, and one more byte is refused.

The input must be exactly one gzip member. A truncated member, a bad CRC-32 or ISIZE
trailer, and bytes after the member are all refused. zlib examines the trailer. Go's
multistream reader would read a concatenation of members, but no producer writes one, and
the phone does not accept one.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Primitives/Gzip.swift` (`Gzip.decompress`,
`GzipError`).

## Randomness comes through RandomSource and has no fallback

Production code takes a `RandomSource` (spec 04 §2.4 R1 and R8). Tests give a seeded
source. `Random.swift` and the CoreTime adapters are the only places that call the system
source, and `ios/scripts/check-imports.sh` keeps `SecRandomCopyBytes` to CorePrimitives and
CoreCrypto.

`SystemRandom` calls `SecRandomCopyBytes`. A status that is not success is the error
`randomUnavailable`, and the operation fails (spec 01 §1). The code never tries again with
a weaker source, and a fill is never partial. A fallback would make keys, nonces and writer
ids from predictable bytes, with no sign that it occurred.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Primitives/Random.swift` (`RandomSource`,
`SystemRandom`), `ios/HasalaCore/Sources/HasalaCore/Primitives/Hashing.swift`
(`PrimitivesError.randomUnavailable`).

## Account ids and writer ids have one spelling

A `UserID` is the lower-case RFC 4122 text of 36 characters (`uuid_str`) and its 16 bytes
in network order (`uuid_raw`). A `WriterID` is `ios-` and a lower-case UUID of version 4,
exactly 40 ASCII characters (spec 01 §1 and §4.8). The two types examine the value when
they are made, thus each value is one that the wire accepts.

- Do not use Foundation's `UUID().uuidString`. It is upper case, and the AAD, the envelopes
  and each signed message refuse upper case. `RandomSource.uuidV4` makes the lower-case
  text from random bytes.
- A writer id contains no `|` and no `0x00`. `|` is the separator of the AAD, and `0x00` is
  the separator of the signing messages. This keeps each encoding that contains a writer id
  to one reading. Do not add a character to the grammar without this check.
- A writer id is made one time for each enrolment, from random bytes. It never comes from a
  device name, and it is never used again for a different enrolment.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Primitives/Identifiers.swift` (`UserID`,
`WriterID`, `WriterID.mint`), `ios/HasalaCore/Sources/HasalaCore/Primitives/Random.swift`
(`RandomSource.uuidV4`).

## SecureBytes zeroes with memset_s and shows no content

`SecureBytes` (spec 01 §11.5) owns the buffer of a secret and zeroes it when it is
released. The zeroing is best effort, as `docs/decisions/code/ios-crypto.md` records.

- The zeroing uses `memset_s`. The optimizer can remove a plain loop that stores zeros into
  memory that is about to be released. It does not remove `memset_s`. Do not replace it
  with a loop or with `memset`.
- The type shows no content. `description` and `debugDescription` give `<redacted>`, and
  the type is not `Codable` and not `Hashable`. Do not add these conformances: a secret
  could then go into a log, an archive or a dictionary key.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Primitives/SecureBytes.swift`
(`SecureBytes`).

## The projection database is plaintext money data, and only CoreProjection holds it

`projection.sqlite` (spec 04 §4.3) holds the folded ledger in plaintext. It is in the store
directory of the account, and it must have the same file protection and the same backup
exclusion as the store (spec 04 §4.1). `LedgerPageObserver.open()` in CoreSync sets the
file protection and the backup exclusion of the directory again, and it marks the database
file. Thus open the observer before the first projection is read. A projection file that
is made without these attributes can go into a device backup as plaintext.

CoreProjection and CoreStore are the only users of GRDB (R6;
`ios/scripts/check-imports.sh`). The sync layer and the app hold a `ProjectionStore` value
and never a database handle. `LedgerReader` only reads, and it returns plain values.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Projection/ProjectionStore.swift`
(`ProjectionStore.open`), `ios/HasalaCore/Sources/HasalaCore/Projection/CoreProjection.swift`.

## The projection is derived: a version change rebuilds it

The projection is derived from the fold. It is never migrated. When the
`projection_version` in the file is different from `ProjectionSchema.version`, the
projector drops each table and each view and projects again.

Thus increase `ProjectionSchema.version` for each change to a table, a view or a derived
column. Without the increase, a phone that updates keeps the old tables, and the readers
fail or show old values.

`ProjectionSchema.create` must drop the tables of any older layout, with any names and
references. It sets `PRAGMA defer_foreign_keys = ON`, which SQLite applies inside the
transaction of the caller, so that foreign keys are examined only at the commit. It also
drops children before parents. With the two, no drop order of an older layout can fail on
a reference.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Projection/Schema.swift`
(`ProjectionSchema.version`, `ProjectionSchema.create`).
