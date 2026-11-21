# Server auth (accounts, codes, freeze, invites, passkeys): decisions from the code (2026-11-21)

These decisions were code comments under `server/internal/auth` (the files from
`accountkeys.go` to `passkey_guarded_test.go`). Code comments are not permitted
(`scripts/comment-lint.ts`), thus the decisions are here.

## Account keys are opaque to the server, and bootstrap has two paths

The server stores the account's key material as opaque bytes (spec 01 §4–§5, §10.3,
§10.7; spec 02 §10.1, §10.5). It checks lengths and header bytes. It builds the canonical
BootstrapPayload v1 again from the fields of the request and verifies the signatures of
the account authority key (AAK) over it. It never opens a wrap or the phrase box, and it
holds no key that could (spec 02 §4.4 fence 3). `GET /api/v1/keys` never returns the
phrase box. The box leaves the server only through the phrase view, under its step-up.

Two paths can bootstrap an account:

- The key that the account-creating passkey ceremony bound. When the posted
  `authority_pubkey` is `users.authority_pubkey_pending`, no step-up is necessary. But
  `auth_kind` must be `0x01` and `auth_hash` must be the `attestation_sha256` of the
  creating credential (R-01). Thus a TLS terminator that changed the credential fails
  here, and the failure is visible.
- Any other key needs the step-up `keys.bootstrap` with T = (`authority_pubkey`), and
  `auth_kind` `0x00` with `auth_hash` = 0^32 (the interrupted-onboarding path, spec 01
  §10.3).

`auth_kind` `0x02` exists only in the password signup. The bootstrap route refuses it.

The bootstrap also binds the address: the posted email hash must agree with the address
of the account. A terminator that changed the address at signup fails here. An account
with no address cannot bootstrap.

The writer nonce is spent before the signatures are verified. A failed attempt thus
cannot try again with the same nonce. Do not move the verification before the spend.

The bootstrap registers the first writer under the same nonce. The `key_history` row
holds an AAK RegistrationMessage, never the bootstrap signature. No device could verify
the bootstrap signature as a registration.

The pending key and the attestation hash are read before the transaction starts. Thus
the statement that clears the pending key compares that same key again and must change
one row. Without this check, two concurrent bootstraps could both pass on one pending
key.

Applies to: `server/internal/auth/accountkeys.go` (`AccountKeys.Bootstrap`,
`bootstrapTx`, `Keys`).

## Email codes: only a MAC is stored, and a code is never the only factor

An email code has six digits, lives ten minutes and has five tries (spec 01 §10.14, spec
02 §10.11). A MAC binds it to its purpose, its id and the tag of the address.

- The server stores only `HMAC(K_code, …)`. `K_code` is not in the database. A code is
  never logged and never in a URL. It stays in memory from the transaction that mints it
  until the mailer gets it, after the commit.
- A code never authorizes an action alone. Each route that consumes a code also needs a
  strong factor. The two exceptions are `signup/verify` and `email/verify/finish`.
- Each code failure gets the one answer `403 code_rejected`: wrong, expired, used,
  burned, never sent, or for another purpose, ceremony or address. A different answer
  for each case is an oracle.
- A row with `Send = false` exists only to keep the answer the same. It sends nothing and
  can never verify.
- A send counts against the pause and the hourly count of the address. The step-up codes
  of the password reset (C8) are the exception: their budget is for each account.
- Each check takes one of the five attempts of the code before it compares the guess, in
  its own transaction. Thus concurrent guesses cannot share one attempt. If the compare
  came first, parallel requests could make more than five guesses.
- A wrong guess is recorded in a transaction of its own, after the transaction of the
  consuming route rolled back. If it were recorded in the route's transaction, the
  rollback would remove the count.

Applies to: `server/internal/auth/codes.go` (`ErrCodeRejected`, `IssuedCode`,
`issueCodeTx`, `codeFailure`, `limitCodeVerify`, `verifyCodeTx`).

## An answer does not show if an account, a ceremony or a writer exists

The auth routes give the same answer to a caller who has no credential, whatever the
state behind the request. A different answer lets a caller list accounts, writers or
ceremonies.

- A rate limit (`429 rate_limited`) never depends on the existence of an account.
- `email/change/begin` (#60) answers the same if the new address is in use or not.
- The freeze link (#64) answers an invalid, used or expired token as it answers a
  freeze. Such a token changes nothing and wakes no device.
- The device-freeze challenge (#77) gives a nonce for each well-formed writer id and
  does no account lookup. Thus the answer says nothing about writers.
- All passkey rejections wrap `ErrPasskeyRejected`, and the HTTP layer must answer all of
  them with the same 401. The one exception in the auth surface is `not_invited`.
- `ErrCeremonyUnknown` is one error for four cases: the ceremony never existed, is spent,
  is expired, or was begun as a different kind.

Do not add an error code or a detail that tells these cases apart.

Applies to: `server/internal/auth/codes.go` (`ErrRateLimited`),
`server/internal/auth/emailchange.go` (`EmailChangeBegun`),
`server/internal/auth/freeze.go` (`FreezeByLink`, `DeviceFreezeChallenge`),
`server/internal/auth/passkey.go` (`ErrPasskeyRejected`, `ErrCeremonyUnknown`).

## A deleted account's sessions answer 410 from a tombstone

An account deletion is one `DELETE FROM users`, and `sessions.user_id` cascades from
`users`. Thus the state "the session resolves but the user row is missing" cannot occur,
and a check for it tests nothing. The deletion writes a tombstone for each live session
instead (`deleted_account_sessions`), and a token with a tombstone answers
`410 account_deleted`.

- The device wipes its local data only on `410 account_deleted`. An expired session must
  stay a 401. Expiry is the usual case, and a wipe on it destroys data.
- A token that was never issued must not answer as a deleted account. That answer would
  tell an unauthenticated caller that a guessed token existed.
- A tombstone answers only until its session would have expired. After that, "expired" is
  true and sufficient.
- `ErrSessionAccountDeleted` wraps `ErrSessionInvalid`, so a caller that knows only the
  general error still rejects the token.
- A tombstone holds nothing that identifies the person: no user id, no subject hash and
  no address. It holds the token hash and the expiry.

Applies to: `server/internal/auth/session.go` (`deletedOrUnknown`,
`ErrSessionAccountDeleted`), `server/internal/auth/deleted_account_test.go`.

## One clock decides session, tombstone and ceremony times

The clock of the Go process (`Sessions.Now`, `Passkeys.Now`) decides when a session or a
ceremony starts and when it ends. The same clock decides if a tombstone still answers and
when it is reaped. The clock of Postgres (`now()`) must not decide one of these facts.
Two clocks that decide one fact are the defect.

The reason is clock skew. `hasalad` and Postgres are on one host today, but that is a
property of the deployment, not of the system. A second host, a VM resume or an NTP
correction ends it. With a Go clock behind Postgres:

- a delete trigger that keeps only rows with `expires_at > now()` writes no tombstone,
  and each 410 becomes a 401;
- a sweep on `now()` in the delete trigger removes the tombstone that the same trigger
  wrote, and the tombstones of other accounts.

A device that gets 401 for a deleted account does not wipe, because it wipes only on
`410 account_deleted`. Thus an early removal is the dangerous direction.

The sweep is not in the trigger. `ReapDeletedAccountTombstones` runs in Go and removes a
tombstone only when its session expired more than `tombstoneGrace` (30 days) before the
time of the Sessions clock.

The tests of this rule use a clock at a fixed distance from wall time (a duration), not a
pinned date. A pinned date disagrees with Postgres only until the calendar passes it, and
then the test proves nothing. Each test also asserts its premise (what Postgres's clock
would do) and does not skip when the premise is false.

Applies to: `server/internal/auth/session.go` (`Sessions`,
`ReapDeletedAccountTombstones`), `server/internal/auth/passkey.go` (`Passkeys.Now`),
`server/internal/auth/deleted_account_test.go` (`newSkewedClock`).

## Display names: folded white space, no other repair, no name in an error

`DisplayName` is the rule of spec 02 §10.7.4. It is the only writer of
`users.display_name` and `signup_ceremonies.display_name`. It folds each run of Unicode
white space into one U+0020 and trims the two ends. It makes no other repair: a name that
breaks a rule is refused, not changed.

Each accepted name also passes `name_ok` of spec 01 §4.11 (the floor). The function
checks `name_ok` last, as a tripwire for a mistake in the narrower rule.

The server does no Unicode normalization. Fence 1 keeps `golang.org/x/text` out of the
server build, and the device sends NFC. Do not add normalization here.

A refusal (`400 bad_name`) names the rule that failed (length or characters), never the
name. The name is personal data and must not go into an error detail or a log.

Applies to: `server/internal/auth/displayname.go` (`DisplayName`, `ErrBadName`).

## Email change proves both addresses and re-salts the password verifier

An email change (spec 02 §10.12, spec 01 §10.17; routes #60–#63) needs a step-up, a code
to the new address, and a proof for the old address. The proof is a code to the old
address or, when the old mailbox is lost, the signature of the recovery key over
`EmailChangeMessage`. Exactly one of the two is permitted.

The verifier of a password account is salted again for the new address, because `s_srv`
is a function of the address. The client sends the new verifier with the begin request.
Without it, the password does not sign in after the change.

Applies to: `server/internal/auth/emailchange.go` (`EmailChangeBegin`,
`EmailChangeFinish`).

## PBKDF2 runs before the transaction and before a ceremony is spent

The server's PBKDF2 goes through a gate with a limited number of slots (spec 02 §16.2). A
busy gate answers `503 unavailable`.

- The PBKDF2 of a new verifier runs before the transaction of the step-up starts. Thus no
  database connection is held while a request waits at the gate. `SetPassword` and
  `EmailChangeBegin` follow this order.
- The gate comes before the ceremony or the code is claimed (spec 02 §10.8 steps 4 and
  5). Thus a 503 leaves a password signup, a password-login ceremony and a verified
  recovery ceremony usable, and the retry succeeds with the same code.

If the claim came first, a busy server would spend the person's code or ceremony for
nothing.

Applies to: `server/internal/auth/emailchange.go` (`EmailChangeBegin`),
`server/internal/auth/gate_busy_test.go`.

## Freeze removes access, and only an older factor lifts it

A freeze (spec 02 §9.8, §10.13; spec 01 §10.18) only removes access. It revokes each
session. Later sign-ins get restricted sessions until a full sign-in proves a factor that
is older than the event that caused the freeze. A factor that the event made (a new
password, a new writer, a new passkey) cannot lift the freeze, because an intruder holds
it.

There are four ways to freeze:

- the freeze link (#64) in a new-sign-in alert or a recovery-used alert, dated to that
  event;
- the lockdown in the app (#65), with step-up `account.freeze`, dated now;
- the device freeze (#77, #78, D42): an enrolled iPhone with no session signs
  `DeviceFreezeMessage` with its DAK. The freeze is dated back to the time when
  something else signed that iPhone out, at most seven days;
- the operator (`OperatorFreeze`).

An operator freeze has priority over a holder's freeze. Only the operator lifts an
operator freeze (review 2 F-03). A holder's freeze on an operator-frozen account is kept
in `holder_also_froze`. The console's unfreeze (C37, `ScopeOperatorOnly`) lifts only the
operator's part and gives such an account back to the holder. It never lifts a holder's
freeze. Only the CLI `account unfreeze` lifts any freeze, after the out-of-band check.

The console and the CLI hold no APNs key. Thus an operator freeze wakes no device: the
devices learn of the freeze at their next request (401), and the alert email goes out.
The owner accepted this.

Applies to: `server/internal/auth/freeze.go` (`freezeTx`, `Unfreeze`, `DeviceFreeze`,
`OperatorFreeze`, `OperatorUnfreeze`, `UnfreezeScope`).

## Invites gate account creation only

An invite (spec 07 §2.5, §4.4; spec 02 §14.1) gates the creation of a `users` row and
nothing else. An account that exists signs in with no code. `internal/invites` owns the
state machine. The auth package checks the invite at `signup/begin` and redeems it in the
account-creation transaction, bound to the address of the signup. The join hook of the
waitlist (`waitlist.OnInviteRedeemedTx`) runs in the same transaction.

`403 not_invited` is the one refusal in the auth surface that a caller can tell apart. It
is a fact about the policy of the deployment, not about a credential. It covers an
unknown, spent, revoked or expired code, and an addressed invite used with another
address. Do not add a second distinguishable refusal.

Applies to: `server/internal/auth/invite.go` (`ErrNotInvited`),
`server/internal/auth/signup.go`.

## Invite codes carry 120 bits from crypto/rand

An invite code is 15 bytes from `crypto/rand`, written as 24 characters of RFC 4648
base32. `403 not_invited` is a perfect oracle: each attempt tells a guesser if the code
exists. Thus the entropy of the code is the only barrier between the beta and open
sign-up.

The tests examine this property in two ways, and the two are necessary:

- A statistical test mints codes through `MintInvite` (the production entry point). It
  examines the length, that each byte position varies, and that no two codes are near
  each other. A test for distinct codes alone passes a counter, and a counter is fully
  predictable.
- A test of the syntax tree of `internal/invites/invites.go` examines that the file
  imports `crypto/rand`, does not import `math/rand` (either version), and calls
  `rand.Read`. A statistical test cannot see a fixed seed: a seeded generator passes each
  statistic and gives the same codes on each deployment.

Do not make the code shorter, and do not change its source. A 2-byte code and a counter
both passed the older tests.

Applies to: `server/internal/invites/invites.go` (`NewCode`),
`server/internal/auth/invite_test.go` (`TestTheInviteCodeSourceIsCryptoRand`,
`TestMintedInviteCodesAreUnguessable`).

## Key history: the device verifies the log

The key-history log is append-only (spec 02 #27). Each entry holds the signature that
authorized it and the nonce of that signature. A device verifies the log itself (spec 01
§10.13) and does not trust the server's account of it. A registration verifies under the
authority key that the device derived from its own unwrapped seed. A revocation verifies
under a writer that was live at that point of the log.

The server returns the log and computes nothing over it. Do not add a server-side
summary or a "valid" flag: a device that trusts it loses the protection.

The log is returned in ascending id, so the last element is the head. A device compares
the head, and a log with entries removed from the end has a different head. Do not change
the order.

Applies to: `server/internal/auth/keyhistory.go` (`Writers.KeyHistory`,
`KeyHistoryEntry`).

## Auth mail: codes go after the commit, alerts go in the transaction

The emails of the auth package reach the outbox in two ways (spec 02 §14.4, D-12):

- A code, and the "already has an account" notice, is minted in the transaction of the
  request. After the commit it goes to `SendCodes`, and `mailq.SendNow` sends it off the
  request path. Thus the time of the answer never depends on whether an email goes out.
  A send in the request path would show, through its time, if an address has an account.
- An alert is enqueued with `mailq.EnqueueTx` in the transaction of its event, together
  with the `auth_events` row. Thus an action that rolls back sends nothing, and a
  restart loses nothing. The alert renderer mints the freeze token at send time, so no
  token waits in the queue.

Applies to: `server/internal/auth/mailer.go` (`Mailer.SendCodes`, `enqueueAlertTx`,
`recordEventTx`, `renderAlert`).

## Passkeys: what one proves and how it names its account

A passkey proves possession of a key that the authenticator holds, unlocked by its owner
(user verification). It proves nothing about the writer keys. A session, however it was
obtained, never enrols a writer and never changes an authenticator alone (spec 02 §8).

Each account has a user handle (`users.user_handle`): 32 bytes from `crypto/rand`, minted
at signup and stored on each credential of the account. A discoverable credential returns
the handle in each assertion, so sign-in needs no identifier. The handle is the identity.
It is never derived from the display name, and the display name is never read from an
assertion. The handle is all that identifies an account in a ceremony, so it must not be
guessable: 32 bytes, inside the 64-byte limit of WebAuthn.

At sign-in the credential row is found by its credential id, and the handle is a tripwire
that must name the same account.

An added passkey uses the existing handle of the account. A second handle would name a
different account, and the new credential would not sign in to this one. An account with
no handle is refused (`ErrNoPasskeyIdentity`). To give it a handle silently would be
account linking. The existing credentials go to the authenticator as exclusions, so an
enrolled authenticator says so and makes no second row.

The finish of an add ceremony makes two checks, and the two are necessary. The user id
comes from the session of the request and must be the account that the handle of the
ceremony names. Without the session check, a person with a ceremony id could complete the
enrolment of another person. Without the handle check, a session could finish a ceremony
begun for a different account and attach a credential to it. The account is compared with
the column that the ceremony was written with and with the account that the handle
resolves to. A row where the two differ was not written by this code.

Applies to: `server/internal/auth/passkey.go` (`passkeyUser.WebAuthnID`,
`userHandleBytes`, `beginAdd`, `verifyAdd`, `FinishLoginResult`),
`server/internal/auth/passkey_store.go` (`userIDForHandle`).

## Ceremony ids are unguessable and a ceremony lives five minutes

A ceremony id is 32 random bytes. It is not a credential: the challenge in the ceremony
authorizes the action. But it is a handle to server-side state that an unauthenticated
caller can reach, so it must not be sequential or guessable.

A begun ceremony must finish within five minutes (`CeremonyTTL`). This is the same limit
as the writer challenge (`Writers.Challenge`), because it bounds the same thing: the time
that a challenge minted by the server stays usable. Five minutes is sufficient for a
person who must get a security key, and short enough that an abandoned ceremony does not
stay as a row.

Applies to: `server/internal/auth/passkey.go` (`CeremonyTTL`, `ceremonyIDBytes`).

## A signature counter of zero is not a clone

`ErrClonedAuthenticator` means that the signature counter did not increase. By WebAuthn
§6.1.1, that shows that two copies of the private key exist or that the authenticator is
defective. It is not a sign-in.

A counter that stays at zero is a different case. Platform authenticators (iCloud
Keychain is one) report a permanent zero, because the credential is synced and a counter
has no meaning. go-webauthn's `UpdateCounter` excludes this case, and the server does
too. Do not make a zero counter an error: each synced passkey would then fail.

Applies to: `server/internal/auth/passkey.go` (`ErrClonedAuthenticator`).

## go-webauthn does the WebAuthn verification

All the cryptography, all the verification steps of WebAuthn §7 and all the attestation
handling belong to go-webauthn (`Passkeys.WA`), not to this package. This is the code
path where a hand-written mistake is an authentication bypass. Do not replace a library
check with local code.

`NewPasskeys` returns an error when the relying party has no RP id or no origin. It does
not return a `Passkeys` that rejects each request. The origin binds a ceremony to this
site, and with none there is nothing to compare the client data with. When the
configuration has no RP id, the server has no `Passkeys` and does not mount the passkey
routes. A wrong configuration thus fails at startup, not at the first sign-in.

Applies to: `server/internal/auth/passkey.go` (`Passkeys`, `NewPasskeys`),
`server/internal/api/api.go` (`mountPasskeys`).

## Passkey options: discoverable, user verification required, no attestation

- **Resident key: required.** Only a discoverable credential returns the user handle in
  its assertion. Without the handle there is no sign-in without a username.
- **User verification: required**, in each ceremony: registration, login, step-up and
  recovery (spec 01 §10.2, spec 02 §8.1, W15). A step-up claims that the person approved
  this action with Face ID or the passcode. "Preferred" does not prove that.
- **Attestation: none.** The relying party enforces no list of permitted authenticator
  models, so it has no use for a signed statement of the model. A request for one adds an
  identifier that is relevant to privacy to each registration, and a consent prompt.

Applies to: `server/internal/auth/passkey.go` (`NewPasskeys`).

## A passkey shows no personal data

`user.name` and `user.displayName` in each registration are the constant "Hasala", never
the address (spec 02 §10.7.2). These fields go to the authenticator and show in the
passkey sheet of the platform.

The name has no suffix for each account. A short prefix of the user handle after the name
was tried and rejected: the sheet then showed the product name two times with noise after
it. The result is a known limit: two accounts on one device look the same in the passkey
picker. The owner accepted this for the closed beta. Sign-in never depends on this string.

Applies to: `server/internal/auth/passkey.go` (`passkeyUser`, `passkeyUserName`).

## A session alone does not add or remove a passkey

A session does not authorize the add or the removal of a passkey (spec 02 #10, #11, #13,
§10.5; spec 01 §10.7, R-01, D33). With only a session, a thief could enrol a passkey of
their own and then pass each later passkey step-up with it (`keys.bootstrap` on an
account without keys, `writer.revoke`, `keys.wrap.delete`), or remove the passkeys of the
owner. Thus:

- `add/begin` needs a session bound to a writer. It consumes the step-up `passkey.add`,
  T = (), and stores the nonce of that step-up as the `add_nonce` of the ceremony, in the
  transaction of the step-up. An account between `register/finish` and bootstrap has no
  writer, so a session there cannot begin an add.
- `add/finish` verifies the attestation. Then it verifies `dwk_sig`, made with the DWK
  of the session's writer over `PasskeyAddMessage(add_nonce, SHA256(clientDataJSON),
  SHA256(attestationObject), SHA256(prf_wrap) or 0^32)`, built again from the raw posted
  bytes. It stores the credential and its optional PRF wrap in one transaction. A TLS
  terminator that puts in its own credential, or a bad wrap, has no DWK to sign with
  (R-01, N-11).
- `DELETE` consumes the step-up `passkey.delete`, T = (`credential_id`), and removes the
  credential in the transaction of that step-up.

`add/finish` reads the session's writer with `FOR SHARE` and requires it to be live. A
revocation that commits first makes the add fail. A revocation that comes second waits
until the credential is stored. Without the lock, a revoked writer could add a passkey
during its revocation.

A removal that is refused after a good proof (`ErrLastPasskey`, `ErrCredentialUnknown`)
leaves the step-up nonce usable (spec 02 §8.1, AT-SU-8). The refusal rolls the
transaction back, so the person does not need a new step-up for the next attempt.

Applies to: `server/internal/auth/passkey_guarded.go` (`AddBegin`, `AddFinish`,
`DeletePasskey`).

## Lock-then-count transactions pin READ COMMITTED

A transaction that takes a lock and then counts rows (for example, the check for the last
passkey) starts with `READ COMMITTED` set explicitly (`pgtx.BeginReadCommitted`). It does
not use the default isolation level. The default can be set for each database, for each
role and by a pooler.

The count is correct only if a transaction that waited for the lock takes a new snapshot
when the lock is released. Under `REPEATABLE READ` the second transaction still sees the
row that the first one deleted. Then two concurrent removals both see two passkeys and
both succeed, and the account has none.

Applies to: `server/internal/auth/passkey_guarded_test.go` (`deleteCredential`),
`server/internal/auth/stepup.go` (`StepUp.Run`), `server/internal/pgtx`.
