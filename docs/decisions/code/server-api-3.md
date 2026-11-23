# Sync routes (api): decisions from the code (2026-11-21)

These decisions were code comments under `server/internal/api`. Code comments are
not permitted (`scripts/comment-lint.ts`), thus the decisions are here.

## A pull page never ends inside an upload batch

The server stores the head signature of an upload batch (spec 01 §7.1) on the last row
of that batch only. All other rows have `head_sig: null`. A pull page never ends inside
a batch (spec 02 §11.3). Thus the last row of each writer in a page always has a head
signature, and the phone can verify each writer's head from one page.

Do not let the row limit or the byte budget cut a page between two rows of one batch.
The phone then gets a writer's last row with no signature and cannot verify that head.

Applies to: `server/internal/api/sync.go` (`Row.HeadSig`).

## Pull reports `complete` from the stream maximum, read after the page

`next` in a pull or hash-list answer is the largest seq that the page returned for the
stream. An empty page returns the cursor that the caller sent. Thus a client that sends
`next` back as `after` never goes backward.

`complete` says that the client has all rows of the stream. The server computes it
against the committed maximum seq of the stream. It does not infer it from the page
size. A page can end early because of the byte budget, with fewer rows than the limit.
A client that reads "short page, therefore done" stops with rows still on the server.

The server reads the maximum after it reads the page, never before. Rows that commit
between the two reads make the answer "not complete", and the cost is one empty round
trip. With the other order, the answer can be "complete" while rows exist, and the
client does not get its data.

Applies to: `server/internal/api/sync.go` (`PullResponse`, `handlePull`, `handleHashes`,
`pageComplete`), `server/internal/api/sync_test.go`
(`TestAPullTruncatedByTheByteBudgetIsNotComplete`).

## The account of a sync request comes only from the session

No sync request shape has a user id. The account is always the one that the session
resolves to. A `user_id` in a query or a body has no effect.

Do not add a user field to `UploadRequest` or to the pull parameters. With such a field,
a session of one account can aim a read or a write at a different account. The only
user id that a client sends is the one in the AAD of a sealed frame, and the position
check refuses a frame that names a different account.

Applies to: `server/internal/api/sync.go` (`UploadRequest`, `handleUpload`, `handlePull`).

## A pull takes its slot before its rate token

An account has at most 2 pulls or hash lists in flight (spec 02 §11.3). The third gets
429. A pull first takes one of these slots, then spends a token of the `pull-user`
limiter. A pull that the limiter refuses gives its slot back.

Keep this order. With the limiter first, each pull that is refused as the third in
flight also spends a token, and a client that retries empties its own rate budget. If
the slot is not given back, the account stays at its bound with no request in flight.

Applies to: `server/internal/api/sync.go` (`pullAdmitted`).

## The upload checks run in a fixed order, and a batch is stored whole or not at all

`POST /api/v1/sync` (spec 02 #30, §11.1) does its checks in this order:

1. The session resolves the account.
2. The shape of the body: the stream, the batch size, a 64-byte `head_sig`.
3. The writer: the writer id grammar (§4.8), then the session must be bound to exactly
   that writer (spec 02 §9.4), and the writer must be live.
4. The account has keys.
5. Each blob is examined: its size, the plaintext predicate, and the AAD of the exact
   position where it will be stored.
6. Only then the append transaction opens. In it, the writer row is read `FOR SHARE`,
   the chain is joined to the stored head, the key epoch is checked for the rows above
   the head, and the head signature is verified over the last row as the server computed
   it again.

The cheap checks that need no database come first, and the transaction opens only for a
batch that can be stored. Each step also relies on the steps before it. Do not move a
later check before an earlier one.

Nothing is stored unless the whole batch is stored. `oplog.AppendClient` rolls back as
one unit, thus a refused batch uses no seq and no writer counter. A partial store leaves
holes in the writer's chain.

Applies to: `server/internal/api/sync.go` (`handleUpload`).

## Upload has a request budget for the pool and a byte budget for storage

An upload passes three controls, each for a different resource.

- A bound of 2 uploads in flight for each account, and the `SyncPerUser` request rate.
  The handler spends these before it reads the body. They are the fairness control of
  the database pool: one account cannot hold the 16 connections with append
  transactions one after the other. They are not the storage control. A real import and
  abuse differ in blob size, not in request count, thus no request rate can limit
  storage.
- The `SyncUploadBytes` byte budget. The handler spends it immediately before the
  append, after all validation. Thus a malformed batch costs no budget. The charge is
  the number of bytes that become durable, and it is all or nothing for the batch, as
  the append is. An append that adds nothing gets its bytes back.

Do not move the byte charge before validation, and do not replace it with a request
rate. The first lets bad requests use up an account's budget. The second does not limit
the bytes on the disk.

Applies to: `server/internal/api/sync.go` (`handleUpload`), `server/internal/api/api.go`
(`syncRate`, `syncByteBurst`, `syncByteRate`).

## Too soon is 429 `upload_bytes`; too much is 413 `account_full`

The two storage refusals of an upload must stay different, because the client does
different things with them.

- `429 upload_bytes` comes from the byte limiter, before the append. The batch is not
  too large; it is too soon. The same batch is accepted a short time later, and the
  answer has `Retry-After`. It is not a 413.
- `413 account_full` comes from the account ceiling (`internal/budget`) in the append.
  It is a policy result, not a fault. The same batch is never accepted until something
  is deleted or the ceiling is raised. It is not a 429: a client that tries it again on
  a timer never stops. The body has the account's own numbers (`budget`), so the app
  can show a true message.

The ceiling must never be answered as a 500. A 500 tells a person with a full account
that the server is broken, which is not true and gives them nothing to do. Thus the
handler also answers 413 when the refusal comes without its detail, although
`budget.Admit` always gives the detail.

Applies to: `server/internal/api/sync.go` (`handleUpload`, `writeAppendErr`).

## The content of a refused frame never goes to a log

When the plaintext predicate refuses a blob, the server logs the account, the index of
the blob and the name of the failed check. It never logs bytes of the frame. A refused
frame can be readable money data, and an operator log is outside the encryption of the
op log.

Do not add the frame, or a part of it, to this log line or to an error detail.

Applies to: `server/internal/api/sync.go` (`handleUpload`).

## A batch that does not chain to itself is a client error, not a chain break

The handler examines the internal links of a batch before the append: consecutive
counters, each `prev_hash` equal to the previous `blob_hash`, and each `blob_hash` equal
to SHA256(`prev_hash` || blob). A failure is `400 bad_request`.

`oplog.AppendClient` does the same check and reports `ErrChainBreak`. The API answers
that error as `409 chain_break`, which is a hard stop of sync: the app shows a warning
that the server may have changed the person's data, and the person cannot dismiss it
(spec §3.3:68). Nothing that the server does can make the blobs of one request fail to
link to each other. Thus such a failure is always an arithmetic error in the client,
and it must not show that warning.

`chain_break` stays for the case relative to the stored head. There it is not possible
to know if the client skipped rows or the server lost rows, and the hard stop is
correct.

Do not remove the check in the handler. Without it, a client bug tells people that
their operator tampered with their log.

Applies to: `server/internal/api/sync.go` (`handleUpload`),
`server/internal/api/sync_test.go`.

## Each uploaded blob is checked for size, then sealing, then position

The checks of one blob follow spec 02 §11.1 step 5.

1. Size (spec 01 T18). The cap comes before the bucket check, so a blob over the cap
   gets `413 too_large`, not a `400 bad_bucket` that says "not a size bucket".
2. The plaintext predicate (security finding F1). A blob that does not look like a
   sealed frame v3 gets `400 plaintext_refused` with the name of the failed check,
   before anything is stored. This includes a ledgerd v1 or v2 frame, a zero nonce or
   tag, zero padding, and a cleartext gzip header where ciphertext must be.
   `oplog.Row.validate` runs the predicate again in the append, and the
   `op_log_blob_is_sealed` CHECK in the database is the guarantee behind the two.
3. The position. The AAD in the frame must be the AAD of the account, stream, writer
   and counter where the blob will be stored, or the answer is `400 aad_mismatch`. This
   stops a blob that was sealed for a different position, and also a blob that was
   sealed for a different account. The AAD is in the cleartext header, thus the server
   needs no key.

The key epoch is not checked here. `oplog.AppendClient` checks it after it reads the
head, and only for the rows above the stored head (spec 01 §8.3). Thus a batch that is
sent again is never refused for its epoch (`409 stale_epoch`).

The framing version does not change. A blob with a different version cannot be opened by
any client. The op log is append-only, so such a row is a permanent loss that nobody
sees. Thus the server refuses it at upload and does not store it for later. An empty
blob gets a 400 and must not cause a panic.

Applies to: `server/internal/api/sync.go` (`decodeUploadBlob`),
`server/internal/api/sync_test.go`.

## Append conflicts share status 409 and differ in code and detail

The conflicts of an append all answer 409. The status does not tell them apart; the
error code and the detail do, because the client does a different thing for each one.

- A chain break (`chain_break`) is a hard stop of sync (spec §3.3:68).
- A batch that is partly applied (`conflict`) has a simple remedy. The server refuses a
  batch that straddles the stored head; it does not trim it. The detail is the client
  contract, the same words as in `oplog/chain.go`: "read the chain head and resend only
  the rows above it". A test reads this sentence.
- A position that is already held (`conflict`) is a broken server invariant. The client
  cannot repair it.

Each detail describes only the caller's own log, thus it discloses nothing. Do not give
these cases one common detail, and do not change the sentence of the partly applied
case in one place only.

Applies to: `server/internal/api/sync.go` (`writeAppendErr`).

## Race tests warm the connection pool first

`pgxpool` opens its connections only when they are necessary. In a test that starts
requests at the same time to prove that the server serializes them, the first requests
each wait for a new connection. They then run one after the other, and the test passes
with code that does not serialize.

Each such test opens the connections first (`warmPool`). Do not remove that call: the
test stays green and proves nothing.

Applies to: `server/internal/api/sync_test.go` (`warmPool`).

## Failed writer registrations have their own rate limit

The challenge limit bounds only the registrations that succeed, because each of them
spends one challenge. A registration that fails (for example a nonce that was used
before) spends no challenge budget, but it costs
two database round trips in `consumeChallenge` before any signature work. Thus
`POST /api/v1/writers/register` has its own limiter for each account
(`RegisterPerUser`), and a failed attempt counts against it. The limit is for each
account, so one account cannot stop another.

Without this limiter, a session can make the server do database work at any rate with
registrations that always fail.

Applies to: `server/internal/api/routes_writers.go`, `server/internal/api/api.go`
(`registerRate`), `server/internal/api/sync_test.go`
(`TestRegistrationAttemptsAreRateLimited`).

## An invite code alone does not prove an address

An invite link has the code in its path and the link key in its fragment (spec 02
§14.1, spec 07 §4.4). Mail scanners and link previews see the path. Thus the code alone
proves nothing about who holds the address. At `signup/begin`:

- An addressed invite with a different address gets the same `not_invited` bytes as an
  unknown code.
- The correct address with no key, or with a different key, is accepted, but the address
  is not proven and still needs a signup code.
- A malformed key is a 400.
- Only the key of the link proves the address.

Do not treat the code as proof of the address. A scanner that opened the link can then
make an account with a proven address that is not its own.

Applies to: `server/internal/api/waitlist_test.go`, `server/internal/invites/invites.go`
(`Resolve`).
