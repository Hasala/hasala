# Passkeys, passwords, sessions and recovery (auth): decisions from the code (2026-11-21)

These decisions were code comments under `server/internal/auth`. Code comments are
not permitted (`scripts/comment-lint.ts`), thus the decisions are here.

## An account keeps a way to sign in when a passkey is removed

The server refuses to remove the last passkey of an account that has no password
(`ErrLastPasskey`, HTTP 409 `last_authenticator`). The recovery phrase opens the data,
but it does not give access. Thus an account with no authenticator is locked out. The
rule is in the server, not in the app or in the API layer: a rule that only a client
keeps is lost when the next client is written.

The count and the delete run in one transaction. That transaction first locks all
credential rows of the account (`FOR UPDATE`). Without the lock, two concurrent
removals on an account with two passkeys each see two rows, each delete one, and the
account has none. With the lock, the second removal waits and then counts again.

The transaction must be READ COMMITTED, and the code sets this level itself
(`pgtx.BeginReadCommitted` in `StepUp.Run`). A database, a role or a pooler can change
`default_transaction_isolation`. Under REPEATABLE READ the removal that waited still
sees the row that the first removal deleted, and the count is wrong again.

The removal runs inside the `passkey.delete` step-up (spec 02 #13, §10.5; spec 01
§10.7), so a stolen session cannot remove the owner's passkeys.

Applies to: `server/internal/auth/passkey_manage.go` (`deleteCredentialTx`,
`ErrLastPasskey`), `server/internal/auth/passkey_guarded.go` (`DeletePasskey`).

## A passkey removal ends the sessions of that passkey and no others

A passkey removal must end the access that the passkey gave. Otherwise "remove my lost
phone" leaves the lost phone signed in. It must not end other access: a person who
retires a phone must stay signed in on the laptop. `sessions.credential_id` records the
passkey that made each session.

The removal revokes these sessions:

- Each session that the removed passkey made. The caller's own session is included. A
  person who removes the passkey of the session in use signs in again with a passkey
  that stays. One always stays for an account with no password, because the last one
  cannot be removed.
- Each session from a passkey ceremony (register, login, recover) that has no recorded
  passkey, except the caller's own session. The server cannot say which passkey made
  such a session, and it can be the lost phone. Thus the server signs it out. The
  caller's own session is the one session that the server has no reason to doubt.

Sessions of the account's other passkeys stay.

Rules that a change must keep:

- The revocation runs before the `DELETE` of the credential row.
  `sessions.credential_id` is `ON DELETE SET NULL`, so the delete erases the record of
  which sessions the passkey made. In the other order, those sessions count as "no
  recorded passkey", the caller's own session is spared, and a session stays live with
  no passkey behind it. `TestRemovingTheCredentialYourOwnSessionUsesSignsYouOut` fails
  on that order.
- The revocation, the push-token delete and the credential delete are in one
  transaction. If the sessions are revoked later, a process stop between the two steps
  leaves the passkey gone and its sessions live.
- One predicate selects the sessions, and the two statements (revoke the sessions,
  delete their push tokens) use it. The push tokens are selected through the sessions
  that registered them. Two predicates that differ a little give a session that is
  revoked while its notifications continue.
- The push-token delete is not limited to sessions that are not revoked yet. The token
  of a session that was revoked before must go too.
- The caller's session is excluded with `IS DISTINCT FROM`, not `<>`. With `<>`, a
  nil hash (no session to spare) makes the comparison NULL and the server revokes no
  session of the second group.

A removal also gives one answer (`ErrCredentialUnknown`) for a credential that does not
exist and for a credential of another account.

Applies to: `server/internal/auth/passkey_manage.go` (`deleteCredentialTx`,
`revokeCredentialSessionsTx`).

## A removed passkey takes its PRF key wrap with it

`account_key_wraps` references `webauthn_credentials` with `ON DELETE CASCADE`
(`00010_keys.sql`). Thus the removal of a passkey deletes its PRF key wrap. This is
intended. Only that authenticator can open the wrap, so a wrap that stays is a row that
nothing can use. The loss costs nothing, because the recovery phrase still opens the
account.

The schema does this, not the Go code. Thus a test asserts it
(`TestDeletingACredentialTakesItsKeyWrapWithIt`). Do not change the foreign key to
`SET NULL` or `RESTRICT`.

Applies to: `server/internal/auth/passkey_manage.go` (`deleteCredentialTx`),
`server/internal/pg/migrations/00010_keys.sql`.

## Only a deleted account answers 410, and session rows stay for it

Each session rejection wraps `ErrSessionInvalid`, and the HTTP layer answers 401 for
all of them except one. `ErrSessionAccountDeleted` answers 410. 410 is the only signal
that tells an iPhone to wipe its local ledger. Do not answer 410 for another reason,
and do not give a deleted account's session a 401.

The 410 comes from a tombstone. A `BEFORE DELETE` trigger on `users` copies the
account's session rows into `deleted_account_sessions`. Thus a session row must stay
until its account is deleted. For this reason `sessions.credential_id` is
`ON DELETE SET NULL`, not `CASCADE`. With a cascade, the removal of a passkey deletes
its session rows. Then the trigger finds no row for that device, the device never gets
410, and it never wipes its ledger. The token also answers "unknown session" and not
"revoked session".

Applies to: `server/internal/auth/session.go` (`ErrSessionInvalid`,
`ErrSessionAccountDeleted`, `Sessions.deletedOrUnknown`),
`server/internal/auth/passkey_manage.go`, `server/internal/pg/migrations/00001_baseline.sql`.

## A ceremony is single use and bound to its kind

A WebAuthn ceremony row gets its kind (register, login or add) when it is made. A
`CHECK` constraint permits only these kinds. The finish step claims the row by id and
by kind. Thus a registration ceremony cannot be used as a login. The kinds carry different
authority (a registration makes an account), and a shared handle lets a caller move
that authority from one to the other.

The claim is one `DELETE ... RETURNING` statement. The delete is the claim. It is not a
cleanup after a read. With a read and then a delete, two concurrent finish requests
both see the row and both use the challenge, which must be usable one time only.

The expiry of the claimed row is compared in Go with the clock of the package, because
`expires_at` was written from that clock (refer to "One clock decides each expiry").
A row that is claimed and found expired stays deleted.

Applies to: `server/internal/auth/passkey_store.go` (`ceremonyKind`, `claimCeremony`).

## A rejection does not say which check failed

A passkey rejection gives one answer for different causes:

- `ErrCeremonyUnknown`: the ceremony is unknown, is spent or was started as another
  kind.
- `ErrPasskeyRejected` or `ErrCredentialUnknown`: the credential does not exist, or it
  belongs to another account.

An answer that separates these causes is an oracle. It tells a caller that a ceremony
id or a credential id exists, and whose it is. The cause goes to the operator log only.
Do not add a different error code or a different message for one of these causes.

Applies to: `server/internal/auth/passkey_store.go` (`claimCeremony`),
`server/internal/auth/reauth.go` (`VerifyAssertionCredentialTx`),
`server/internal/auth/passkey_manage.go` (`deleteCredentialTx`).

## An expiry sweep does not run on a request path

The sweep loop of `hasalad serve` deletes expired ceremonies and old tombstones of
deleted accounts. The finish paths do not. A sweep on a path that a caller with no
session can reach lets that caller make the server write to the database on each
request. Do not move a sweep into a begin or finish handler. The sweep uses the clock
of the package, the same clock that the claim compares with.

Applies to: `server/internal/auth/passkey_store.go` (`ReapExpiredCeremonies`),
`server/internal/auth/session.go` (`ReapDeletedAccountTombstones`),
`server/cmd/hasalad/serve.go`.

## A helper under a transaction uses the connection of that transaction

A helper that reads or writes for a caller that holds a transaction takes a `dbtx`
(a pool or a `pgx.Tx`), and the caller passes its transaction. `StepUp.Run` is such a
caller: it holds the row lock of the step-up nonce while the assertion is verified.

A helper that goes to the pool takes a second connection while the first one waits for
it. Each request then holds one connection and waits for a second. With sufficient
concurrent requests the pool is empty and all of them wait permanently. Do not call
`p.Pool` in a helper that can run under a caller's transaction.

Applies to: `server/internal/auth/passkey_store.go` (`dbtx`, `credentialByID`,
`credentialsForUser`), `server/internal/auth/reauth.go`
(`VerifyAssertionCredentialTx`).

## An account, its first authenticator and its invite redemption commit together

A registration creates the account, stores its first passkey (or its password, keys and
first writer for a password signup), claims the signup and redeems the invite in one
transaction. Thus no account is committed without the authenticator that is its only
way in, and a failure rolls back the redemption of the invite.

Do not divide this into two transactions with a `DELETE FROM users` as compensation.
`invite_codes.redeemed_by` is `ON DELETE SET NULL` and a trigger clears the note. The
compensation leaves the invite marked as redeemed, with no account and no note: the
code is lost and the operator cannot see whose it was.
`TestARegistrationThatFailsAfterTheUpsertDoesNotBurnTheInvite` covers this.

The redemption in that transaction is the gate. The checks before it (at begin, and
before the PBKDF2 of a password signup, spec 02 §10.7.3 step 1) only save work. Two
signups that start on one live invite both pass these checks, and only the redemption
makes sure that one account results. Do not remove the redemption because an earlier
check exists.

Applies to: `server/internal/auth/passkey_store.go` (`insertCredential`),
`server/internal/auth/password.go` (`PasswordSignup`),
`server/internal/auth/signup.go` (`createAccountTx`, `claimSignupTx`).

## A passkey counter never goes back, and the last use always moves

A synced passkey (iCloud Keychain, Google Password Manager) reports a signature counter
of zero permanently, because a counter has no meaning for a credential on many
devices. This is the usual case, not a rare one.

After a good assertion (a sign-in or a step-up) the server writes
`sign_count = GREATEST(sign_count, new)` and sets `last_used_at` in all cases. These
are two different facts:

- The counter must not decrease. The Go check (`CloneWarning`) refuses a clone.
  `GREATEST` also stops two concurrent sign-ins from storing the smaller counter.
- "This passkey was used now" is true for all counters.

Do not replace `GREATEST` with a `WHERE sign_count < new` condition. A counter of zero
never satisfies it, the update changes no row, and `last_used_at` stays NULL for most
people.

Applies to: `server/internal/auth/passkey_store.go` (`touchCredential`),
`server/internal/auth/reauth.go` (`VerifyAssertionCredentialTx`).

## A password gives access only

The server sees only S, the value that the device stretched from the password (spec 01
§4.10, spec 02 §10.15). It stores PBKDF2(HMAC(K_pepper, S), salt, 100000) with a new
16-byte salt each time a password is set. It derives no key from S and wraps nothing
under S (PO B). No password route changes `account_keys`, key wraps or writers.

`password/login/finish` (#47) is the only route that accepts S as the full proof, and
it gives a session only. A session cannot change an authenticator, a key or a mailbox
without a step-up. A device step-up that uses the password must first have a valid
signature of the device key. Do not add a route where S alone opens or changes key
material: a person who learns a password then gets the data, not only access.

Each limiter runs before the PBKDF2, and each PBKDF2 runs through the gate
(`authkeys.Gate`). The PBKDF2 is the expensive step. Without these two rules a flood of
guesses uses all of the CPU.

Applies to: `server/internal/auth/passwords.go`, `server/internal/auth/password.go`.

## An answer does not show that an address has an account

The sign-in, signup and reset routes give the same answer, at the same cost, for an
address with an account and an address without one (spec 02 §9.4, §10.8, E-09).

The shape of the answer:

- `password/login/begin` (#46), `signup/begin` (#43) and `reset/begin` (#49) answer the
  same for each valid address. The signup answer depends only on the invite, the link
  key and the syntax of the address.
- An invite made for one address, used with another address, gives the same
  `ErrNotInvited` as an unknown code. The answer does not say whom an invite was for.
  Only the link key proves the address.
- An address that is in use gives the uniform `code_rejected`. The one exception is a
  signup whose address was proven by the invite link: it gets 409 `email_in_use`,
  because only the holder of that link can learn it.

The cost of the answer:

- A password sign-in runs one PBKDF2 on each path. With no account, no password or a
  paused attempt it hashes with a fixed dummy salt, and a wrong-size input still gets
  one PBKDF2 that cannot match.
- The device binding of a sign-in is verified one time on each path. For an unknown
  writer or an address with no account, the signature is verified against a fixed dummy
  key and fails.
- The account row, the writer row and the failure counter are read or updated with the
  same statements when the account does not exist (the nil id matches no row).

Do not remove a dummy hash, a dummy verification or a statement against no row because
it "does nothing". The time of the answer then tells a caller which addresses have an
account.

Applies to: `server/internal/auth/password.go` (`dummyBindKey`, `checkBinding`,
`PasswordLoginBegin`, `PasswordLoginFinish`), `server/internal/auth/passwords.go`
(`dummySalt`, `passwordMatches`), `server/internal/auth/reset.go` (`ResetBegin`),
`server/internal/auth/signup.go` (`SignupBegun`, `SignupBegin`, `addressFree`).

## A password sign-in checks the binding and the limits before the PBKDF2

`PasswordLoginFinish` (#47, spec 02 §10.8) has a fixed order:

1. The device binding. A bad signature answers 400 `bad_signature` before S is
   examined, so this answer tells nothing about the password and costs no PBKDF2.
2. The counters (per address for an unbound attempt, per writer for a bound one).
3. The gate.
4. The ceremony is spent, then the one PBKDF2 runs in the gate slot.

Do not move the PBKDF2 before the counters. A caller can then make the server hash
without limit. Do not move the binding check after the password check. The answer to a
bad binding then depends on the password.

Applies to: `server/internal/auth/password.go` (`PasswordLoginFinish`).

## A busy server or a server fault does not spend a ceremony

A ceremony or a signup is spent by an attempt that the checks refuse, because its nonce
was used. It is not spent when the server cannot do the work:

- Password sign-in: the gate is taken before the ceremony is spent. A busy gate (503)
  spends nothing, and the retry uses the same ceremony.
- Password signup: the claim of the signup is the first statement of the account
  transaction (AT-AUTH-2). A busy gate or a fault in that transaction leaves the signup
  unclaimed.
- Recovery finish: on a busy gate or a server fault, the verified ceremony goes back to
  unclaimed. The retry is then not refused, and the limit of 3 recoveries an hour for
  each IP is not used up by faults of the server.

Do not claim or spend before the gate, and do not keep a claim when the cause of the
failure is the server. A person then must start again (a new email code) because the
server was busy.

Applies to: `server/internal/auth/password.go` (`PasswordLoginFinish`,
`PasswordSignup`), `server/internal/auth/recovery.go` (`RecoverFinish`).

## A revocation deletes the push tokens in its own transaction

When a session or a device is revoked, the same transaction deletes its `apns_tokens`
rows (spec 02 §9.3, F4). A push payload has no content, but its timing shows when the
person spends. A device that the person signed out or removed must not continue to get
wakes.

- The delete and the revocation commit together. A delete in a later step leaves a
  window, and a process stop in that window leaves the tokens permanently.
- `Sessions.Revoke` deletes the tokens also when the session was already revoked. The
  delete does not depend on the result of the `UPDATE`. The failure to prevent is "the
  person thinks it stopped, and it did not".
- "Sign out everywhere" deletes all tokens of the account.

The tests are in `auth`, not in `pushv2`, because `auth` owns the revocation
transactions.

Applies to: `server/internal/auth/session.go` (`forgetPushTokens`, `Sessions.Revoke`,
`Sessions.RevokeAllForUser`, `RevokeOtherSessionsTx`),
`server/internal/auth/passkey_manage.go` (`revokeCredentialSessionsTx`),
`server/internal/auth/push_revocation_test.go`.

## A step-up assertion has no ceremony of its own

A passkey step-up verifies an assertion over a challenge that the server already made
for one action (the step-up's C, spec 02 §8, in `step_up_challenges`). The verification
has no `webauthn_ceremonies` row, no ceremony id and no begin step. The caller gives the
raw challenge and the assertion.

A second row is a second piece of state, with its own expiry and its own sweep. It can
disagree with the step-up row about whether the attempt is still live. For the same
reason `SessionData.Expires` stays zero: only the step-up row decides the time limit.
`StepUp` spends it one time and compares its expiry with one clock.

The assertion proves that an authenticator with an enrolled passkey of this account
signed the bytes of this action, with user verification. It proves nothing about the
writer keys of the account. An action that needs a device (the signature of a deletion,
a revocation) checks that factor itself.

Applies to: `server/internal/auth/reauth.go` (`VerifyAssertion`,
`VerifyAssertionCredentialTx`).

## The checks of a step-up assertion

`VerifyAssertionCredentialTx` makes these checks. Each one is necessary:

1. The challenge is 16 bytes or more. go-webauthn only compares the challenge with the
   value that the client sent back. A short or empty challenge from a caller's mistake
   authorizes an assertion over bytes that the server did not make. The server's nonces
   are 32 bytes.
2. The credential id of the assertion is an enrolled credential. An unknown id is a
   rejection, never a first enrolment.
3. The credential belongs to the account of the session. The assertion itself does not
   name an account. Without this check, one account's passkey passes the step-up of
   another account's session.
4. The account that the user handle of the credential names is the account of its
   foreign key. The two come from different sources, so the check is real. `FinishLogin`
   and `verifyAdd` have the same check.
5. go-webauthn verifies the signature, the challenge, the origin, the RP id hash and the
   user-verification flag. Do not write this verification again in this package. An
   error in it is an authentication bypass.
6. The user-verification flag is checked a second time in this package (spec 02 §8.1).
   go-webauthn checks it only when the session data says "required", so a change of the
   configuration can remove that check with no failure.
7. A counter that did not increase is refused (`ErrClonedAuthenticator`), as in a
   sign-in. A counter that stays at zero is not such a case.

Each rejection wraps `ErrPasskeyRejected`, so the caller answers all of them the same.
A database error or a missing relying party is not a rejection and stays a plain error.
If such a fault is reported as a rejected credential, the person tries to authenticate
again for a cause that is not theirs.

Applies to: `server/internal/auth/reauth.go` (`VerifyAssertion`,
`VerifyAssertionCredentialTx`).

## Access recovery needs the email code and the recovery phrase

Access recovery (C4; spec 02 §10.4, spec 01 §10.9, routes #7, #48, #8) never works with
email alone. The emailed code proves the mailbox. The recovery key, which the phone
derives from the 12 words, signs the raw bytes of the new authenticator. A person who
controls only the mailbox cannot take the account.

The finish is one transaction. It registers the new authenticator with a new writer and
a bound session. It also revokes all other sessions, all other passkeys, the old
password and all open ceremonies of the account. If these steps do not commit together,
an old authenticator can stay valid after a recovery, and the person who made the
recovery necessary keeps access.

Applies to: `server/internal/auth/recovery.go` (`RecoverBegin`, `RecoverVerify`,
`RecoverFinish`).

## A password reset on a new iPhone needs the approval of a signed-in iPhone

A password reset on a new iPhone (C9; spec 02 §10.9, routes #49 to #54; spec 01 §10.16)
has two proofs. The new iPhone proves the address with a `password_reset` code and
posts an ephemeral Ed25519 key. An enrolled iPhone with a bound session then approves
with its device key (DAK) over `ResetApproveMessage`. The new iPhone finishes with the
signature of the ephemeral key over the new S.

Before the approval, the person compares an 80-bit approval code on the two iPhones.
The two iPhones derive the code from the ephemeral key. The server never computes it.
A server or a network that replaces the ephemeral key thus shows as two different
codes. Do not make the server compute or relay the approval code, and do
not let an email code alone reset a password on a new iPhone.

Applies to: `server/internal/auth/reset.go` (`ResetBegin`, `ResetVerify`,
`ResetRequest`, `ResetApprove`, `ResetFinish`).

## One clock decides each expiry

The server writes each expiry time from the clock of the Go package (`Sessions.Now`,
`Passkeys.now`, `Accounts.now`). It also compares each expiry with that clock, in Go or
as a query parameter. It never uses `now()` of Postgres in the comparison.

With two clocks, the minting and the expiry of one session or one ceremony are decided
by clocks that can differ, and tests cannot move the time. Do not write
`expires_at > now()` in a query of this package.

Applies to: `server/internal/auth/session.go` (`Sessions.Now`, `Sessions.Info`,
`Sessions.ReapDeletedAccountTombstones`), `server/internal/auth/passkey_store.go`
(`claimCeremony`, `ReapExpiredCeremonies`).
