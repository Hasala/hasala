# iOS core, Domain to Mail: decisions from the code (2026-11-21)

These decisions were code comments under `ios/HasalaCore/Sources/HasalaCore/Domain/`,
`Invariants/`, `JSON/`, `Keychain/` and `Mail/`. Code comments are
not permitted (`scripts/comment-lint.ts`), thus the decisions are here.

## Every author of an account shares one stamp memory

`AuthorStamps` holds the newest `authored_at` that this device gave to an op of its writer
(03c §1.8.2, the `own_last_ms` input). The outbox and the fold do not always show that
stamp: a blob can be built and not enqueued yet, or acknowledged before the self-pull
folded it.

All authors of one account use one instance. This includes the screens
(`LedgerPageObserver.stamps`) and the mail lane (`MailboxAuthoring`). Each blob is built
inside `authoring`, which holds the lock from the read of the floor to the record of the
last stamp of the blob. Thus two blobs that start before either is enqueued never get the
same stamp.

Do not give an author its own instance, and do not read the floor outside the lock. Then
two blobs of one writer can carry the same `authored_at`. The closure runs with the lock
held. It must only build blobs. It must not wait for I/O or for another task.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Domain/Author/AuthorStamps.swift`
(`AuthorStamps`, `authoring`).

## An op is checked before it is enqueued and is at most 8 KiB

`OpAuthor` is the only constructor of ops that code outside HasalaCore can reach (spec 04
§2.4 R5, §5.4; 03c §10; 03a §9). The server does not validate a payload, so the author is
the only check before an op goes into the append-only log. Each op that `build()` returns:

- has `v = SchemaVersion.author` and a ULID `op_id`;
- has a stamp from the author rule of 03c §1.8.2:
  `authored_ms = max(now, min(own_last, now + 24 h) + 1, seen + 1)`, then +1 for each next
  op of the blob. `seen` ignores writers whose newest stamp is more than 24 hours ahead, so
  one writer with a wrong clock does not move all later stamps;
- passed `validateOp` and the payload decoder of the fold (`Replay.payloadProblem`);
- is at most 8 KiB of canonical JSON (04 §5.4 S7, `opTooLarge`). This limit is a privacy
  guard: the body of an email can never go into an op.

An op that fails a check is an author bug. The call throws and nothing is enqueued (03c §2,
AT-30). Do not remove a check, and do not raise the size limit to make a large payload
pass.

User text (each `Label` and `Note`) is NFC-normalized and trimmed in the author (03c §1.6).
Text that is still outside its grammar is a `refused`, which the screen shows to the
person. It is never an `invalidOp`, because it is not a bug.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Domain/Author/OpAuthor.swift` (`OpAuthor`,
`OpAuthor.build`, `AuthorContext.baseMs`, `AuthorError`).

## A mailbox supersede keeps the person's category

A `txn_superseded` replaces a live row when the phone reads the same email again, for
example after a template fix. When the category source of the replaced row is `user` or
`held`, the author puts the category and the source of that row into the new payload (03c
§3.1 "Mailbox supersede"). Only for other sources does the new reading decide the category.

The reason: a new reading of an email must never remove a choice that the person made. If
this step is removed, each template fix sends sorted rows back to Review.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Domain/Author/OpAuthor.swift`
(`OpAuthor.ingest`, `OpAuthor.supersedeFields`).

## Rule patterns keep the merchant's own bytes

The author normalizes user text to NFC, but it does not normalize the patterns of a rule.
The matcher compares bytes, and `Canon` keeps the NFC and the NFD spelling of a merchant
apart. Thus a pattern must keep the form that the merchant has in the row.

Do not add NFC normalization to rule patterns. A rule made from a merchant with an NFD
spelling would then never match that merchant.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Domain/Author/OpAuthor.swift`
(`OpAuthor.rule`).

## The fold does not normalize and does not apply the taxonomy

The fold keeps what the ops say (03c §1.11). Two rules follow:

- Text normalization (NFC, then the trim of `EDGE_SPACE` and white space, 03c §1.6) is
  done only by the author, before the op is written.
- The effective category table (03c §4.4) is made when the app reads the state. It is the
  built-in taxonomy with the `category_defined` records of the account on top. A built-in
  category keeps its taxonomy order. A user category gets order 100 plus the index of its
  first definition in fold order.

The reason: the same log must fold to the same state on each device and in each build. The
audit folds the log again from the start and compares the bytes with the kept state. If the
fold normalized text or applied the taxonomy, a change of either in a later build would
change the folded state of old ops, and the audit would stop sync.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Domain/Author/OpAuthor.swift` (`UserText`),
`ios/HasalaCore/Sources/HasalaCore/Domain/Categories/TaxonomyView.swift` (`TaxonomyView`).

## Sample data loads only through the gate in the app

"Use sample data" on a review account authors the Maya scenario as ordinary ops, through
`OpAuthor` (spec 04 §4.6; 06 §13.5). Thus the sample uploads, folds and syncs to a second
iPhone exactly as data from a mailbox does.

The server cannot refuse sealed ops, so the check in the app is the only check (04 §6.13;
06 R-REV-3, AT-34). `SampleSeed.batches` needs a `Permit`. Only `SampleSeed.permit` makes
one, and it needs three facts:

- a live `GET /account` of this session says `review_account: true` (a missing field
  refuses);
- the projection has no transaction, with the outbox included;
- the ledger has no sample row, so the load occurs one time only.

`LedgerPageObserver.sampleBatches` gets these facts itself. It is the only way in for the
app. Do not add a second path to `batches`, and do not let a caller supply the facts from a
cache. Without the gate, sample rows can go into the ledger of a real person, and the
server cannot remove them.

Other rules of the seed:

- The seed file is generated from the Maya mock by `Tools/SampleSeedExport`. Do not edit it
  manually.
- The seed has no `home_currency_set` and no rate. The open of the account authors those
  (04 §6.2), and a second home currency is an anomaly.
- Each load makes new ids for its placeholders, so two loads never collide. Fixed ids
  (the cash account, ids derived from a card or a bill) stay as they are.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Domain/Sample/SampleSeed.swift`
(`SampleSeed.permit`, `SampleSeed.batches`).

## A sample row is known by its message id

Each sample row that stands for a bank alert has the message id `sample-<n>`. A row is a
sample row exactly when its message id starts with `sample-`. The gate uses this to refuse
a second load, and the transaction sheet uses it to show "This is sample data".

This is safe because Gmail message ids are hex, so no real row matches. A new source of
message ids must keep this true: it must never give an id that starts with `sample-`.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Domain/Sample/SampleSeed.swift`
(`SampleSeed.isSampleMessageID`).

## Forwarder domains and shared suffixes are never trusted senders

The effective set of trusted senders (spec 03c §7.2) is the domains that the folded
`sender_trust_set` records mark as trusted, minus `ForwarderDomains.v1` and
`SharedSuffixes.v1`. It is a rule of the reader, applied when the state is read. It is not
applied in the fold. The mail lane makes its `from:` queries from this set (sorted by UTF-8
bytes), so mail from all other senders is never listed.

- `ForwarderDomains.v1` lists the mail providers that a message can come from or pass
  through. A domain is excluded when it is on the list or under an entry. Anyone can send
  mail that such a provider authenticates, so trust in one of these domains is not trust in
  a bank. Spec 04 §7.6 excludes them from the trusted set and from the sender query, and
  "Trust <domain>" and "Add a sender" never offer one.
- `SharedSuffixes.v1` lists suffixes that many organisations share (for example a country's
  company suffix). Only an exact match is excluded. A bank's own domain under such a suffix
  stays valid. A subdomain match here would exclude every bank under the suffix.

The forwarder list is frozen. A change is a new version of the list, never an edit, because
each device computes the set from the same log and must get the same result.

The forwarder list has two copies, `SenderTrust.forwardersV1` in `Domain/Trust` and
`ForwarderDomains.v1` in `Mail`. They must stay equal.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Domain/Trust/EffectiveTrust.swift`
(`SenderTrust`), `ios/HasalaCore/Sources/HasalaCore/Mail/ForwarderDomains.swift`
(`ForwarderDomains`).

## Violation details and parse errors carry no content

The detail text of an invariant `Violation` has only ids and kinds. It never has an amount
or a merchant. The Integrity screen shows this text, and it can go into a log.

A `JSONParseError` has only a coarse reason and a byte offset. It has no text from the
parser and no part of the input. A caller reports only
`"<what>: body is not valid JSON (<n> bytes)"`, because this text can go into materialized
state.

Do not add a value from a transaction or from the input to these texts.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Invariants/CoreInvariants.swift`
(`Violation.detail`), `ios/HasalaCore/Sources/HasalaCore/JSON/JSONParser.swift`
(`JSONParseError`).

## A page that breaks an invariant is not persisted

A pulled page that the reader decided is folded onto a copy of the state (spec 04 §5.2
steps 4-5, §5.6). Then the incremental invariants run. Only a clean result goes back to the
caller, which persists it together with the page. On a hard stop the caller persists
nothing from the page: no rows, no cursor and no state.

Do not fold in place, and do not persist the page before the check. Then a state that
breaks an invariant would be stored, and the next start would continue from it.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Invariants/LedgerFold.swift`
(`LedgerFold.page`).

## Canonical JSON is the output of JSON.stringify, byte for byte

The op codec, the raw body and the serialized state were defined by a JavaScript client
that wrote them with `JSON.stringify`. The golden fixtures, the size limit of an op and the
audit comparison all use these bytes. Thus `JSONWriter` must give the same bytes as
`JSON.stringify` for each value:

- No white space. Keys in the order of the object.
- Escaping: `"` and `\` are escaped, `\b \f \n \r \t` are written by name, each other C0
  control is a lower-case `\u00XX`, and all other characters are literal. This includes
  `/`, `<`, `>`, `&`, DEL, U+2028 and U+2029. Go's `encoding/json` escapes `<`, `>`, `&`,
  U+2028 and U+2029, so bytes that Go encodes that way are equal in value only, never
  equal byte for byte.
- Key order (`.javascript`, the default): a JavaScript object gives its array-index keys
  first (`"0"` to `"4294967294"`, canonical decimal), in ascending order, then the other
  keys in insertion order. `.insertion` keeps the order as written.
- Numbers (`.javascript`, the default): the number is written as a JavaScript Number.
  `1.50` becomes `1.5`, `1e2` becomes `100`, `-0` becomes `0`, and 2^53+1 becomes
  9007199254740992. A literal that overflows a double becomes `null`. `.literal` writes the
  literal as it was parsed (spec 04 §2.2 "literal-preserving").

`JSNumber` gives ECMAScript's `Number::toString` (ECMA-262 §6.1.6.1.20). It takes the
digits from Swift's `Double.description`, which gives the shortest digits that round-trip,
the same digits that ECMAScript requires. Only the layout is ECMAScript's. With the value
written as `0.digits × 10^n`, the text is plain decimal when `n` is from -5 to 21, and it
has the exponent form otherwise. Do not replace
`description` with a formatter that gives other digits. This is the only use of a double in
the JSON module, and it is never on a money path.

Applies to: `ios/HasalaCore/Sources/HasalaCore/JSON/JSONWriter.swift` (`JSONWriter`),
`ios/HasalaCore/Sources/HasalaCore/JSON/JSNumber.swift` (`JSNumber`).

## The JSON parser reads as JSON.parse does, with two differences

`JSONParser` is a strict RFC 8259 parser. It behaves as `JSON.parse` does on the text that
a WHATWG `TextDecoder` gives:

- The bytes are decoded first: one leading BOM is removed, and invalid UTF-8 becomes
  U+FFFD. Swift's `String(decoding:as:)` does this repair exactly as WHATWG does. In a
  string the U+FFFD is data. Outside a string it is a syntax error.
- White space is exactly space, tab, LF and CR.
- A `\uXXXX` pair that makes a surrogate pair is combined. A raw control character
  U+0000 to U+001F in a string is refused.
- A number keeps its literal. A repeated key takes the last value.

Difference 1, lone surrogates. JavaScript keeps a lone surrogate in a string, keeps such
keys apart and writes the escape again. A Swift `String` cannot hold one, so the parser
makes it U+FFFD, or refuses the document when `refuseLoneSurrogates` is set. Op bodies and
raw bodies must be parsed with the refusal, so that two different inputs never become the
same value. The serialized state never has a lone surrogate.

Difference 2, depth. The parser refuses a document that nests deeper than 128 levels.
JavaScript accepts it. Nothing on the wire nests more than a few levels. The limit exists
because the release of a `JSONValue` is recursive: Swift frees an indirect value level by
level. A hostile document of some hundreds of levels overflows the 512 KiB stack of a
secondary thread when it is freed. Measured on macOS 26: 2000 levels crash a Swift Testing
worker on release, 512 levels do not, and 128 leaves a wide margin. Do not raise the limit
without this measurement.

For the same reason the parser is iterative, with its own stack of open containers. A deep
document costs heap, not stack. Do not change it to a recursive parser: tests and
background work run on threads with small stacks.

Applies to: `ios/HasalaCore/Sources/HasalaCore/JSON/JSONParser.swift` (`JSONParser`,
`JSONParser.defaultMaxDepth`).

## JSON values keep the number literal and the key order

`JSONValue` keeps what `JSONSerialization` and `JSONDecoder` remove (spec 04 §2.2; spec 03c
§1.1-§1.2):

- The number literal, exactly as written. `1`, `1.0` and `1e0` are three literals, and the
  v4 decoders refuse the last two where an integer is necessary. A literal above 2^53 stays
  exact.
- The order of the object keys, as first seen. A repeated key keeps its first position and
  takes the last value, as `JSON.parse` does.
- The difference between `1` and `true`. There is no `NSNumber` bridge.

The JSON module is a byte-exact module (spec 04 §2.4 R2). It uses no Foundation JSON type,
no `Double` on a path that decides a value, and no iteration over `Character`. A change to
Foundation JSON would round large numbers, lose the key order and accept payloads that the
fold must refuse.

Applies to: `ios/HasalaCore/Sources/HasalaCore/JSON/JSONValue.swift` (`JSONValue`,
`JSONNumber`, `JSONObject`).

## Strings are compared by UTF-8 bytes

In the byte-exact modules, two strings are equal only when their UTF-8 bytes are equal.
Swift's `String ==` and the hash of a `String` use canonical equivalence, so the NFC and
the NFD spelling of a text are equal there.

- `JSONValue` has its own `==` and `hash`. The synthesized ones would make two values equal
  that write different bytes.
- `JSONObject` finds a key by its bytes (`[UInt8]`). A `String` key would merge the NFC and
  the NFD spelling of a key into one member.
- The mail trust reader compares header values with a byte comparison (`same`).

Do not replace these with `String ==` or with a dictionary keyed by `String`.

Applies to: `ios/HasalaCore/Sources/HasalaCore/JSON/JSONValue.swift` (`JSONValue.==`,
`JSONObject.positions`), `ios/HasalaCore/Sources/HasalaCore/Mail/AuthResults.swift`
(`AuthResults.same`).

## The fresh-install purge runs before any Keychain read

Keychain items stay on the iPhone when the app is deleted. A new install must not get the
keys and the session of an earlier install (spec 04 §4.4 `installCheck`; spec 01 §11.3;
R-03). `app.hasala.installID` in `UserDefaults` marks an install that did the purge.

The rules, in order:

1. The check runs at process start, before any other code reads the Keychain.
2. It runs only while protected data is available. Before the first unlock, `UserDefaults`
   can read as empty. A missing `installID` at that time is not proof of a new install, and
   a purge then would delete the keys of a good install.
3. When `installID` is not set, the check deletes each item of each app service in the two
   access groups.
4. Only when each delete answered success or not-found, it removes the widget snapshot
   directory and sets `installID`.
5. If a delete failed, `installID` stays unset, start-up waits (`.notNow`), and the next
   launch tries again.
6. Only the app process does the purge. An extension never does it.

Do not set `installID` before all deletes are complete, and do not move a Keychain read
before the check. Then a new install can use the items of an old one.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Keychain/InstallCheck.swift`
(`InstallCheck.run`), `ios/HasalaCore/Sources/HasalaCore/Keychain/KeychainSecretStore.swift`
(`purgeAll`).

## A Keychain read tells a missing item from a locked one

`KeychainSecretStore` is the `SecretStore` on the data-protection Keychain (spec 04 §4.4;
spec 01 §11.1, §11.3). Each item is a generic password in the data-protection Keychain. It
is not synchronizable, it is in the access group of the app only, and it has the
accessibility class that its `SecretItem` names.

- A read returns `nil` only for `errSecItemNotFound`. It throws for each other status.
  `errSecInteractionNotAllowed`, which the Keychain gives before the first unlock, is
  "not now". If a locked Keychain read as "no item", the app would act as if it had no
  session and no keys, and could write new ones on top of good ones.
- A write is `SecItemAdd`, then `SecItemUpdate` on `errSecDuplicateItem`, then a read and a
  comparison. A difference throws.

The SecItem calls go through the `KeychainAPI` protocol. The reason is the tests: a macOS
test runner has no entitlement for the data-protection Keychain, so `swift test` uses an
in-memory double with the same semantics.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Keychain/KeychainSecretStore.swift`
(`KeychainSecretStore`, `KeychainAPI`).

## Gmail trust reads only Gmail's own DKIM verdict

The Gmail rule itself is in `docs/decisions/outlook-mailbox.md` (§3, "The Gmail rule") and
in `conformance/authres/README.md`. These points were only in the code:

- Why the rule is sound. It runs only on headers that the phone got from Gmail's own store
  through an authenticated API (TLS and OAuth). RFC 8601 §5 tells the receiving domain to
  delete incoming `Authentication-Results` headers that claim its own authserv-id. The rule
  does not assume that Gmail does this. It fails closed: more than one `mx.google.com`
  header, or one that is not the topmost, is not trusted. Do not use the rule on headers
  from another source (for example forwarded mail or a pasted message).
- `spf` and `dmarc` results are parsed but never trusted. DMARC can pass on SPF alone, and
  SPF speaks for the envelope sender, not for the `From` domain that a bank's template is
  keyed on. Only `dkim=pass` with a DKIM domain aligned with the one `From` domain gives
  trust.
- A message that is not trusted gets a reason and goes to Review. It is never dropped.
- The server never reads `Authentication-Results`. It never sees mail.
- The reader uses JavaScript's rules where they can change a verdict: the `trim` set (with
  U+00A0 and U+FEFF), the full lower-case mapping, and the 256 KiB limit counted in UTF-16
  code units. The `authres` fixtures came from a JavaScript reader, and the verdict and the
  domain must be the same on each input. The tests pin the non-ASCII white space and the
  case mapping.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Mail/AuthResults.swift`
(`AuthResults.analyze`).

## The trust rule gets only the header block

`AuthResults` refuses an input above 256 KiB. That limit is for the header block. A whole
message can be up to 1 MB, so a large but ordinary HTML alert would fail on size alone and
go to Review. Thus the caller cuts the message at the first blank line
(`MailHeaders.headerBlock`) before it asks for the verdict. The verdict reads the same
fields as before, because its unfolder stops at the first blank line too.

Do not give the whole message to `AuthResults`.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Mail/HeaderBlock.swift`
(`MailHeaders.headerBlock`).
