# Server step-up, writers, server keys, blob framing and storage budget: decisions from the code (2026-11-21)

These decisions were code comments under `server/internal/auth` (the files from
`stepup.go` to `writer_test.go`), `server/internal/authkeys`, `server/internal/blob`
and `server/internal/budget`. Code comments are not permitted
(`scripts/comment-lint.ts`), thus the decisions are here.

## A failed step-up proof burns its nonce, and a failed action does not

A step-up (spec 01 §10.2, spec 02 §8) is a single-use proof that the person approved
one action with its exact parameters. The challenge is
C = SHA256("hasala/v1/step-up" ‖ 00 ‖ nonce ‖ action ‖ 00 ‖ params_hash). The guarded
request carries the nonce and the proof. The server verifies the proof and spends the
nonce in the transaction of the action.

- A failed proof rolls the transaction of the action back. The burn of the nonce then
  commits in a transaction of its own (spec 02 §8.1 step 4). If the burn were in the
  transaction of the action, the rollback would remove it, and one nonce would buy
  many attempts.
- An action can refuse the proof itself. `keys.wrap.put` refuses when the asserting
  credential is not the credential of the wrap. `account.unfreeze` refuses when the
  factor is not older than the event that caused the freeze. These are failed proofs,
  and they burn the nonce.
- An action that fails after a good proof (for example `409 head_moved`) leaves the
  nonce usable until it expires. The person does not prove again for the next attempt.
- Two failed proofs also move counters: a device proof with a valid device signature
  and a wrong password, and a `device_code` proof with a valid device signature and a
  wrong code. The second keeps its nonce until the fifth wrong code.
- A request with no step-up answers `403 step_up_required` and changes nothing. Each
  failed proof answers the one `403 step_up_failed`. Do not add a code or a detail that
  tells which check failed.

Applies to: `server/internal/auth/stepup.go` (`StepUp.Run`, `StepUp.fail`,
`ErrStepUpRequired`, `ErrStepUpFailed`).

## A device proof checks the device key before the password or the code

A step-up has three kinds of proof:

- `passkey`: a WebAuthn assertion with user verification over C, by one of the
  credentials of the account.
- `device`: the signature of the bound writer's device key (DAK) over
  `DeviceStepUpMessage(C, writer_id)`, then the password value S.
- `device_code`: only for `password.reset` (C8). The same DAK signature, then the
  `password_reset` code that the begin call sent by email. These codes have a budget
  for each account (5 begins each hour).

The DAK signature is always checked first, and the writer of the proof must be the
live writer of the session. Thus only an enrolled iPhone with its owner present can
submit a password or a code on this path.

- An invalid DAK signature changes no counter. A caller without the device cannot use
  this path to guess a password or to use up the limits of the account.
- A valid DAK signature makes the attempt a bound attempt (review 2 F-01). The pause
  of the account and the counter of the address do not apply to it. The password
  budget of that writer applies.

Do not check the password or the code before the DAK signature. Do not count a
bound attempt against the pause or the address counter.

Applies to: `server/internal/auth/stepup.go` (`StepUp.verify`, `StepUp.verifyDAK`,
`StepUp.verifyDevicePassword`, `StepUp.charge`).

## Only the authority key enrols a writer

A writer is enrolled only by the account's authority key (AAK), with this message
(spec 01 §4.8, §10.5; spec 02 §10.2):

    "hasala/v1/writer-registration" ‖ 00 ‖ nonce32 ‖ 00 ‖ writer_id ‖ 00 ‖ dwk_pub32 ‖ dak_pub65

The AAK signs it over a single-use nonce that the server issued. The signature
certifies the two device keys: the DWK (Ed25519; it signs batch heads, revocations
and bindings) and the DAK (P-256 in the Secure Enclave; it approves step-ups).

The AAK is in memory only after account creation, a PRF unlock or the entry of the
recovery phrase. Thus a stolen session cannot make this signature. There is no other
path: no step-up, no approval by an enrolled device, no trust on first use and no
recovery-key path (spec 01 DEV-3). The bootstrap registers the first writer with the
same message.

Do not add a second way to enrol a writer. A path that a session or an enrolled
device can use lets a thief of that session or device add a writer of their own.

Applies to: `server/internal/auth/writer.go` (`Writers.Register`, `insertWriterTx`),
`server/internal/auth/accountkeys.go`.

## A revocation pins the final head of its target

Any live writer of the account can revoke a writer, the target included (spec 01
§10.6, spec 02 §9.5). The request needs the step-up `writer.revoke` and a DWK
signature over this message:

    "hasala/v1/writer-revocation" ‖ 00 ‖ nonce32 ‖ 00 ‖ writer_id ‖ 00 ‖ u64be(final_counter) ‖ final_head32

The message pins the last counter and the last hash of the target's chain. The server
requires them to be the current head, and it compares them under a `FOR UPDATE` lock
on the target's writer row. An upload reads the same row `FOR SHARE`. Thus no row can
land between the comparison and the revocation (R-02). After the revocation, a reader
accepts no row of that writer above the pinned head.

Do not read the head before the lock, and do not remove the lock from the upload
path. A row that lands after the comparison is then stored and never accepted.

The `head_moved` error goes to the operator log. Its text names the counter and never
the head hash (spec 02 §20).

Applies to: `server/internal/auth/writer.go` (`Writers.Revoke`, `writerHead`,
`ErrHeadMoved`).

## The runtime role cannot change key_history

`key_history` is append-only (spec 02 D-6, spec 01 §9). A trigger refuses each change
of a row, and the runtime role holds no `UPDATE` or `DELETE` privilege on the table.
Each row carries the signature that authorized it and the nonce of that signature, so
a device verifies the log itself.

The owner of the schema (`hasala_migrate`) can disable the trigger. This is one reason
why `hasalad` never serves as the owner (spec 02 §5.6). Do not give the runtime role
more privileges on this table, and do not run `serve` as the owner.

Applies to: `server/internal/auth/writer.go`, `server/internal/auth/writer_test.go`
(`TestKeyHistoryGuardBindsANonOwnerRuntimeRole`).

## A writer challenge is spent by the attempt

One writer challenge serves a registration, a revocation or the bootstrap. The server
spends it before it verifies the signature, in a statement outside the transaction of
the action. Thus a failed attempt cannot roll the spend back, and one nonce buys one
attempt.

A nonce that is unknown, of another account, used or expired gets the same
`ErrBadSignature` (spec 02 §6.3). The answer does not say which.

There is one check before the spend: a registration whose writer id, DWK or DAK is
already enrolled is a malformed request, and its nonce stays unspent. This answer
discloses nothing. The caller holds a session of that account and can read the roster.

Do not move the spend into the transaction of the action, and do not move the
signature check before the spend.

Applies to: `server/internal/auth/writer.go` (`consumeChallenge`, `Writers.Register`,
`Writers.Revoke`).

## The two server key files and what each derives

The server has two key files (spec 01 §4.10–§4.11, §12.2; spec 02 §3.3). Each use has
its own subkey, made with HKDF, a salt of 32 zero bytes and its own info string:

    K_salt     = HKDF(salt_key,   0^32, "hasala/v1/server/password-salt")
    K_pepper_g = HKDF(auth_key_g, 0^32, "hasala/v1/server/password-pepper")
    K_code     = HKDF(auth_key_c, 0^32, "hasala/v1/server/email-code")
    K_tag      = HKDF(auth_key_c, 0^32, "hasala/v1/server/email-tag")
    key_id(k)  = hex(HMAC(k, "hasala/v1/server/auth-key-id")[0:8])

    s_srv     = HMAC(K_salt, email_norm)
    pw_hash   = PBKDF2(HMAC(K_pepper_g, S), pw_salt, 100000)
    code_mac  = HMAC(K_code, purpose ‖ 00 ‖ uuid_raw(code_id) ‖ email_tag ‖ code)
    email_tag = HMAC(K_tag, email_norm)

- `salt_key` makes only `s_srv`, the salt of an address. `s_srv` is public by design:
  the server gives it to each caller who names an address. It is the same before,
  while and after an account exists, so it does not show that an account exists.
- `salt_key` is never rotated. The device stretches the password with `s_srv`, so a
  different `salt_key` makes each stored password fail.
- `auth_key` rotates by generation. A stored hash names its generation. The beta has
  generation 1 only.
- No key is derived from a password, and nothing is wrapped under one (PO B, spec 01
  §4.10). S is peppered and hashed for comparison only.
- In the build of `hasalad`, `internal/authkeys` is the only package that imports
  `crypto/pbkdf2` (spec 02 §4.4 fence 3(d)). Do not import it in a different package
  of the server.

Do not use one subkey for two purposes, and do not change an info string. Each stored
hash, code MAC and email tag then stops to agree.

Applies to: `server/internal/authkeys/authkeys.go` (`New`, `subkey`, `Keys.PasswordSalt`,
`Keys.VerifierHash`, `Keys.CodeMAC`, `KeyID`).

## A waiter that leaves the PBKDF2 gate late passes its slot on

A caller that waits at the PBKDF2 gate stops when its wait time or its context ends.
It then removes itself from the queue. If it is no longer in the queue, a release
gave it a slot at the same moment. The caller does not use that slot, so it must
release it to the next waiter or to the free count.

Do not remove this release. Without it, each such race loses one slot permanently.
After sufficient losses the gate has no slot, and each password request answers
`503 unavailable`.

Applies to: `server/internal/authkeys/gate.go` (`Gate.Acquire`).

## The server build has no sealer

The server holds no key. It never seals, opens, compresses or decompresses a blob
(spec 02 §4.4 fence 3). `internal/blob` reads only framing that is cleartext by
design: the length of the frame (its bucket), the key epoch and the AAD.

The sealed frame v3 (spec 01 §6.1) has this layout, with L = `aad_len` and n = the
length of the frame, which is exactly one bucket:

    [0]          version    0x03
    [1:5]        key_epoch  u32be, 1 to 2^31-1
    [5:7]        aad_len    u16be = L
    [7:7+L]      aad        user_id|hot|writer_id|writer_counter
    [7+L:19+L]   nonce      12 bytes
    [19+L:n-16]  ct         AES-256-GCM of R = u32be(m) ‖ gzip(plaintext) ‖ zero bytes
    [n-16:n]     tag        16 bytes

The production sealer is the device's (`CoreCrypto.Sealer` in Swift). The Go reference
sealer and opener for v3, and the reader of the ledgerd v1 plaintext frame, are in
`internal/blob/blobtest`. That package is test and vector code only. The build graph
of `cmd/hasalad` must never reach it (fences 1 and 3: no `PlaintextSealer` and no
AES-GCM in the server), and `cmd/hasalad/fence_test.go` enforces this. The v1 code
stays only to read the v1 fixtures in `conformance/blob` and `conformance/ts`.

`blob.Header3` is the one function in the production package that builds a part of a
frame. It builds only the cleartext header. The reference sealer uses it, so the two
packages cannot disagree on the layout. The server itself never builds a frame.

Do not import `blobtest` from a package that `hasalad` links, and do not move the
sealer into `internal/blob`. A server that can seal or open is not blind.

Applies to: `server/internal/blob/blob.go`, `server/internal/blob/frame3.go`
(`Header3`), `server/internal/blob/blobtest/seal3.go`,
`server/internal/blob/blobtest/v1.go`.

## Frames are padded to a size ladder, and the length is in the encrypted region

Each frame is padded to one of seven sizes: 1, 4, 16, 64, 256, 512 and 1024 KiB. A
300-byte op and a 900-byte op have the same size on the wire and in the database.
Thus the server, or a person who steals a backup, learns the bucket and nothing more
exact.

The 4-byte payload length is the first field of the encrypted region. It is not in
the cleartext header, and no cleartext byte depends on the size of the payload. Two
ops of different sizes in one bucket differ only in bytes that are encrypted.

Do not move the length, or any other value that depends on the size, into the
cleartext header. The padding then hides nothing. Do not change the ladder alone: the
database CHECK and the reader on the phone hold the same list.

Applies to: `server/internal/blob/blob.go` (`Buckets`, `MaxBucket`),
`server/internal/blob/frame3.go`, `server/internal/blob/blobtest/v1_test.go`
(`TestPayloadLengthPrefixesTheSealedRegion`,
`TestSameBucketBlobsAreIndistinguishableOnceSealed`).

## The frame header has one reader, and the names and bounds of the predicate are a contract

`Parse3` is the only way that production code reads the key epoch or the AAD of a
frame (spec 01 §6.1, "one versioned layout function"). It runs `LooksSealed` first, so
each offset is in range, and no other code computes an offset. Only `Parse3` makes a
`FrameV3`. Do not read a header field with a slice expression in a different place.

These values of the predicate are shared with the phone and the database (spec 01
§8.1):

- The version byte is 3 and nothing else. 0x01 is the ledgerd plaintext frame and 0x02
  was an encryption benchmark. The two are refused.
- `MaxEpoch` is 2^31-1. The database column and Swift's `Int32` agree on it (N-01).
- `minTail` is 67. Check 4 requires L + 67 ≤ n. This keeps the 32-byte window of check
  7, the bytes from n-48 to n-16, inside the encrypted region.
- The names of the checks (`bucket`, `version`, `epoch` and the others) are in the
  order of the predicate. They are the vocabulary of the API (spec 02 §11.2) and the
  raw values of the Swift enum. A renamed check changes what the app reads.

Applies to: `server/internal/blob/frame3.go` (`Parse3`, `FrameV3`, `Version3`,
`MaxEpoch`, `minTail`, `CheckBucket` and the other check names).

## The AAD is not escaped, so an envelope is validated before it is used

The AAD of a blob is `user_id|stream|writer_id|writer_counter`, with the counter in
decimal. These four fields are exactly what spec 01 §6.2 binds. The
`op_log_aad_matches_position` CHECK builds the same string from the columns of the
row, so the Go function and the CHECK change together or not at all.

The separator `|` is not escaped. A separator in a field lets two different positions
give the same associated data. Thus `Envelope.Validate` refuses a writer id that
contains it, and each caller validates the envelope before it calls `AAD`. The other
three fields cannot contain it: a UUID, the one stream name and a decimal number.

`Validate` also refuses a stream that is not `hot`. A wrong stream name is as bad as a
separator: it is a valid position on a different chain, it is in the AAD permanently,
and no other writer reconciles with it.

Applies to: `server/internal/blob/blob.go` (`Envelope`, `Envelope.AAD`,
`Envelope.Validate`, `aadSeparator`).

## One plaintext cap binds the sealer and the opener

`MaxPlaintext` (2 MiB) is the limit of the plaintext of one op blob (spec 01 §6.3). It
applies on the two sides of the sealer: a sealer refuses a larger plaintext, and an
opener stops at the same limit. The server never sees plaintext. The constant is in
the server package so that the reference sealer and the documents use one number.

Nothing that a sealer accepts can fail to open. A cap on the opener only lets a legal
blob be stored and then never be read, and the op log is append-only. Do not change
the cap on one side.

Applies to: `server/internal/blob/blob.go` (`MaxPlaintext`),
`server/internal/blob/blobtest/seal3.go` (`GunzipStrict`),
`server/internal/blob/blobtest/v1_test.go` (`TestSealAndOpenAgreeOnTheSizeCap`).

## One gate admits durable bytes, in the transaction of the caller

Each durable byte must belong to exactly one account when it is admitted, and the
admission must fail closed against the budget of that account, in one place and not
in each endpoint. `Gate.Admit` is that place. The op log append calls it, because the
append is the one place where bytes can accumulate at the scale of an attack. The
caller side is in `server-oplog-to-oplogtest.md` ("The storage ceiling is charged in
the append transaction").

There are three tables:

- `account_usage` is the ledger: one row for each account and resource. `Admit`
  changes it in the transaction of the caller. Thus the bytes and the number that
  counts them commit together or not at all, and an append that rolls back leaves the
  ledger as it was. This is why `Admit` takes a `pgx.Tx` and not a pool.
- `account_limits` is the policy: one default row and optional rows for single
  accounts. To raise a ceiling is an `UPDATE`, not a deployment.
- `account_refusals` is the receipt: a count of denials for each account, day and
  resource, with no content.

There is one ledger resource, `oplog_hot_bytes`, with the ceiling
`account_limits.oplog_bytes` (256 MiB by default; spec 02 §5.4). The resources
`upload_bytes`, `headroom` and `suspended` are only names for refusals. They have no
ledger row and no ceiling.

The contract of the caller: when `Admit` returns an error, roll the transaction back,
then give the error to `Gate.RecordRefusal`. `Admit` does not end the transaction,
because it is the caller's.

Applies to: `server/internal/budget/budget.go` (`Gate.Admit`, `Gate.RecordRefusal`),
`server/internal/oplog/append.go`.

## A refusal is counted outside the refused transaction

The count of a refusal is written through the pool, on its own connection and in its
own transaction. It is the only statement of the gate that does not use the
transaction of the caller.

The reason: `Admit` refuses with an error, and the caller can only roll back. A count
that was written in that transaction goes away with it. `account_refusals` then shows
zero while the server declines writes all day, and the purpose of the table is that
no refusal is dropped silently.

- The count runs only after the refused transaction rolled back. Thus a request never
  holds the connection and the locks of that transaction while it waits for a second
  connection.
- The context of the count is detached from the context of the request, so a refusal
  is counted when the request was cancelled. It has a limit of 5 seconds, so a blocked
  server does not hold the connection.
- A gate with no pool refuses each admission with an error. It could do the
  arithmetic, but it could not count a refusal.

Do not move the count into the transaction of the caller.

Applies to: `server/internal/budget/budget.go` (`Gate`, `Gate.Admit`,
`Gate.recordRefusal`, `Gate.RecordRefusal`).

## account_refusals has one writer and one day clock

`CountRefusals` is the only writer of `account_refusals`. The ceiling of the gate and
the refusals of the API (the upload byte limiter, the headroom fuse, suspension) all
go through it. The names of the API's refusals are in `internal/budget` for this
reason: a writer that cannot name each legal resource makes somebody build a second
writer.

Two writers existed before. They had two day clocks, one from Go and one from the
database, and only one of them skipped a deleted account. The table then held two
different days for one moment, and it could get a row for an account that was gone.

- The day is `(now() AT TIME ZONE 'UTC')::date`, from Postgres. It is one stamp for
  each table that an operator joins. A count that waited in a buffer gets the day on
  which it is stored, which is the only day on which all writers agree.
- `Gate.now` changes the day only in the tests of the package. It is not exported, and
  `New` never sets it. A test asserts that it is off by default.
- `CountRefusals` takes a `*pgxpool.Pool` and not a `pgx.Tx`. Thus the compiler
  prevents a count in the transaction of the caller. Do not change the parameter to
  an interface that a transaction satisfies.
- A count for an account that was purged is skipped, with no error. The API sends
  these counts from a buffer and tries a failed one again. An error that can never
  succeed is then tried again without end.

Applies to: `server/internal/budget/budget.go` (`CountRefusals`, `countRefusals`,
`Gate.now`, `Gate.overrideDay`, `ResourceUploadBytes`, `ResourceHeadroom`,
`ResourceSuspended`), `server/internal/budget/refusals_test.go`.

## The resource names are closed sets that agree with the database

The ledger resources are a closed set, and it is the same set as the CHECK on
`account_usage.resource`. A new value needs a migration. That effort is correct for a
claim that a new write path can fill the disk.

The refusal resources are a second closed set, and it is wider than the first on
purpose. Each source of a refusal needs a place where it is counted: the ceiling, the
upload byte limiter, the headroom fuse and suspension. The CHECK
`account_refusals_resource_is_closed` in the baseline migration states the same set
and is the authority.

The Go list exists so that a wrong name is a Go error that names the resource. Without
it, a wrong name is a constraint violation in the buffered retry loop of the API,
which tries again without end. Change the Go list and the CHECK together. A test
compares the two sets in the two directions.

Applies to: `server/internal/budget/budget.go` (`ResourceOplogHotBytes`,
`refusalResources`), `server/internal/budget/refusals_test.go`
(`TestTheAllowlistIsExactlyTheDatabasesClosedSet`).

## Budget rows are locked in one order

`Admit` locks all usage rows of a family (the resources that one ceiling limits) with
one `SELECT ... ORDER BY resource ... FOR UPDATE`. `ORDER BY resource` is the lock
order, not a choice of presentation: Postgres locks the rows in the order of the
sorted plan. Thus two transactions on one family take the same rows in the same
order and cannot deadlock.

- `family.members` is kept sorted, because it is also the lock order. Do not change
  its order to make it easier to read.
- `Admit` inserts each missing member row before the lock, in the same order. Without
  the insert, a family with a row that was never written locks one row now and the
  other row in a later call, in the order in which the calls come.

Applies to: `server/internal/budget/budget.go` (`family`, `Gate.Admit`,
`Gate.lockFamily`).

## A refusal and a server fault are different errors

`ErrRefused` means only that the account is at its ceiling. It is a result of the
policy, and the person can be told about it (`413 account_full`). Each other failure
of `Admit` is a different error, because it is a fault of the server. One error for
the two cases shows an outage to a person as "you have no space".

`Admit` does not guess when a row is missing:

- No default row in `account_limits` is an error. There is no fallback constant in the
  code. A trigger keeps the default row from deletion. The two possible guesses are
  "refuse each write on the host" and "permit each write on the host", and the code
  must not make one of them silently.
- A usage row that is missing after `Admit` inserted it means that the account was
  purged during the append. `Admit` returns an error. A zero in its place writes a
  usage row for an account that no longer exists.

Applies to: `server/internal/budget/budget.go` (`ErrRefused`, `RefusedError`,
`Gate.limitFor`, `Gate.lockFamily`).

## A release is never refused, and an underflow is an error

A negative delta is a release. A ceiling never refuses a release: an account that is
above a ceiling that was lowered must be able to get smaller.

A release that is larger than the stored amount returns `ErrLedgerUnderflow` and
changes nothing. It is not a refusal, and it is not counted in `account_refusals`,
because nothing that a person did was declined. It means that the ledger and the
stored bytes disagree, which is a server bug. It is the signal to run the
reconciliation of `internal/verify`.

Do not clamp the amount at zero. A clamp changes an accounting bug into free quota,
silently and permanently. The CHECK `account_usage_amount_is_non_negative` holds the
same rule in the database.

Applies to: `server/internal/budget/budget.go` (`Gate.Admit`, `ErrLedgerUnderflow`).
