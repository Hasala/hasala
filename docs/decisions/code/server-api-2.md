# Account, passkey, mailbox and hook routes (api): decisions from the code (2026-11-21)

These decisions were code comments under `server/internal/api`. Code comments are
not permitted (`scripts/comment-lint.ts`), thus the decisions are here.

## The server refuses the removal of the last authenticator

`DELETE /api/v1/auth/passkeys/{credential_id}` (spec 02 #13, §6.3) answers 409
`last_authenticator` when the credential is the last way into the account: the only
passkey of an account that has no password. The check is in `auth`, in the transaction
of the removal, with the account's credential rows locked. The app also disables the
control when one passkey is left, but that is not the guard.

The reason is that the removal of the last authenticator locks the person out, and
nothing can undo it. There is no reset mail, and the recovery phrase opens the data
but does not give access again. A rule that only a client keeps is lost when the next
screen or the next client does not have it. Two removals at the same time must also not leave an
account with no credential, and only the server can see the two.

Do not move this check to the client, and do not remove the row lock.

Applies to: `server/internal/api/passkeymanage.go` (`handleDeletePasskey`),
`server/internal/auth/passkey_manage.go` (`ErrLastPasskey`).

## The passkey list has no key material

`GET /api/v1/auth/passkeys` returns four fields for each credential: `credential_id`,
`created_at`, `last_used_at` and `current`. It never returns a public
key. A client has no use for the key bytes, thus they are only a liability on the
wire.

`auth.Credential` has no public key field. Thus the rule is a property of the type,
not of a column list that somebody can make wider. The test
`TestListPasskeysCarriesFourFieldsAndNoKeyMaterial` searches the response for the
stored key bytes in each encoding that the API uses. Do not add a key field to
`auth.Credential` or to `PasskeySummary`.

Applies to: `server/internal/api/passkeymanage.go` (`PasskeySummary`,
`handleListPasskeys`).

## The `current` passkey is read from the session, never inferred

`current` in the passkey list marks the credential that made the caller's session. The
server reads it from `sessions.credential_id`, which the sign-in ceremony writes when
it makes the session. The marker is a byte comparison with that value.

Do not derive the marker from `last_used_at` or from creation times. A
re-authentication or a later sign-in on a different device changes `last_used_at`, and
the marker then shows the wrong device. A wrong "this device" marker is worse than no
marker, because the person uses it to decide which passkey to remove.

A session with no recorded credential marks nothing: each row has `current: false`.
Such a session is older than the column, or it came from a sign-in that proves no
passkey.

The read of the session's credential is not necessary for the list. If it fails, the
server writes a log line and returns the list with no marker. It does not answer 500,
because the list is correct without the marker.

Applies to: `server/internal/api/passkeymanage.go` (`PasskeySummary.Current`,
`handleListPasskeys`).

## A passkey removal signs out what that passkey signed in

The removal of a passkey revokes the sessions that this credential made. It leaves the
sessions of the account's other credentials signed in. It also revokes each session
that the server cannot attribute to a credential, except the caller's own session. An
unattributed session can be the lost phone, and this is the one case where it is safer
to sign a device out.

A caller who removes the credential of their own session is signed out by that
request. The `current` marker in the list exists so that this is a decision of the
person and not a surprise.

Do not make the removal revoke all sessions: the removal of a lost phone then signs
out the other devices. Do not make it revoke none: the lost phone then stays signed
in. `auth/passkey_manage.go` has the full rule and its order.

Applies to: `server/internal/api/passkeymanage.go` (`handleDeletePasskey`),
`server/internal/auth/passkey_manage.go` (`deleteCredentialTx`).

## One answer where a difference tells a secret

Some routes give the same answer for cases that an attacker wants to tell apart. Keep
the answers the same in status, in body and in shape. Put the real reason only in the
operator log, where the route has one.

- Passkey removal: a credential of a different account and a credential that does not
  exist are both 404 `not_found`. `auth` returns one error for the two.
- Email change begin (#60): the answer is the same when the new address is in use.
- Freeze by link (#64): 204 with an empty body for each token, known or not (D-13).
  Only a live token spends the `freeze-global` budget. A 503 is only for a live token
  that the server could not try, or a lookup that failed.
- Device freeze challenge (#77): the answer is the same for each well-formed writer id.
- Password sign-in begin (#46) and password reset begin (#49): the answer has the same
  shape for each valid address, with or without an account.
- Mailbox link (#35): each ID token failure is 403 `link_rejected` with no detail.
- Sign-out (#15): a session that is revoked, expired or unknown gets the same 401.
- Waitlist submit (spec 07 P1): each valid submission gets the same answer, when the
  address is new, pending, confirmed, invited or already an account. The only
  difference is the email that the worker sends later.

A different status, a different field or a detail text in one of these cases lets a
caller find which addresses have accounts, which tokens are live or which credential
ids exist.

Applies to: `server/internal/api/passkeymanage.go` (`handleDeletePasskey`),
`server/internal/api/routes_email.go` (`EmailChangeBeginResponse`),
`server/internal/api/routes_freeze.go` (`handleFreezeLink`,
`DeviceFreezeChallengeResponse`), `server/internal/api/routes_password.go`
(`PasswordLoginBeginResponse`), `server/internal/api/routes_reset.go`
(`ResetBeginResponse`), `server/internal/api/routes_mailboxlink.go`
(`errLinkRejected`), `server/internal/api/routes_session.go` (`handleLogout`),
`server/internal/api/routes_waitlist.go`.

## A full limiter shares one bucket and does not refuse

`Limiter` is a token bucket for each key. Some keys are client addresses, which an
attacker selects. Thus the map of buckets has a maximum size (`maxKeys`); a map with
no maximum lets an attacker use all the memory.

When the map is full, `AllowN` first removes the buckets that are full of tokens again.
These keys were idle for a sufficient time, and their removal changes no decision. This
is the only removal. Do not remove a bucket that is partly spent: its key then gets a
new burst, and the bounded map becomes a way around the limit.

If the map is still full, a new key uses one shared bucket. The limiter does not
refuse the new key. A refusal lets an attacker with many source addresses fill the map
and lock all real callers out, which changes a nuisance into an outage. Under pressure
the limit becomes less exact, but it stays a limit.

`NewClientLimiter` also holds one IPv6 /48 to 1/64 of the map. When a /48 has used its
share, its other /64 prefixes share one bucket on the /48. Thus one network cannot fill
the map with addresses that cost it nothing.

A rate of zero is permitted. It gives the burst and no refill.

Applies to: `server/internal/api/ratelimit.go` (`Limiter`, `AllowN`, `sweep`,
`NewClientLimiter`).

## A weighted charge is at least 1, and the burst must be larger than the largest charge

`AllowN` takes `n` tokens, all or nothing. It exists for the upload byte budget, which
counts bytes and not requests (refer to "Upload has a request budget for the pool and
a byte budget for storage" in `docs/decisions/code/server-api-3.md`).

Two rules belong to it:

- An `n` below 1 becomes 1. A call that charges nothing is a way to ask the limiter
  for an answer and pay nothing.
- A charge larger than the burst is never admitted. The caller owns this property: the
  burst of the byte budget is several times the largest possible upload. If somebody
  makes that burst smaller than one full upload, a full upload fails permanently.

Applies to: `server/internal/api/ratelimit.go` (`AllowN`), `server/internal/api/api.go`
(`syncByteBurst`).

## Account deletion is in the app and always mounted

`DELETE /api/v1/account` (spec 02 §15, #41) is mounted in each configuration of the
server. App Review guideline 5.1.1(v) requires that an app that makes an account also
lets the person delete it in the app. The privacy page also says that people own their
data, and deletion is the proof. `hasalad purge-user` is only for the operator; a path
that needs the operator is not self-service.

Do not put this route behind a configuration switch. The route also stays open for a
suspended account (spec 02 §9.6).

Applies to: `server/internal/api/routes_account.go` (`mountAccount`,
`handleDeleteAccount`).

## Account deletion needs three factors on one nonce

A deletion is permanent. It needs these three things (spec 02 §15.2):

1. A live session. It says only which account the request is about.
2. An `account.delete` step-up (spec 02 §8) whose parameters name this account: a
   passkey assertion with user verification, or the device key of the session's writer
   with the password (the only factor of a password account).
3. An Ed25519 signature of a live writer of the account over
   `keyproto.DeletionMessage(step-up nonce, user_id)`. The signer can be any live
   writer, not only the writer of the session.

A stolen session has neither of the last two. One nonce serves the proof and the
signature, thus the gesture has one expiry. The signature is checked in the
transaction of the step-up, thus a wrong signature spends the nonce as a wrong proof
does.

Each refusal is the refusal of the step-up: 403 `step_up_required` or
`step_up_failed`. Thus a caller cannot find which factor is absent or wrong.

The step-up commits before the purge starts. The purge deletes by cascade, and its
cascade waits on the nonce row that an open step-up transaction holds. Do not run the
purge in the transaction of the step-up.

Applies to: `server/internal/api/routes_account.go` (`handleDeleteAccount`,
`deleteWithStepUp`).

## A failed purge says that the account is still there

The purge is all or nothing. When it fails, the route answers 500 `deletion_failed`
with a text that says the account was not deleted and nothing was removed. The log
line is loud and names the account.

The worst result of this route is an app that shows "your account is deleted" when the
purge failed. Do not change this answer to a generic 500 with no text, and do not
answer a success code before the purge commits. The text is safe to return: it is
about the caller's own account, and the cause is a fault on the server.

Applies to: `server/internal/api/routes_account.go` (`purgeAccount`).

## A success log line of a deletion names no account

The log line of a completed deletion gives only the number of rows and tables. It has
no user id (spec 02 §20: `user` is in a log line only for a failure on the server).
The account is gone, and the log must not keep its id. Do not add the id to this line.

Applies to: `server/internal/api/routes_account.go` (`purgeAccount`).

## Tokens are read before the rows that hold them go away

Some actions delete the rows that hold the APNs tokens of the devices they must wake:
account deletion, the revocation of a writer, a sign-out of all sessions, and a
security action that signs other sessions out (spec 02 §12.5). After the commit,
nothing can find these tokens.

Thus the server reads the tokens before the delete, in or before the transaction, and
sends the wake after the commit through `wakeTokens`. Do not move the read after the
delete: the wake then goes to nobody, and no error shows it. A device that was signed
out or whose account is gone then does not learn of it until its next request.

A failed read of the tokens costs only the wake. It writes a log line and never fails
the request.

Applies to: `server/internal/api/routes_push.go` (`accountTokens`, `wakeTokens`,
`securityWake`), `server/internal/api/routes_account.go` (`purgeAccount`).

## A mail hook spends a shared budget only for a proved notice

The provider hooks are public. They have three budgets (spec 02 §16.2):

- `hook-ip`: one budget for each caller address, shared by the Gmail hook and the
  Outlook hooks. Each request spends it, the Graph validation handshake included.
- `hook-link`: one budget for each mailbox link. For Gmail the key is the address HMAC
  of the notice. For Outlook the key is the hash of a `clientState` that names a link.
- `hook-global`: one budget for each provider.

Only a request that proved itself spends `hook-global`. For Gmail, that is a request
with a verified Google token of Pub/Sub's service account. For Outlook, that is a
request with a `clientState` that names a link inside its `hook-link` budget. Thus
traffic with no proof cannot delay a real wake.

The Outlook hook reads the route from the database before it spends `hook-link` and
`hook-global`. A made-up `clientState` matches no link and spends neither. If the order
changes, a flood of made-up values empties the global budget, or fills the link
limiter and moves real links into its shared bucket. The route read is bounded by
`hook-ip`, by the 64 KiB body and by the maximum of 100 entries. When `hook-global` is
empty, the `hook-link` tokens of that request go back.

The `hook-link` budget is for each link, thus a watch that an outsider makes on one
mailbox cannot spend the budget of a different holder.

Applies to: `server/internal/api/routes_hooks.go` (`mountHooks`, `handleGmailHook`,
`handleOutlookHook`).

## Mail hooks: what proves a notice, what the answer is, what is never read

Gmail (`POST /hooks/gmail/pubsub`, spec 02 #39, §13.4): Pub/Sub sends the notice with
Google's OIDC token. A notice that routes to a link wakes only the holder device of
that account. Each other notice (a foreign subscription, a malformed body, an unknown
mailbox, a link over its budget) gets 204 and a counter. Pub/Sub sends a notice again
after each answer that is not a success, thus an error status for a notice that can
never route causes retries with no end. A 503 is only for a fault of the server (the
route read failed, or a wake was not queued), where a retry helps.

Outlook (`POST /hooks/outlook/graph` and `/hooks/outlook/graph/lifecycle`): Graph signs
nothing that a public client can verify. The proof of a notification is the
`clientState` that the server made at the link. Graph sends it back in each
notification, and the server routes by its SHA-256.

- The server makes the `clientState`, returns it one time in the link answer and keeps
  only its hash. It is never in a log, never stored and never sent back by a hook.
- `resource` and `resourceData` in a notification name the message. The server never
  decodes them (`internal/outlookpush`), thus a message id cannot get into a log or
  the database.
- A route read that fails part way is a 503, not "no such link". Graph then sends the
  notification again. The answers and the handshake are in
  `docs/decisions/outlook-mailbox.md`.

A change that decodes `resourceData`, or that writes the `clientState` to a log, puts
data about a person's mail on the server. That breaks "the server is blind".

Applies to: `server/internal/api/routes_hooks.go` (`handleGmailHook`,
`handleOutlookHook`), `server/internal/api/routes_mailboxlink.go` (`handleLink`,
`LinkResponse.ClientState`).

## The Outlook hook paths are the same in three places

The paths `/hooks/outlook/graph` and `/hooks/outlook/graph/lifecycle` are constants in
`api` and in `config` (`OutlookNotificationPath`, `OutlookLifecyclePath`), and the
ingress of the tunnel admits exactly these paths
(`infra/qa/cloudflared/config.golden.yml`). `config` refuses a public URL whose path
is different.

When you change a path, change the three places together. If they differ, Graph
cannot reach the hook and Outlook wakes stop, with no error on the server.

Applies to: `server/internal/api/routes_hooks.go` (`outlookHookPath`,
`outlookLifecyclePath`), `server/internal/config/config.go`.

## The server keeps an HMAC for a mailbox link, and an account has one link

A mailbox link (spec 02 #34–#38, §13.2) proves that the device of the session can read
the mailbox. The proof is the provider's ID token with a nonce that the server gave to
this session. The server keeps only an HMAC of the address under the route key (for a
new Outlook link, of the token's `sub`: `docs/decisions/outlook-mailbox.md`) and the id
of the holder writer. The holder is the one device that reads mail and that the hook wakes.
The server never stores the address. The test `TestMailboxLink` searches each text and
bytea column for it.

An account has one link (`mailbox_links_one_per_user`). The insert has its conflict on
the account. Thus a new link replaces the link of each provider, and of two links at
the same time the later one stays. Do not change the conflict target to the account
and the provider: an account then has a Gmail link and an Outlook link, and the routes
#36–#38 and the holder rule work with one link.

Applies to: `server/internal/api/routes_mailboxlink.go` (`handleLink`).

## The mailbox link step-up binds the ID token, not the provider

The parameters hash of the `mailbox.link` step-up is made from the SHA-256 of the ID
token. The provider name is not in it. This is not an omission: the token's hash binds
its issuer, and a token of one provider fails the verifier of the other provider. Thus
a step-up for a Gmail token cannot link an Outlook mailbox.

Applies to: `server/internal/api/routes_mailboxlink.go` (`handleLink`).

## The mailbox link refuses cheap failures before it verifies the ID token

`PUT /api/v1/mailbox/link` (#35) does its cheap checks first. It settles the provider
before all other work, and it refuses a request with no step-up before it verifies the
ID token. The verification of an ID token can need the provider's key set (JWKS), which
is a call to a different host. Thus an unknown provider, or a request with no step-up,
costs no JWKS work and no step-up.

The step-up assertion itself is verified later, in `StepUp.Run`, before the server
writes something. Do not move the ID token verification before these two checks.

Applies to: `server/internal/api/routes_mailboxlink.go` (`handleLink`).

## A link change wakes the other devices so the old holder stops

After a link or an unlink commits, the server sends a security wake to each other
device of the account, the old holder included (spec 02 §12.5, §13.2, AT-GM-9). On
that wake the old holder stops its mail reads, and after an unlink it revokes its own
refresh token.

Do not remove this wake and do not leave the old holder out of it. Without it, the old
holder continues to read mail and keeps a live provider token until it asks the server
for some other reason.

Applies to: `server/internal/api/routes_mailboxlink.go` (`handleLink`, `handleUnlink`).

## Without a provider's push the server records and reports no watch

A server can have the mailbox link with no push for a provider. Then `/meta` offers no
watch topic, the app makes no watch, and nobody relays a wake.

- `PUT /api/v1/mailbox/link/watch` (#36) answers 409 `no_watch_topic` and writes
  nothing. When no provider has a push, this check comes before the body, the writer
  binding and the holder check, on purpose. The answer then depends only on the
  configuration of the server, which `/meta` already makes public. Thus a caller who
  is not the holder learns nothing from it. When one provider has a push, the same
  answer for a link of the other provider comes after the holder check.
- `GET /api/v1/mailbox/link` (#37) reports `watch_expires_at: null`, also when a watch
  was recorded while the push was on. Nobody relays that watch now, and the app takes
  a value in this field for a live watch.

An app that read a topic before the push was turned off gets `no_watch_topic`, stops
its watch, forgets the topic and reads `/meta` again.

Applies to: `server/internal/api/routes_mailboxlink.go` (`handleLinkWatch`,
`handleGetLink`).

## A reported watch expiry cannot be later than the provider permits

`PUT /api/v1/mailbox/link/watch` refuses an expiry that is too far in the future. The
maximum is 8 days for Gmail, because a Gmail `users.watch` lasts 7 days. The maximum
is 7 days for Outlook, because a Graph subscription to messages lasts at most 10,080
minutes (`docs/decisions/outlook-mailbox.md`).

A larger maximum lets a device record an expiry that the provider cannot give. When
you change a maximum, read the provider's limit first.

Applies to: `server/internal/api/routes_mailboxlink.go` (`maxWatchAhead`,
`maxOutlookWatchAhead`).

## The APNs token routes are always mounted

The routes `PUT`, `GET` and `DELETE /api/v1/push/apns` (spec 02 #31–#33, §12) are
mounted when `apns.enabled` is false too. A device registers its token at each start.
When the operator turns sending on, the tokens are already there and the wakes start
at once. If the routes are mounted only with sending on, each device has no token row
until the app runs again.

Applies to: `server/internal/api/routes_push.go` (`mountPush`).

## An APNs token moves to a different account only when its row is dead

A device token has one row (AT-APNS-7), and a writer has one token. The row is bound
to the session that registered it, thus a sign-out of that session silences the
device.

- A token that a different writer of the same account holds moves to the caller.
- A token that a different account holds moves only when that row is dead: its session
  is revoked, expired or idle, or its writer is revoked. A phone that changes accounts
  signs the first account out, and that deletes the row.
- While the row is live, the answer is 409 `token_in_use` and nothing changes.

Do not let a live row move. A person who knows the token of a device can then register
it on their own account, and the device gets no more wakes for its real account.

Applies to: `server/internal/api/routes_push.go` (`handlePutAPNs`).

## Sign-out needs no step-up, no body and no active account

`POST /api/v1/auth/logout` (#15, spec 02 §9.3) must work each time a person wants to
end a session.

- It needs no step-up.
- It works while the account is suspended. A pause by the operator must not take away
  the ability to sign out.
- It accepts no body at all, or the empty object. A client that sends nothing must not
  get "malformed", because it then keeps a session that the person wanted to end.
- It is idempotent. The first call answers 204 and a second call answers 401. The app
  treats the two answers the same. The app calls the route before it deletes its
  Keychain item, and it queues a retry when it is offline.

The route revokes the session on the server and deletes the APNs tokens that the
session registered, in one transaction. A sign-out that leaves the session valid on
the server is not a sign-out (security finding F4).

Applies to: `server/internal/api/routes_session.go` (`mountSession`, `handleLogout`,
`decodeEmptyBody`).

## Sign-out of all sessions keeps the writers

`POST /api/v1/auth/logout-all` (#16) needs a `session.logout_all` step-up. It revokes
each session of the account, the caller's included, and deletes each APNs token, in
one transaction. It does not revoke the writers (spec 02 §9.3). The devices keep their
keys, sign in again and continue to write.

Do not revoke writers here. A revoked writer cannot write again, and each device then
needs a new enrolment after a sign-out that the person made for safety.

Applies to: `server/internal/api/routes_session.go` (`handleLogoutAll`).

## A step-up is bound to the parameters of its action and is spent with the action

`POST /api/v1/auth/step-up/begin` (spec 02 #9, §8.1) gets the action and a
`params_hash` that the client computed for the action it will do. The client also
computes the challenge C itself, and it does not prove a C that differs from the one
in the answer (spec 01 AT-C9).

The guarded route does not trust the hash from the begin call. It computes
`params_hash` again from its own request, and it spends the nonce in the transaction
of the action. Thus a step-up that was made for one action or one target cannot
approve a different one, and a nonce cannot approve an action that did not commit.

Do not let a guarded route accept the hash that the client sent, and do not spend the
nonce outside the transaction of the action.

Applies to: `server/internal/api/routes_stepup.go` (`handleStepUpBegin`), each guarded
route in `server/internal/api`.
