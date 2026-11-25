# iOS sync, account ceremonies and bank templates: decisions from the code (2026-11-21)

These decisions were code comments under `ios/HasalaCore/Sources/HasalaCore/Sync/` and
`ios/HasalaCore/Sources/HasalaCore/Template/`. Code comments are
not permitted (`scripts/comment-lint.ts`), thus the decisions are here.

## A passkey signup writes its session before the keys exist

In a passkey signup (spec 04 §6.2 C1), the session is written to the Keychain at once
after `register/finish` (R-04). The bootstrap, which publishes the keys, comes later, after
the person saw the 12 words.

The app can stop between these two steps. Then the account has a passkey and a session but
no keys: `GET /keys` answers `404 no_keys`, and a sign-in answers `has_keys: false`. Boot
reads "a session and no binding" as `onboardingKeys` (the "C1 interrupted" row of §6.2), and
`AccountCreation.bootstrapInterrupted` completes the account.

The resume always makes new secrets and a new phrase, and the person sees the new words. The
first secrets were only in memory (spec 01 §11.5) and are lost. The resume proves the person
with a step-up `keys.bootstrap` on the passkey.

Do not move the session write to the end of the signup, and do not keep the first secrets on
disk to resume with them. Without the early session, an interrupted signup leaves an account
that this iPhone cannot complete.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Sync/AccountCreation.swift`
(`registerPasskey`), `ios/HasalaCore/Sources/HasalaCore/Sync/AccountCreationResume.swift`
(`bootstrapInterrupted`).

## Enrolment stores the writer key first and the binding last

Each enrolment (C1, C1-P, C2, C2-P, C3 and recovery) has the same order on the iPhone.

First: `NewDevice.mint` writes the DWK seed to the Keychain before it returns, thus before
any server call uses the writer (spec 04 §6.2, "persisted before first use"). The answer to
a registration or a bootstrap can be lost. Then the server has a writer, and this iPhone
still holds its key and can continue with it. A seed that is only in memory would leave a
writer on the server that nobody can use.

Last: the binding item. Boot reads the binding as "this iPhone is enrolled". All other
items (the session, `K_1`, the store, the pinned roster) are written before it.

The caller's check runs between the two, after all other items are stored and before the
binding. After a bootstrap this check is E-04: `GET /keys` and `GET /account` must equal the
values of this device. An address that is missing from the answer is a difference, because
`02` #40 always returns it to the account's own session. A difference raises the integrity
alarm and stops onboarding. The binding is not written, so boot never opens the account and
stays at `onboardingKeys`.

Do not write the binding earlier. A binding that exists before the check passed lets boot
open an account whose published keys are not the keys of this device.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Sync/AccountEnrolment.swift`
(`NewDevice.mint`, `Enrolment.persist`),
`ios/HasalaCore/Sources/HasalaCore/Sync/AccountCreation.swift` (`persistAndCompare`,
`compareAfterBootstrap`).

## A roster fetch that fails at enrolment pins the authority key alone

At the end of an enrolment the iPhone fetches the roster, verifies it under the authority
public key and pins it.

- A key history that fails verification stops the enrolment, with no binding. The same is
  true when the verified roster does not list this iPhone's writer with its two keys.
- A transient failure (for example no network) does not stop the enrolment. The iPhone pins
  the authority public key with an empty roster.

The reason for the second rule: at this point the server already accepted the writer. A
failure here would strand an iPhone that the server knows. The first sync run fetches the
roster and verifies it under the pinned key (R1 for any row, and the refresh stage), so no
row is read without a verified roster.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Sync/AccountEnrolment.swift`
(`Enrolment.persist`).

## A new writer removes the store of an earlier writer

An iPhone can enrol again after it was `unenrolled`. Its store then belongs to the earlier
writer of the same account: it has that writer's authored head and that writer's pending
ops. The new writer starts its own chain. Enrolment thus deletes the old store and makes a
new one, which the first pull fills from the server.

Known limit: the unsent ops of the old writer are lost. They cannot be sent, because they
belong to the chain of a writer that this iPhone no longer is. Do not keep the old store
and continue under the new writer. Its authored head and its pending ops are those of
another chain.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Sync/AccountEnrolment.swift`
(`Enrolment.persist`).

## Ceremony values that hold secrets belong to one ceremony

`RegisteredPasskey`, `StepUpHelper.Proof` and `Recovery` are `@unchecked Sendable`. Each
holds secret bytes or changes during its ceremony, and the compiler cannot prove that this
is safe. The rule that makes it safe:

- `RegisteredPasskey.prf`: the caller of the bootstrap wipes it.
- `StepUpHelper.Proof.prf`: the proof goes to one ceremony, and that ceremony wipes it.
- `Recovery`: one ceremony at a time changes it. It holds the phrase entropy and, after the
  verify step, the unwrapped body, in memory only.

Do not give one of these values to two ceremonies, and do not add a use of `prf` that does
not wipe it. The second reader gets wiped bytes, or the two race. This is the same rule as
"The PRF output of a passkey result has one owner" in `docs/decisions/code/ios-hasala.md`.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Sync/AccountCreation.swift`
(`RegisteredPasskey`), `ios/HasalaCore/Sources/HasalaCore/Sync/AccountSignIn.swift`
(`StepUpHelper.Proof`), `ios/HasalaCore/Sources/HasalaCore/Sync/AccountRecovery.swift`
(`Recovery`).

## Recovery with the 12 words ends with a new passkey or a new password

Access recovery (C4; `02` routes #7, #48, #8) ends with a new passkey or with a new
password. The person chooses, and the ceremony is bound to that kind at `recover/verify`.

A password is stretched with the salt `s_srv ‖ email_norm` (spec 01 §10.6), so the phone
must know the full address. `recover/begin` (#7) answers only the masked hint. When the
kind is a password, `recover/verify` (#48) answers `salt` and `email_norm`, after the code
from that mailbox is correct. For a passkey it answers neither.

- The phone uses the answered address and salt for the stretch, and writes them to the
  binding. It does not ask the person to type the address: a typing error would set a
  password that no sign-in can make again.
- The phone refuses an answer with no 32-byte salt or with an address that is not in the
  normalized form, before it asks for a password.
- A ceremony that was verified for one kind does not finish with the other kind. The phone
  refuses it and sends nothing.

The 12 words alone still reveal only the hint. The full address needs the words and the
code, and those two already give the account (the session of `recover/finish` reads the
address at `GET /api/v1/account`). The server side of this rule is in
`docs/decisions/code/server-auth-2.md`.

Forgot password (C9) is a different flow and stays out of the build. It needs the approval
of another iPhone.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Sync/AccountRecovery.swift`
(`verifyForPassword`, `finishWithPassword`, `Recovery.Way`),
`ios/Hasala/Live/Account/LiveAccountService.swift` (`verifyRecovery`, `finishRecovery`),
`ios/Hasala/Features/Account/AccountContracts.swift` (`AccountCapabilities.beta`).

## A recovery checks the answered keys before the passkey sheet

`recover/verify` answers the account's published keys and its recovery wrap. The phone
opens the wrap with the phrase entropy and checks the commitments in the verify step,
before any prompt. A server that answers the keys of another account is refused there, and
the person is never asked to make a passkey for it.

In this step, a wrap that does not open and a commitment that does not agree are both the
integrity alarm. They are never "wrong words". The reason: `recover/begin` (#7) already
matched the recovery public key of these words to an active account. Thus the words are
correct, and a failure is the server's answer, not the person's typing. This is different
from a normal unlock, where a wrap that does not open can be a wrong phrase.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Sync/AccountRecovery.swift`
(`verifyForPasskey`).

## Sign-out keeps the session until the server confirms it

Sign-out (spec 04 §4.7 row 1) calls `POST /auth/logout` before it deletes the session item.
A `204` or a `401` means that the server session is gone, and the item is deleted. When
the call fails for another reason (for example offline), the item stays with
`pending_logout: true`. All readers treat such a session as signed out: boot sees no live
session, and sync answers `needsSignIn`.

The reason: the token is the only way to end the session on the server. If the phone
deleted the token first, a failed call would leave a live server session that the phone can
never end. Do not delete the session item before the answer, and do not read a session
with `pending_logout` as a live one.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Sync/AccountSignIn.swift` (`SignIn.signOut`),
`ios/HasalaCore/Sources/HasalaCore/Sync/SyncContext.swift` (`bearer`),
`ios/HasalaCore/Sources/HasalaCore/Sync/Boot.swift` (`Boot.decide`).

## A secret that cannot be read now is not a missing secret

The Keychain reads of sync and boot keep two results apart (spec 04 §4.4, null-vs-throw):

- A read that throws means "not now". The usual cause is a launch before the first unlock.
  Sync stops with `notNow` (a background wake reports no data), and boot waits
  (`waitingForUnlock`).
- A read that returns nothing means "absent". Only this result leads to `needsSignIn`,
  `needsUnlock`, `unenrolled` or a wall.

Do not turn a thrown read into "absent". The app would then sign a person out, ask for the
phrase or offer to remove data, only because the iPhone was locked.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Sync/SyncContext.swift`,
`ios/HasalaCore/Sources/HasalaCore/Sync/Boot.swift` (`Boot.gather`, `BootFacts.unreadable`).

## Only the sync engine flushes the outbox, and one run at a time

Each bound account has one `SyncEngine` actor (spec 04 §5.1, §3). One run is: send the
in-flight batch again, pull, fold, flush, pull the own rows. Triggers coalesce: a call while
a run is in flight asks for one trailing run and waits for it. There is never a second
concurrent run.

`Pusher.flush` has one caller, the engine. Two concurrent flushes could seal the same
pending op two times, into two frames of the chain. For the same reason "Remove this
iPhone" does its catch-up through the account's engine and not through its own push.

The engine clears its in-flight marker in the same actor step as its last check for a
trailing run, with no suspension between the two. Do not add an `await` between them. With
a suspension there, a caller could ask for a trailing run after the check and still get the
outcome of a run that did not include its request.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Sync/SyncEngine.swift` (`run`, `loop`),
`ios/HasalaCore/Sources/HasalaCore/Sync/Pusher.swift` (`flush`),
`ios/HasalaCore/Sources/HasalaCore/Sync/AccountManagement.swift` (`removeThisIPhone`).

## Every run verifies the key history again, except a run after the person's own edit

Each run fetches the key history and verifies it before the pull (spec 01 §10.13): on a
launch, an unlock, a foreground, a wake and each other trigger except `authored`. The
reason: a wake has the same payload for every cause
(`docs/decisions/code/server-pushv2.md`), so the phone cannot know that a wake is a security
wake. With the check on every run, a revocation pins the final head of the removed writer
before the next page is read, and the reader refuses rows above it.

An `authored` run follows the person's own edit. It keeps the pinned roster. R1 still
fetches the roster again when a page has a row of an unknown writer.

When calls coalesce into one trailing run, that run keeps the strongest trigger: a trigger
that verifies the roster wins over `authored`. Do not let an `authored` call replace it.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Sync/SyncEngine.swift`
(`SyncTrigger.refreshesRoster`, `refreshRoster`, `run`).

## The authority key is pinned at enrolment, and a fresh roster must extend the pinned one

Spec 01 §10.13 wants the roster verified under the authority public key "derived from the
unwrapped seed". The seed is in memory only during a ceremony (spec 01 §11.1). Thus the
device derives the public key from the key body at enrolment and pins it in
`sync_state.roster_json`, with the roster that it verified. Each later fetch (R1 of each
pull, each refresh) is verified under the pinned key. The `authority_pubkey` that the server
serves is never used. This is the storage side of "The reader's roster comes only from the
verified key history" in `docs/decisions/code/ios-crypto.md`.

The server also cannot roll the roster back. A fresh roster is accepted only when it
extends the pinned one:

- the same authority key;
- a `last_entry_id` at or after the pinned one;
- each pinned writer still there, with the same DWK and DAK;
- each pinned final head exactly the same. A revocation never changes and never goes away.

New writers and new revocations are permitted. All other differences are `rosterInvalid`.
This stays a halt and not only an alarm, because the reader cannot run without a verified
roster. Without the rule, a server could serve an older key history and make a revoked
writer live again.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Sync/Roster.swift` (`PinnedRoster`,
`PinnedRoster.extends`, `RosterService`),
`ios/HasalaCore/Sources/HasalaCore/Sync/SyncStatus.swift` (`HaltKind.rosterInvalid`).

## A halt or a latch never wipes data

A halt is a wall that the person cannot dismiss (spec 04 §5.7). A latch stops uploads. The
two never delete data on the iPhone. The engine only reports that a wipe is due (`wiping`:
the account was deleted, or the pinned key history shows this writer's revocation), and the
app does the wipe (`AccountWipe`).

A latch stops the flush and not the pull (§5.4): the person continues to see new data from
the other devices while the changes of this iPhone wait.

The reason is the principle "Do not drop data silently". A halt can come from a server
fault or an attack. If it deleted the store, the unsent ops would go with it.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Sync/SyncEngine.swift` (`latchAware`),
`ios/HasalaCore/Sources/HasalaCore/Sync/SyncStatus.swift` (`HaltKind`).

## A chain break after a server restore is not reported as tampering

The store keeps the `meta.log_generation` that the device saw at enrolment. The server
reports a different value after its log was restored (`02` §15.5). When a chain condition
appears (`chainBreak`, `ownChainConflict` or a resend whose stored hash differs) and the
generation now differs from the stored one, the halt is `serverRestored`, not `tampered`
(R-10).

The reason: after a restore the server's log is shorter than the log that the devices
read, and this looks exactly like a rollback attack. The generation tells the two apart, so
the person gets the correct wall. The two conditions are necessary together. A changed
generation with no chain condition is not a halt.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Sync/SyncEngine.swift` (`restoredOr`),
`ios/HasalaCore/Sources/HasalaCore/Sync/SyncStatus.swift` (`HaltKind.serverRestored`).

## A page is folded on a copy before it is stored

The fold and the incremental invariants run on each pulled page before the page is
persisted (spec 04 §5.2 steps 4 and 5). A fold that throws keeps the whole page out: no row,
no head and no cursor of it are stored.

The fold works on a copy of the state. The transaction of the page writes the rows, the
cursor and the changed snapshot together. Only after the commit does the copy become the
current state. When the transaction fails, the copy is dropped. Thus the state in memory,
the snapshot and the stored rows always agree on one cursor.

The projection is made one time for each pull, after the pull ends with any outcome, and
not one time for each page.

Do not fold in place, and do not write the snapshot outside the transaction of its page. A
crash between the two would leave a snapshot that is ahead of the rows or behind them.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Sync/Puller.swift` (`PageObserver`),
`ios/HasalaCore/Sources/HasalaCore/Sync/LedgerPageObserver.swift`.

## A cold fold checks each stored row and fetches nothing

The fold snapshot is used only when each of its checks passes (version, fold print, bound
tip, digest, decode, cursor; spec 04 §5.3). When one fails, the device folds the stored
rows again from genesis. It does not trust the stored rows. It compares each with what the
reader decided when the row was pulled:

- The chain, for each writer from genesis: the counters are consecutive, each `prev_hash`
  is the hash of the row before, each `blob_hash` is the hash of the stored bytes, and the
  result agrees with the pinned heads. This check runs first, as R2 runs before R3 in the
  reader.
- The blob is opened again with the epoch keys on the device, and the outcome must be the
  stored disposition (folded, set aside or alarm). One exception: a row that an older build
  set aside and that this build can open is read now.

A difference (a damaged blob or key, a row that does not open as it did) records a
content-free `integrity_alarm` fold event and halts sync as `inconsistent` (spec 04 §5.7
A-32). Nothing leaves the state silently.

The cold fold fetches nothing from the server and drops no pinned head. Do not "repair" a
bad store with a new pull from sequence 0. The pinned heads are the protection against a
rollback, and a pull that ignores them would accept a shorter or different log.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Sync/LedgerPageObserver.swift` (`load`,
`coldFold`, `checkStoredChain`, `reopen`, `integrityHalt`).

## One stamp memory serves every author of an account

An author stamps each new op after `own_last_ms` (03c §1.8.2): the largest of the writer's
folded stamp, the newest pending op and the newest stamp given on this device. The last
value is in one `AuthorStamps` instance for each account. Each author of the account uses
that same instance. The mailbox lane (`MailboxAuthoring`) gets the instance of the
observer, not its own.

An author builds its blob inside `stamps.build`, which gives the context and records the
blob's stamps under one lock. Thus two blobs that start together never get the same stamp.
A blob that was built outside it must be reported with `noteAuthored`.

Do not give an author its own `AuthorStamps`. Two authors of one writer could then give
the same stamp to two ops.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Sync/LedgerPageObserver.swift` (`stamps`,
`authorContext`, `noteAuthored`).

## The account directory protects the database files

The projection database, as the ledger store, is in the account directory. The directory
has the file protection class and is kept out of backups (spec 04 §4.1). The directory is
the guarantee for each file in it, and this includes the journal files that SQLite makes
beside a database. The marks on the database files are a second layer only.

Do not remove the directory step because the files are marked, and do not put a database
outside the account directory.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Sync/LedgerPageObserver.swift` (`open`).

## The partial-apply conflict is found by its detail text

When a batch is partly applied already, `POST /api/v1/sync` answers `409 conflict`, and
the detail contains the sentence "read the chain head and resend only the rows above it".
The server pins this sentence (`02` §6.3; `server/internal/oplog/chain.go`,
`ErrPartiallyApplied`). The phone has the same sentence as a constant and looks for it in
the detail. Only then does it read its own head and send the remaining rows again.

The sentence is a contract between the server and the app, not a message for a person. A
change of the words on one side only makes the phone read this answer as an unknown
refusal that it tries again, and the batch stays in flight. Change the two sides
together. Builds that are already installed keep the old sentence.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Sync/SyncWire.swift`
(`partiallyAppliedDetail`), `ios/HasalaCore/Sources/HasalaCore/Sync/Pusher.swift` (`send`).

## A bundled template that fails a check is skipped

The bank templates are files in the app bundle (spec 04 §4.6), copied from
`server/internal/tmpl/seed`. The beta has no template updates over the air. The code
signature of the app covers the bundle, and the loader also compares each file with its
SHA-256 in `TemplatesManifest`.

A template that fails the SHA-256 check, the definition checks or the dialect gate is
skipped. The loader reports it by id and reason only (content-free, for diagnostics). The
other templates still load. One bad file must not stop the reading of all banks. When no
mail template loads, the mailbox halts with `templates_unavailable` (spec 04 §7.11).

Do not load a template that failed a check "as well as possible", and do not make one
failure stop the load.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Template/BundledTemplates.swift`.

## The regex dialect is the gate before ICU

A template is data, and more than one regex engine runs its patterns: Go's RE2 at publish,
and a backtracking engine on the phone (ICU). The dialect is the subset of RE2 on which the
engines were measured to agree, with cost rules that keep a backtracking engine cheap on
mail that an attacker can write. The Swift validator mirrors the Go validator
(`server/internal/tmpl/dialect.go`).

- The gate runs at load time, before a pattern is compiled for ICU, never after.
- Each rejection has a stable reason code. The codes, their scan order and their offsets
  (rune indices, as in Go) are the same as Go's for the same pattern.
  `conformance/dialect/patterns.json` pins them. Treat the codes as a wire format.
- The length and width counters saturate at a cap. They are only compared with a bound,
  so saturation gives the same answer on each executor where Go's `int` would wrap.
- The single-character escapes are a list of permitted escapes, those measured the same in
  RE2 and in JavaScript with the `u` flag. An escape that nobody examined fails closed.
- The scanner models the dialect, not the full regex grammar. The compile of the engine is
  the backstop for all other faults, such as a reversed class range, and gives
  `not_compilable`. The flags are exactly none or `i`.

Do not accept a construct because ICU can run it. A pattern that the phone accepts and Go
refuses, or the opposite, makes the phone and the publish gate disagree on a template.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Template/Dialect/Dialect.swift`,
`ios/HasalaCore/Sources/HasalaCore/Template/Exec/Executor.swift` (`CompiledTemplate.init`).

## ICU gets a translated pattern, compiled without its case flag

The stored pattern is written for Go's RE2 and for JavaScript with the `u` flag. ICU reads
the same text differently by default: `\d` and `\w` are Unicode classes, `$` also matches
before a final line terminator, set syntax has operators (`[a--b]`, `[a&&b]`, nested
sets), and a group name cannot contain `_`. Thus the pattern text is never given to ICU as
it is. The translator parses it with the grammar of JavaScript's `u` mode and writes a form
that ICU cannot read differently:

- each literal as `\x{HEX}` (ASCII letters and digits as themselves);
- each class and each `\d \D \w \W` as an explicit set of code point ranges, with the
  JavaScript `u` meaning (`\d` is `[0-9]`, `\w` is `[0-9A-Za-z_]`);
- `$` as `\z` (end of input only);
- `(?P<name>` as a plain group, with the name kept beside the pattern.

Case-insensitive matching is not left to ICU's `UREGEX_CASE_INSENSITIVE`. That flag uses
full case folding, so `ss` would match `ß`. Go's `(?i)` and JavaScript's `iu` use simple
case folding. With the flag `i`, the translator expands each literal and each set to all
characters that have the same simple fold (for `k`: `K`, `k` and U+212A), and ICU compiles
the result case-sensitive. In a negated class the members are expanded before the negation.

The translator also refuses what JavaScript refuses under `u` and what Go's
`regexp.Compile` refuses (for example a repetition count above 1,000). Thus a pattern that
one of the engines cannot run is not loaded on the phone.

Do not pass pattern text through to ICU, and do not use ICU's case flag. A template would
then read a different value on the phone than in the Go executor, with no error.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Template/Engine/ICUPattern.swift`,
`ios/HasalaCore/Sources/HasalaCore/Template/Engine/CodePointSet.swift`.

## ICU matches on a clone, and never gets a NULL text

`ICURegex` holds one compiled ICU pattern. No match runs on it directly. Each match runs
on a clone from `uregex_clone`, which is cheap because the compiled pattern is shared. ICU
documents that `uregex_clone` is safe on a shared original. The original is written one
time at creation and closed at the end. This is why the type is `@unchecked Sendable` and
why one compiled template can serve concurrent callers. Do not call a match function on
the original.

ICU refuses a NULL text pointer, and an empty Swift array gives one. For empty text the
code gives ICU a buffer of one element with length 0. Do not remove this: an empty subject
or body would then fail and not simply have no match.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Template/Engine/ICUPattern.swift`
(`ICURegex`).

## The ICU limit is 10,000 units for each search, and the deadline is a cancellation

Each search has ICU's processing limit (`uregex_setTimeLimit`) of 10,000 units. One unit is
10,000 operations of the match engine. The limit counts operations, not time, so the result
is the same on each device.

Why a limit is necessary: the dialect bounds the shape of a pattern, not its cost on a
given body. ICU backtracks about ten times slower than V8, where the dialect's costs were
calibrated. Measured on an Apple M-series Mac (2026-10-11, release build), with no limit:
the accepted pattern `[0-9]{1,32}[0-9]{1,32}z` takes 24 s on 2 MB of digits, and `[0-9]+z`
takes 11.9 s on 50,000 digits. One unit is about 90 µs there.

Why 10,000: it is the smallest round limit under which each shipped template completes on
each hostile body of the CoreTemplate tests up to `maxBodyBytes`. The slowest case, the
amount anchor of `enbd.alert.v1` on 2 MB of digits, needs between 5,000 and 10,000 units.
Thus the results stay those of the Go executor. A search that would run longer is stopped,
and the message is refused as `too_large`. A lower limit refuses mail that a template can
read. The value is to be measured again on the oldest test iPhone (inventory
client-core-b §2.3).

One run can cost its pattern count times this limit, which is several seconds on a hostile
2 MB body. The limit for a full run is the caller's deadline. The caller enforces it by
cancelling the task, and the executor checks for cancellation before each search. A
cancellation is not a verdict: nothing about the message is recorded.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Template/Engine/ICUPattern.swift`
(`ICURegex.timeLimit`), `ios/HasalaCore/Sources/HasalaCore/Template/Exec/Definition.swift`
(`TemplateError.cancelled`), `ios/HasalaCore/Sources/HasalaCore/Template/Exec/Executor.swift`
(`runEntry`).

## The template executor treats the body as hostile and pins each platform difference

The Swift executor mirrors `server/internal/tmpl/exec.go` and must give the same bytes on
`conformance/templates`.

The mail body is text that an attacker can write, and it runs through a backtracking
engine on the phone. Three separate controls hold:

1. The dialect, applied when the template loads.
2. The input bounds (2,000,000 bytes of body, 64,000 bytes of subject). A message over a
   bound is refused. It is never truncated.
3. The capture bound: one group gives at most 512 runes.

ICU's limit is a fourth layer, a backstop. A match that it stops is reported as
`too_large`, the same refusal as a body over the bound. The bounds are part of the contract
between the executors: other numbers extract other values. Change them in Go and in Swift
together.

Each place where platforms differ by default is pinned: the trim set is space, tab, line
feed, vertical tab, form feed and carriage return; only ASCII `a` to `z` are upper-cased;
lengths are runes or UTF-8 bytes; money is an integer parsed from a digit string that
passed a shape check; the date layouts are parsed by hand; each text comparison is on
bytes. A body date has no zone: the wall-clock time in the UAE is written as UTC, as the Go
executor does. Do not "correct" it to real UTC in the executor.

The executor does not apply the sender-domain gate, and it takes no domain. That gate
belongs to the trusted lane, which has the verified domain. If this function took a
domain, a caller could give it the `From` line of the body, which any sender can write.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Template/Exec/Executor.swift`
(`CompiledTemplate.execute`, `TemplateBounds`, `Extraction.postedAt`).
