# iOS crypto core: decisions from the code (2026-11-21)

These decisions were code comments under `ios/HasalaCore/Sources/HasalaCore/Crypto/`. Code comments are
not permitted (`scripts/comment-lint.ts`), thus the decisions are here.

## A display name cannot carry a link or a number

The display name follows `02` §10.7.4 (`DisplayName`, D-16), which is narrower than the
`name_ok` floor of spec 01 §4.11. It permits only letters, marks, the space, `'`, `’`, `-`
and `.`, and a period must be followed by a space or end the name. It permits no digits and
no `@`, `/`, `:` or other punctuation.

The reason is outbound mail. The name goes into emails that Hasala sends. A name with a
link, an address or a phone number would let a person use our mail to carry it. Do not add
a character to the permitted set without this check. The server enforces the same rule,
and the app checks it first so that the field can show the error.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Crypto/Accounts.swift` (`DisplayName`).

## The domain registry lists the server-only strings

`Domain` holds one case for each row of the domain-string registry (spec 01 §3), D01 to
D43, in the order of the registry. The device does not use D27 to D30, D41 and D43. Only
the server uses them. They stay in the Swift registry for two reasons: the namespace must
stay free of collisions, and the Swift tests must be able to reproduce A19 and A19-K.

Do not remove a case because no Swift code uses it. AT-X3 compares `Domain.allCases` with
Go's `keyproto/domains.go` and with `conformance/crypto-v3/manifest.json`, and a missing or
moved row fails it. No `ledger-*` string and no op-spec `hasala/v1/*` hash string goes in
this registry.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Crypto/Domains.swift` (`Domain`).

## Zeroing of secrets is best effort, and key bytes get no extra copy

Secrets are returned and held in `SecureBytes`, which zeroes its memory. Spec 01 §11.5
accepts that this is best effort. Some copies are outside its reach:

- CryptoKit takes and returns `Data`. The intermediate `Data` of a derivation cannot be
  zeroed by our type. Where our code makes such a copy (the key body before AES-GCM), it
  zeroes that copy on the way out, together with the `SecureBytes` it came from.
- A password arrives as a Swift `String`. The string itself cannot be zeroed. Its NFC
  UTF-8 bytes go straight into `SecureBytes`, with no `Array` between.

The rule that follows: do not add a copy of key bytes. Read key bytes straight from the
caller's buffer into `SecureBytes` (the key body decoder does this), and do not go through
an `Array` or a `Data` that nothing zeroes. A change that adds such a copy leaves key
material in memory for longer and nothing reports it.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Crypto/KeyDerivation.swift`,
`ios/HasalaCore/Sources/HasalaCore/Crypto/Password.swift` (`PasswordStretch.stretch`),
`ios/HasalaCore/Sources/HasalaCore/Crypto/Wraps.swift` (`KeyBody.init(decoding:)`, `Wrap.seal`).

## A frame opens only at its own position

The associated data of a v3 frame is the domain string, the whole cleartext header and
the hash of the chain predecessor (spec 01 §6.3 to §6.6, C1). The blob key comes from the
epoch key, the nonce and the SHA-256 of that associated data, so each key seals exactly
one AES-GCM message (DEV-1).

The result: a blob opens only at its position, under its epoch, after its exact
predecessor. The server cannot move, reorder or replay a frame, and no key is used with two
nonces. Do not remove a field from the associated data, and do not use the epoch key
directly as the AES-GCM key.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Crypto/Sealer.swift` (`Sealer`, `FrameAEAD`),
`ios/HasalaCore/Sources/HasalaCore/Crypto/KeyDerivation.swift` (`blobKey`).

## The reader's roster comes only from the verified key history

The roster of writers that the reader trusts (R1 and R2b of spec 01 §6.6) has one source:
the entries of `GET /key-history`, verified on the device (spec 01 §10.13). `GET /writers`
is never a source. It is only compared with the verified roster, and a writer that it
lists and the roster lacks, or lists differently, raises the `rosterMismatch` alarm.

The authority public key for that verification is the one derived from the unwrapped key
body (spec 01 §4.5). It is never a key that the server serves.

When an entry breaks a requirement, the caller raises the `keyHistoryInvalid` alarm and
keeps its last verified roster. The alarm names only the entry or the writer.

The reason: the server is not trusted to say who the writers are. If the reader took the
roster from `GET /writers`, or the authority key from the server, the server could add a
writer of its own and its rows would pass the reader.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Crypto/KeyHistoryVerifier.swift`,
`ios/HasalaCore/Sources/HasalaCore/Crypto/PageReader.swift` (`State.roster`).

## LooksSealed is the same predicate on the phone, in Go and in SQL

The plaintext refusal (spec 01 §8.1) is one predicate with eight checks. The Swift
`LooksSealed`, Go's `blob.LooksSealed`, `02` §11.2 and the SQL function
`hasala_frame_is_sealed` have the same checks, in the same order, with the same names. The
first check that fails names the refusal. A change to one of them is a change to all of
them.

The server cannot prove that bytes are ciphertext. The predicate refuses each shape that
a buggy or legacy client would make. On honest ciphertext only check 8 (a cleartext gzip
header in the region) can fail, with probability 2^-24. When it does, the sealer seals one
more time (spec 01 §6.5 step 9). Two refusals in sequence are a sealer fault.

Only `Sealer` can make a `SealedFrame` (spec 04 §2.4 R4). The initializer of
`SealedFrame` runs `LooksSealed` again in every build, release builds included, and stops
the process on a failure. Keep it a `precondition`, not an `assert`: the sealer checked the
bytes already, so a failure there is a bug, and the app must not upload such bytes.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Crypto/LooksSealed.swift`,
`ios/HasalaCore/Sources/HasalaCore/Crypto/Sealer.swift` (`SealedFrame`).

## The page reader runs R0 to R10 in order and keeps nothing from a failed page

The reader of spec 01 §6.6 examines one pulled page through R0 to R10, in that order. The
first step that fails decides the outcome.

- The page-wide steps run before any blob is opened: R0 (row shape), R1 (the roster and
  the own-writer rule, row by row), R2 (the chain from the pinned heads), R2b (the signed
  heads). This is the order of Go's reference reader. Then R3 to R10 run row by row.
- In R2b, writers are examined in the order of their last row in the page, and for each
  writer the revocation pin is examined before the head signature. Go's reference reader
  uses the same order, so the two report the same failure for the same page.
- The row carries `writer_counter` as the decimal string of the wire. R0 examines its
  grammar. Do not change the field to an integer that the caller parsed: a lenient parser
  would accept a counter that R0 must refuse.
- When a page-wide step fails, nothing from the page is persisted. The caller persists the
  rows, the cursor and the heads in one transaction, and only when nothing stopped the page
  (spec 01 §7 "Client order").
- The reader does no network work. The two network steps are outcomes: `refreshRoster`
  (R1: get the key history one more time, verify it, read the page again) and
  `refreshEpoch` (R4: read `GET /keys` one more time, read the page again). Each occurs at
  most one time for a page. A second failure is a hard stop.

A change of the order changes which failure a tampered page reports, and it can let a
blob be opened or a row be stored before the chain and the signatures were examined.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Crypto/PageReader.swift`,
`ios/HasalaCore/Sources/HasalaCore/Crypto/DeviceKeys.swift` (`HeadCheck`).

## The authored head counts sealed frames, not acknowledged ones

The reader stops sync when a pulled row of the device's own writer has a counter above
the device's authored head (`ownChainConflict`; `docs/decisions/sync-writer-checkpoints.md`).
The authored head is the highest counter that the device has sealed for its writer. It
includes the counters of the in-flight record (R-OUT-2; `04` §5.5), not only the counters
that the server acknowledged.

The reason: the server can accept a batch and the response can be lost. That batch then
comes back in a pull. If the authored head counted only acknowledged counters, the device
would read its own rows as a conflict and stop sync.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Crypto/PageReader.swift` (`State.own`).

## A sealed frame is kept whole and sent again byte for byte

A `SealedFrame` holds the bytes that the server will store and their chain hash. The
device persists it whole in the in-flight record before the upload (R-OUT-2). A resend
uses these exact bytes (R-OUT-3). The device does not seal the same ops again for a
resend.

The reason: a new seal has a new nonce, thus other bytes and another blob hash. If the
server accepted the first upload, the second frame at the same counter does not agree with
the chain, and the next frames were chained to a hash that the server does not have.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Crypto/Sealer.swift` (`SealedFrame`).

## A password gives access only, and its work factor is a constant

A password gives access to the account and nothing else (spec 01 §4.10, PO B). No key is
derived from the password, from its stretched value `S` or from the server's hash, and
nothing is wrapped under them. The wrap `kdf` value `0x03` is reserved for a stretched
recovery phrase root. It is never for a password.

The device stretches the password with PBKDF2-HMAC-SHA256 and 600 000 iterations. The
iteration count is a constant in the app. No field from the server can lower it. If the
server could set it, a TLS terminator between the app and the server could ask for a cheap
`S` and collect it. A new work factor is a new domain string, never a parameter.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Crypto/Password.swift` (`PasswordStretch`),
`ios/HasalaCore/Sources/HasalaCore/Crypto/Wraps.swift` (`Wrap.KDF`).

## The password policy runs only where a password is made

The creation policy (spec 01 §4.10; `04` §6.1.2) is: after NFC, 12 to 128 Unicode
scalars, no composition rules, then the bundled blocklist. It runs only where a person
makes a password. It never runs where a person proves one. Thus an update of the list can
never lock a person out. The server cannot do this check, because it sees only `S`.

The bundled list has entries of any length. A root such as a common 8-letter word is
shorter than the minimum, and it is what a candidate matches after its trailing digits and
marks are removed. Do not remove the entries that are shorter than the minimum length.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Crypto/Password.swift` (`PasswordPolicy`,
`PasswordPolicy.Blocklist`).

## The recovery phrase stays in memory, and derivations use its 16 bytes

The recovery phrase (spec 01 §4.3) is 16 bytes of entropy, shown as twelve BIP-39 English
words. Each derivation uses the 16 bytes, never the string of words. This is not the
BIP-39 seed derivation, and a change to the string form would give other keys.

Typed input is normalized exactly one time, in `Phrase`, and only to match the words. No
other code normalizes a phrase. A word must be an exact list word. There is no prefix
match.

The entropy, the words and all that is derived from them are never persisted, logged, put
on the pasteboard or sent. The phrase box is the one exception, and it is sealed.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Crypto/Phrase.swift`.

## Signing messages have one reading, and signatures are verified, not compared

Each signing message (spec 01 §10.1) has fields of fixed length and at most one variable
field. The variable field is last, or it is pinned between fixed fields. `writer_id` (40
bytes) and `uuid_str` contain no `0x00`. Thus the bytes of a message have only one reading,
and a signature for one message cannot be used as another. A new message must follow the
same rule. Each builder examines its fixed lengths and returns exactly the length of its
row.

CryptoKit's Ed25519 signatures are randomized. Two signatures of the same message under
the same key are different bytes. A test or a check must verify a signature. It must never
compare signature bytes with expected bytes.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Crypto/SigningMessages.swift`.

## The client computes each challenge itself

The device computes each challenge that it signs, and it refuses a challenge from the
server that differs.

- Account creation: `C_reg` (D01) binds the authority public key into the WebAuthn
  ceremony with user verification. The client computes it again and refuses `options` with
  another challenge.
- Step-up (spec 01 §10.2, A-10; AT-C9): the client computes `params_hash` and `C` and
  refuses a `challenge` from `step-up/begin` that differs. This is true for every proof
  kind. The device approval key signs only a `C` that the client computed for the action
  that the person chose.

The reason: a challenge that the server supplies could be for another action or another
target. Then one approval from the person would authorize an operation that the person did
not choose.

Step-up params bind the target or the signing key. They never bind content that needs the
PRF output of the same assertion, because that content does not exist when the challenge
is made.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Crypto/StepUp.swift`,
`ios/HasalaCore/Sources/HasalaCore/Crypto/SigningMessages.swift` (`registerChallenge`).

## Opening a wrap gives one error for every cause

When a wrap or the phrase box does not open, the caller gets one error, `unwrapFailed`,
for every cause (spec 01 §5.4, §5.5). The error does not say which step failed, so it is
not an oracle for a person who tries phrases or changed bytes.

The two integrity alarms are different and have their own names. `accountKeysMismatch`
means that the body opened, but its AMK or its authority key is not the published one.
`phraseBoxMismatch` means that the phrase box opened to a phrase that is not of this
account. These are compared in constant time. An integrity alarm must never be shown as
"wrong phrase": the person typed correct words, and the published keys are wrong.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Crypto/Wraps.swift` (`UnwrapError`,
`AccountUnlock.checkCommitments`).

## A PRF wrap that does not open is not deleted

The unlock follows spec 01 §5.4 in order: the recovery key check (on the phrase path), the
wrap, the body version, then the commitments. When a PRF wrap does not open, nothing
deletes it automatically (W14). The caller falls back to the recovery phrase.

The reason: a wrap that does not open now is not proof that the wrap is bad. An automatic
delete would remove a way into the account, and the device cannot make that wrap again
without the passkey. A delete of a wrap is the person's decision.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Crypto/Wraps.swift` (`AccountUnlock`).
