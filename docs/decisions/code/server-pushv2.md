# Push wakes (pushv2): decisions from the code (2026-11-21)

These decisions were code comments under `server/internal/pushv2`. Code comments are
not permitted (`scripts/comment-lint.ts`), thus the decisions are here.

## A wake carries no content and does not show its reason

A push payload carries no content: no amount, no merchant, no count, no category. A
notification shows on a lock screen and goes through Apple's push service, outside the
end-to-end encryption of the op log. A count is also data: it shows how often the person
spends.

Each wake sends the same 31-byte body and the same header set, whatever its reason (spec
02 §12.2, §12.5). The reason (mail, sync, security, nudge, account gone) is internal to
the server. It selects only the throttle rules. Nothing on the wire tells a mail wake from
a security wake.

The interfaces keep this rule. A `Notifier` gets a user id and nothing else, and a `Waker`
gets ids, tokens and a reason. Thus no code path can put data into a payload. Do not add a
parameter that carries content to these interfaces, and do not make the body or a header
depend on the reason. A change here sends spending signals to Apple and to a lock screen.

The Expo and Web Push transports of ledgerd are not to come back (spec 02 §2.3). Web Push
carried an SSRF, and the PWA that used it is retired.

Applies to: `server/internal/pushv2/notifier.go` (`Notifier`),
`server/internal/pushv2/wake.go` (`Reason`, `Waker`), `server/internal/pushv2/apns.go`
(`Payload`).

## The provider token is signed through crypto.Signer

The APNs provider token is an ES256 JWT. The server signs it through the `crypto.Signer`
method of the key. It does not call the package functions `ecdsa.Sign` or
`ecdsa.SignASN1`: fence 3(d) of spec 02 §4.4 (`server/cmd/hasalad/fence_test.go`) refuses
these two calls by name in all server code. The signer gives a DER signature, and the code
encodes it again as the raw r ‖ s that JWS needs.

This is the only signature that the server makes with an EC key. It signs the team id and
a time, never user data. Do not add a second EC signature to the server, and do not change
this one to a direct `ecdsa` call. The fence then fails the gate.

Applies to: `server/internal/pushv2/apns.go` (`SignJWT`).

## The provider token lives 20 to 40 minutes

Apple refuses a provider token that is older than one hour. Apple also throttles a team
that makes a new token more often than one time in 20 minutes (spec 02 §12.2). Thus the
client keeps one token for 40 minutes. When Apple calls a token expired, the client makes a
new one only if that token is 20 minutes old or more, and it tries the send again one time.
If the token is younger, the answer is a configuration error and all sends stop for 5
minutes.

A maximum age near one hour causes refused sends. A new token for each send, or for each
refusal, makes Apple throttle the team and no wake goes out.

Applies to: `server/internal/pushv2/apns.go` (`jwtMaxAge`, `jwtRegenerateFrom`,
`providerToken`, `Send`).

## The APNs request has a pinned header set

A wake request has exactly these headers (spec 02 §12.2): `authorization`, `apns-topic`,
`apns-push-type`, `apns-priority`, `apns-expiration`, `content-type` and the
`Content-Length` that Go adds. Nothing else is sent.

Two settings exist only to keep the set pinned:

- `DisableCompression` is true on the transport. Without it, Go adds an `Accept-Encoding`
  header.
- `User-Agent` is set to an explicit empty value. Without it, Go adds its own
  `User-Agent`.

If somebody removes one of these settings, the request gets a header outside the pinned
set and the test `TestPayloadAndHeadersArePinned` fails.

Applies to: `server/internal/pushv2/apns.go` (`NewClient`, `send`).

## The APNs client follows no redirect

APNs never redirects. The client does not follow a redirect, because a followed redirect
sends the provider token (the `authorization` header) to a host that is not Apple's. A
redirect answer is classified as a transient failure. Do not remove `CheckRedirect` from
the client and do not replace the client with one that follows redirects.

Applies to: `server/internal/pushv2/apns.go` (`NewClient`).

## A wake is best effort

A call to a `Waker` never blocks a request. The wake goes into a bounded queue, and a full
queue drops the wake and counts it (spec 02 §12.1). A send that fails with a 5xx, a network
error or an answer that is not expected is not tried again (spec 02 §12.3). The one retry
is for an expired provider token.

The reason is that a wake is only a "something changed" signal. The app catches up when
the person opens it. A wake that blocks, or a retry loop, puts a request path or the queue
behind a slow push service for no gain in correctness. Do not make a caller wait for a
send, and do not make data depend on the delivery of a wake.

Applies to: `server/internal/pushv2/wake.go` (`Waker`, `Dispatcher.enqueue`),
`server/internal/pushv2/apns.go` (`ResultTransient`).

## The throttle state stays in memory

The debounce windows, the hourly caps and the cooldowns of each token are in memory only
(spec 02 §12.4). A restart loses them. The owner accepted this: the worst case is a small
number of extra background pushes, and Apple throttles background pushes on its side.

The state holds at most 10,000 tokens. The token that was used least recently is evicted,
and it loses its trailing wake that was owed. This is accepted for the same reason. Do not
add a table for this state.

Applies to: `server/internal/pushv2/throttle.go` (`throttle`, `throttle.state`).

## A trailing wake checks its token again

A wake that the debounce deferred goes out when its window closes, up to 300 seconds
later. Before the send, the dispatcher reads the database again. The wake goes out only if
the token's row still exists for the account that the wake was owed to, and the session of
that row is live. A token that was revoked, signed out, expired or registered to another
account in that time gets no wake.

Without this check, a device that left an account, or that now belongs to another account,
gets a wake caused by the first account's activity. If the check itself fails, the wake is
dropped. A wake for tokens collected before their rows were deleted has no owner and
passes only the session check.

Applies to: `server/internal/pushv2/wake.go` (`Dispatcher.Flush`,
`Dispatcher.stillRegistered`).
