# API routes (api): decisions from the code (2026-11-21)

These decisions were code comments under `server/internal/api`. Code comments are
not permitted (`scripts/comment-lint.ts`), thus the decisions are here.

The sync routes have their own file, `docs/decisions/code/server-api-3.md`. It records
the upload budgets, the 429 and 413 answers of an upload, the batch that is partly
applied and the plaintext refusal.

## The contract of the API

Package `api` is the HTTP surface of `hasalad` (spec 02 §6, §7). It is the first code
that a network can reach. It changes the exact errors of the internal packages into
answers that help a client and do not help an attacker.

- **The account comes from the session.** Each query uses the user id that the session
  token resolves to. No request shape has a user field. Do not add one: a session of
  one account can then aim a request at a different account.
- **A 64-bit integer is a decimal string on the wire** (`seq`, `writer_counter`). A JSON
  parser can change a JSON number into a float, and a float cannot hold each 64-bit
  value. Do not send these values as JSON numbers.
- **A chain hash is lower-case hex. Each other binary field is standard base64** (blob
  bodies, public keys, nonces, signatures). The fields that the spec names as b64url
  are the exception.
- **A session is a weak capability.** A session token permits a read of the account's
  log, an append to it and a registration challenge. It does not permit the enrolment
  of a writer or a passkey, or the deletion of the account. Those operations need a
  signature over a single-use nonce from the server, or a step-up that is bound to the
  action (spec 02 §8). Thus a stolen session token cannot add its own device or passkey.
  Do not add a route that changes auth, keys or mailboxes on a session token alone.
- **One file for each area, and one mount function for each file** (spec 02 §4.2).
  `Handler` calls each mount function. Add a route to the file of its area.

The session answers are in "One 401 for every session rejection, and 410 only for a
deleted account".

Applies to: `server/internal/api/api.go` (package `api`, `Handler`).

## One 401 for every session rejection, and 410 only for a deleted account

Each session rejection gives the same 401 with the same body: no header, a wrong
scheme, an unknown token, an expired token, an idle token, a revoked token. Package
`auth` returns a different error for each cause, and the log shows it. A response that
shows the cause is an oracle. `writeUnauthorized` takes no arguments, so no caller can
change the answer.

There is one exception. A token of a deleted account gets `410 account_deleted`. This
is the only answer on which a device deletes its local data. The status is 410 because
its meaning is exact: the resource existed, it is gone, and that is permanent.

- Do not make an expired or revoked token a 410. Tokens expire routinely. The device of
  a person who is offline then deletes its outbox, and those ops are lost.
- Do not answer an unknown token as a deleted account. That tells a caller with no
  session that a token it guessed was real one time.
- Do not make a device delete its data on a 401.
- A failure that is not a rejection (the database does not answer) is a 500, not a 401.

A test of the 410 must delete the account through the real purge. The state "the
session resolves and the user row is missing" does not occur in production, thus a test
that deletes rows by hand does not test the real path.

Applies to: `server/internal/api/api.go` (`requireSession`, `sessionGate`,
`writeUnauthorized`, `writeAccountDeleted`),
`server/internal/api/deleted_account_test.go`.

## The reason for a refusal goes to the log, not to the response

`errorBody.Detail` is present only where it describes the caller's own submission, for
example a malformed blob or a break in the caller's own chain. It is empty on a 401, on
a rejected registration, and on each 403 of the key, writer and step-up routes. On
those answers, each difference is an oracle. The reason goes to the operator log
(`Server.Logf`).

`budget` is present on one answer only, `413 account_full`. Each of its fields
describes the caller's own account, which the caller can read, thus it discloses
nothing. It is absent on all other answers, so a client can use its presence as the
signal. Do not add it to a different error.

`403 account_suspended` has a detail for a person. The caller holds a session of that
account and reads a fact about its own account, thus there is no oracle.

Applies to: `server/internal/api/api.go` (`errorBody`, `BudgetInfo`, `Server.Logf`),
`server/internal/api/keyerrors.go` (`writeKeyErr`),
`server/internal/api/budget_test.go`.

## A log line names the route pattern, not the path

A log line names a request by the route pattern that matched (spec 02 §20). It does not
use the path. A path can contain an id, for example a credential id or a token of a
link. Do not log `r.URL.Path`.

Applies to: `server/internal/api/api.go` (`route`).

## A limiter runs before authentication and before database work

- Each in-memory limiter has a bound on its number of keys (spec 02 §16.2). Without the
  bound, a caller can make the limiter itself use up the memory.
- A limiter of a route with no session runs before all database work.
- The passkey limiters also run on the passkey routes that need a session, and they run
  before the session is resolved. Thus a caller with no session still spends a token.
  With the other order, the easiest way past the limit is to send no credential.
- The per-IP limiter runs first. Only a request that passed it spends a token of the
  global limiter. With the other order, one host uses up the shared budget with
  requests that the per-IP limiter refuses, and all other clients get 429.

The passkey routes need these limits because each `begin` writes a ceremony row for a
caller with no session. A timer removes the expired rows, so the rate of new rows sets
the size of the table.

Applies to: `server/internal/api/accountlimits.go` (`limited`),
`server/internal/api/api.go` (`Server.PasskeyPerIP`, `Server.PasskeyGlobal`),
`server/internal/api/passkey.go` (`passkeyLimited`, `passkeyLimitedSession`).

## Rate limit budgets follow the legitimate traffic

- The registration budget of a writer is always larger than the challenge budget. A
  correct client spends one challenge for each registration, and it can send a
  registration again after a transport failure. With a smaller registration budget, a
  client with a valid challenge is refused.
- `AccountPerUser` is one budget for the deletion challenge and for the deletion
  attempt. They are the two parts of one flow. With two budgets, a caller who can get
  nonces without limit can make attempts without limit.
- The passkey budget (12 each minute, burst 12) is looser than the challenge budgets
  (1 each minute). A person who dismisses the system prompt and tries again is not an
  attack. The burst lets a person cancel the prompt three times.

Applies to: `server/internal/api/api.go` (`registerRate`, `registerBurst`,
`Server.AccountPerUser`), `server/internal/api/passkey.go` (`passkeyPerIPRate`,
`passkeyPerIPBurst`).

## The size limits agree with the blob cap

- `maxUploadBytes` (12 MiB) must hold a batch of `maxUploadBlobs` (8, spec 01 §6.8)
  blobs at the blob cap of 1 MiB: 8 blobs in base64 are about 11.2 MB, plus the JSON.
  `TestUploadSizeCapsAgree` examines this. If one of the three values changes alone, a
  correct batch gets a 413.
- `pullByteBudget` (4 MiB) limits the bytes of one pull page. The row limit is not
  sufficient, because one row can be 1 MiB. With 4 MiB, one response uses about 15 MB of
  memory at its peak (the raw bytes, the base64 and the JSON).
- The burst of the upload byte budget (64 MiB) must be larger than the largest upload
  (8 MiB). If it is not, a correct upload can never be paid, at any refill rate. The
  sustained rate is 256 MiB each day.
  `TestTheUploadByteBudgetIsSizedAgainstTheLargestUpload` examines the two values.

Applies to: `server/internal/api/api.go` (`maxUploadBytes`, `pullByteBudget`,
`syncByteBurst`, `syncByteRate`), `server/internal/api/guards_test.go`.

## A route that cannot work is not mounted

- With no relying party (`auth.rp_id`), the passkey routes are not mounted. Such a
  deployment cannot do a ceremony. A sign-in route that can only answer 500 is a route
  that a client tries again without end; a 404 stops the client.
- With no server key files (spec 01 §4.11), the account routes (signup, passwords,
  recovery, resets, email change, freeze) are not mounted.
- `/api/v1/meta` gives `gmail_watch_topic` only when the Pub/Sub hook is mounted. The
  topic comes from the configuration of the hook itself. With no topic, the app does not
  call `users.watch`, so it never makes a watch that this server cannot relay. The
  mailbox link can be mounted with or without the hook.
- `/api/v1/meta` gives the two Outlook URLs together or not at all, and only when the
  Graph hooks are mounted. With no URLs, the app makes no subscription.

Do not offer a topic or a URL from a different configuration value. The app then makes
a watch or a subscription, and its notices go nowhere.

Applies to: `server/internal/api/api.go` (`Server.Passkeys`, `Server.Accounts`,
`mountPasskeys`), `server/internal/api/meta.go` (`MetaResponse`, `handleMeta`).

## A rise of the log generation means a restore

`log_generation` in `/api/v1/meta` is the integer in `HASALA_LOG_GENERATION_FILE` (spec
02 §15.5). It is 1 or more; with no file it is 1. The operator increases it after a
restore from a backup (`docs/runbooks/restore.md`). A device that sees a larger value
knows that the server was restored, and it says so. Without this value, the device sees
a log that went backward and reports that somebody changed the log.

Do not decrease the value, and do not use it for a different purpose.

Applies to: `server/internal/api/meta.go` (`MetaResponse.LogGeneration`, `Meta`).

## An unrouted path answers 404 JSON

A path with no route gets a 404 with the JSON error body. This process serves no web
content on any name (spec 02 §2.1), thus `/` is also a 404. Do not add a fallback that
serves a page.

One known limit is accepted. `http.ServeMux` cleans a path before it finds the route.
For a path that needs this (for example `/api/v1/../v1/sync`), `net/http` itself answers
301. This is harmless, because the target is the correct route.

Applies to: `server/internal/api/api.go` (`Handler`).

## Each response is no-store, and the process sets no HSTS

The JSON writer sets `Cache-Control: no-store` on each response. Each response of this
API is a credential (a ceremony returns a session token) or the person's own encrypted
history. Neither must go into a shared cache, an intermediary or a disk cache of a
client. The header is set in the one writer, not in each handler, so a new handler
cannot be without it. For the health answer it has one more purpose: a cached 200 shows
the state of the past.

The process sets no HSTS header. Cloudflare's edge sets it, and the `.app` domain is on
the HSTS preload list. `hasalad` listens only on loopback and has no TLS code.

Only the website routes of spec 07 have CORS, with their own origin rule. No other
route sends a CORS header.

Applies to: `server/internal/api/api.go` (`writeJSON`, `securityHeaders`).

## Suspension and the fuse are checked in one place, and reads stay open

Suspension and the headroom fuse are admission checks for an account or for the box,
not for one endpoint. They are P3 and P4 of the account isolation design
(2026-08-09, ledgerd design archive). Its rule: admission must fail closed in one
place, not in each endpoint, because a check in an endpoint is the check that the next
feature does not have. Thus suspension is in the session gate, which each route with a
session uses, and the fuse is a middleware around the whole router.

The two checks do not stop a GET or a HEAD. This is the purpose, not a weakness.

- The devices of a suspended account continue to pull their own history. If a
  suspension also emptied the app, the person cannot tell it from a deletion. The
  operator must be able to lift a suspension before the person decides that the data is
  gone.
- A box with a full disk continues to serve what it has. A read uses no durable bytes.
  A refused read makes a storage emergency a full outage for people who did not cause
  it.

HEAD counts as a read: it is a GET with no body, and `net/http` answers it from the GET
handler.

If the status row of an account cannot be read, the answer is a 500, not "not
suspended". A status that cannot be read does not show a permission.

Applies to: `server/internal/api/guards.go` (`isRead`, `accountStatus`,
`headroomGate`), `server/internal/api/api.go` (`sessionGate`).

## The headroom fuse wraps the whole router

While the fuse is tripped, each request that is not a read gets a 503. The gate is
around the whole router, not in the session gate, because the writes that must stop
include the writes with no session. A sign-in writes a session row. Thus nobody can
sign in while the fuse is tripped. This is deliberate. Do not add an exception for
sign-in: exceptions grow one endpoint at a time until the fuse protects nothing.

- The answer is 503 with `Retry-After`, not 429 or 507. The condition is temporary, and
  it is the state of the server, not a fault of the caller. The client must try again
  and must not treat its outbox as refused. Nothing is lost, because the device keeps
  each op that it could not upload.
- `Retry-After` is 60 seconds. This is long enough that many clients that try again do
  not become a load, and short enough that writes start again soon after the operator
  frees space.
- The mail hooks (`/hooks/gmail/pubsub` and the two Outlook hooks) are exempt (spec 02
  §13.4). Each writes at most one row for each link in an hour, and writes no row while
  the fuse is tripped. A 503 only makes Pub/Sub or Graph send the notice again.
- `Fuse.Tripped` runs on each request that is not a read. It must be fast and must not
  block. The real fuse reads a flag that a timer sets.
- With no fuse (`Server.Headroom` is nil), there is no gate.

Applies to: `server/internal/api/guards.go` (`Fuse`, `headroomGate`, `fuseExempt`),
`server/internal/api/api.go` (`Handler`).

## Suspension stops writes and keeps sign-in, sign-out and deletion

A suspended account (spec 02 §9.6) is refused on each method that is not a read, with
`403 account_suspended`. The code is not the general `forbidden`, because the app shows
a different thing for it: "your account is paused", not an error that looks like a bug.
The app must not sign out or delete local data on it.

These stay open for a suspended account:

- Reads, as "Suspension and the fuse are checked in one place, and reads stay open"
  says.
- Sign-in. It is outside the session gate. A device needs a session to pull, and the
  purpose of open reads is that a device can read.
- Sign-out (spec 02 §9.3). A pause by the operator must not keep a session alive on a
  lost phone.
- Account deletion, its challenge and its step-up (AT-DEL-3). A pause must not stop a
  person who wants to leave.

When the operator lifts the suspension, writes work again with the same session token.
The person must not need to sign in again, because that is not always possible. A
suspension that cannot be lifted is not better than the purge that it replaces.

Applies to: `server/internal/api/api.go` (`sessionGate`, `requireSessionSuspendedOK`,
`requireSessionForStepUpBegin`), `server/internal/api/guards.go`
(`writeAccountSuspended`), `server/internal/api/guards_test.go`.

## healthz pings the database and answers two words

`GET /api/v1/healthz` answers the question "can this process serve requests?".

- It pings the database. A process with no database connection still accepts TCP
  connections and finds routes, and then each request fails with a 500. A health check
  that only shows that the router is mounted says "healthy" during a full database
  outage.
- The ping has a 2 second timeout. This is short deliberately. With the connect timeout
  of the pool, one sick database makes a queue of stalled health requests. Each caller
  (a load balancer, a deploy script, a readiness loop) prefers a fast "not yet".
- A failed ping is a 503, not a 200 with a "degraded" field. A load balancer reads the
  status line and not the body.
- It needs no session and is always mounted. A caller that needs a credential to ask if
  the service is up cannot be a load balancer.
- The body is two words from closed sets (`status`, `db`). All people who can reach the
  port can read it. Thus it has no build version (it shows which vulnerabilities
  apply), no host name or DSN (they describe the deployment) and no count of users or
  rows (a business figure). Detail belongs in the operator console. Do not add a field.

Applies to: `server/internal/api/health.go` (`healthzTimeout`, `healthBody`,
`handleHealthz`).

## The per-IP limiter key trusts Cf-Connecting-Ip only from loopback

The rate-limit key of a caller with no session is its client IP (spec 02 §16.1).

Behind `cloudflared`, each request comes from loopback. With the peer address alone,
each per-IP limiter is one limit for the whole internet. Thus, with
`server.trusted_proxy = cloudflare`, a request from a loopback peer gets its key from
`Cf-Connecting-Ip`. An IPv6 client gets its /64 as the key (D-8), because one host owns
a /64 and can change its address inside it to pass the limiter.

The header is trusted only from a loopback peer. A peer that is not loopback gets its
own address as the key, whatever headers it sends. The configuration refuses an
`http_listen` that is not loopback. Thus a header from the open network never comes
with a loopback peer.

The server reads no other forwarded header (`X-Forwarded-For`, `True-Client-IP`,
`Forwarded`). Fence 3 of spec 02 §4.4 (`server/cmd/hasalad/fence_test.go`) refuses
`x-forwarded-for` and `true-client-ip` in the server code. If the server trusts such a
header, a caller sets its own key and the per-IP limits stop nothing.

Applies to: `server/internal/api/clientip.go` (`ClientKeyFor`, `withClientKey`).

## Only GET /account reads the review flag

In package `api`, only `account.go` reads the review flag of an account (spec 02
fence 6). `GET /api/v1/account` reports it, and no other route uses it. The server has
no review bypass: a review account goes through the same sign-in, step-up and limits
as each other account. `server/cmd/hasalad/fence_test.go` fails when a different file
reads the flag. Do not make a route behave differently for a review account.

Applies to: `server/internal/api/account.go` (`AccountResponse`).

## The server holds key material that it cannot open

The server stores only opaque key material (spec 02 #17, #18; spec 01 §4–§5, §10.3):
the AMK commitment, the authority public key and the recovery public key, the 127-byte
recovery wrap and the 45-byte phrase box. The commitment and the public keys are
published so that each device can examine what it unwrapped. The server has no key
that opens the wrap or the box.

- Keys come only through the bootstrap, signed by the authority key that the ceremony
  of account creation bound. There is no route that sets keys a second time
  (spec 02 §2.4).
- `GET /api/v1/keys` never returns the phrase box. Only the `phrase.view` step-up
  returns it. Do not add the box to a different answer.
- The server computes nothing over the key-history log (spec 02 #27). Each entry has
  its nonce and its signature, and the device verifies the log itself (spec 01 §10.13):
  a registration under the authority key that the device derived from its own unwrapped
  seed, and a revocation under a writer that was live at that point. Do not make the
  device trust a result that the server computed.

Applies to: `server/internal/api/keys.go` (`KeysResponse`, `handleBootstrap`),
`server/internal/api/keyhistory.go` (`handleKeyHistory`).

## A PRF wrap needs a step-up by its own credential and a device signature

A PRF wrap (spec 02 #19–#21, §10.5; spec 01 §5.3, §10.7) is the 65-byte body of the
recovery wrap, sealed under a key from the PRF output of one passkey. With it, Face ID
opens the account's data and the person does not type 12 words.

- A wrap is exactly 127 bytes with the header `01 02` (spec 01 §5.1). Its AD binds it to
  the account and the credential, so it cannot be replayed into a different account or
  under the row of a different credential.
- A put needs the step-up `keys.wrap.put` with a passkey proof by that same credential
  (its PRF output made the wrap). It also needs the signature of the session writer's
  DWK over `WrapPutMessage`. Thus a TLS terminator that replaces the wrap with garbage
  has no DWK to sign it (N-11). Do not remove one of the two proofs.
- A delete needs the step-up `keys.wrap.delete`. The loss of a wrap costs nothing,
  because the phrase still opens the account.

Applies to: `server/internal/api/keywraps.go`.

## The passkey routes pass WebAuthn data unchanged and give one refusal

- `options` in a begin answer is go-webauthn's own `CredentialCreation` or
  `CredentialAssertion`, marshalled as it is. The platform API uses exactly this shape.
  A second encoder here must then agree with a specification that neither side owns.
- `credential` in a finish request is the raw `PublicKeyCredential` JSON. The handler
  gives it to go-webauthn's parser and does not decode it. Thus this package never has
  to agree with the library on the shape of an attestation object. Such a disagreement
  can make a verifier accept something that it must refuse.
- A rejected ceremony never says why. Package `auth` has a different error for an
  expired ceremony, a replay, an unknown credential and a cloned authenticator. Each is
  useful in the log, and each is an oracle in a response.
- `403 not_invited` is a separate answer. It is a fact about the policy of the
  deployment, not about the credential, and the person who holds the phone needs it.
- Each passkey route has a rate limit, as "A limiter runs before authentication and
  before database work" says.

Applies to: `server/internal/api/passkey.go` (`PasskeyBeginResponse`,
`PasskeyFinishRequest`, `writeBegin`).

## Request parsing is strict

- A JSON body has a hard byte cap, and an unknown field is a 400. Thus an error in a
  client is a loud failure, not a value that the server ignores. One result: a build of
  the app that sends a new field needs a server that knows the field. Deploy the server
  first.
- A body has exactly one JSON value. Bytes after it show that the client and the server
  do not agree on what was sent.
- A negative `after` cursor is refused, not changed to 0. It shows that the cursor
  arithmetic of the client is wrong, and a silent repair hides that.
- A `limit` above the maximum gets the maximum, not an error. The answer has
  `complete`, so the client gets a correct answer in more pages.
- `POST /api/v1/auth/passkey/login/begin` reads no body. A discoverable login sends
  nothing. A client that posts `{}` and a client that posts nothing are both correct,
  thus a body is ignored and not refused.

Applies to: `server/internal/api/api.go` (`decodeBody`, `parseCursor`, `parseLimit`),
`server/internal/api/passkey.go` (`handlePasskeyLoginBegin`).
