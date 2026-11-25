# iOS app, transaction sheet and Live layer: decisions from the code (2026-11-21)

These decisions were code comments under `ios/Hasala/Features/Transaction/` and
`ios/Hasala/Live/` (`Account/`, `Ledger/`, `Mailbox/`, `Runtime/`). Code comments are
not permitted (`scripts/comment-lint.ts`), thus the decisions are here.

## The split editor shows amounts when Hide amounts is on

The split editor shows the total and the amount of each line, also when the device
setting Hide amounts is on. The person opened the editor to change these amounts.

Do not apply Hide amounts to this page. With hidden amounts the person cannot see what
they type, and cannot see if the lines add up to the total.

Applies to: `ios/Hasala/Features/Transaction/SplitEditorView.swift` (`SplitEditorView`).

## One account for each iPhone

An iPhone holds the data of one account at a time (spec 04 §4.4, §6.5 `foreignData`).
While the iPhone holds the binding of an account, these operations do not continue:

- a signup;
- a sign-in to a different address, or with a passkey of a different account;
- an access recovery for a different account.

The account service tells the gate, the gate shows the "Remove this iPhone's data" wall,
and the screen that asked stays as it is. In a recovery the check comes when the account
is known (`recover/verify`), and before the passkey sheet. The 12 words alone do not say
whose they are, so `recover/begin` cannot make the check.

The reason: a second account would leave the keys and the session token of the first
account in the Keychain, with no screen that can use them or remove them.

Other code relies on this rule. The setup-finished flag in UserDefaults is one Bool with
no account id (refer to "UserDefaults holds no identifier of the account or of a
transaction"). If an iPhone could hold two accounts, that flag would be wrong for one of
them.

Applies to: `ios/Hasala/Live/Account/LiveAccountService.swift` (`otherAccountHere`,
`beginSignup`, `signInWithPassword`, `verifyRecovery`),
`ios/Hasala/Live/Runtime/BootController.swift` (`Wall.otherAccount`),
`ios/Hasala/Live/Runtime/LocalAccountData.swift`.

## The fresh-install purge runs before any Keychain read

The fresh-install purge (spec 04 §4.4, R-03; `InstallCheck`) runs before anything reads
the Keychain. Keychain items stay on an iPhone after the app is deleted. A new install
must not read the items of an earlier install as its own account.

Thus:

- `AppEnvironment.live` runs the purge first, and the environment is built one time for
  each process.
- The initializer of `LiveAccountService` reads nothing. The gate calls `loadProfile()`
  only after the purge is done.
- `BootController.start()` reads the Keychain (`Boot.gather`) only after
  `retryInstallCheck()` answers `.done`. Until then the gate stays in `waiting`.

Do not add a Keychain read to an initializer, to a static property or to another path
that can run before the purge. Such a read can show the session, the keys or the binding
of an account that the person removed with the app.

Applies to: `ios/Hasala/Live/Runtime/AppEnvironment.swift` (`live`, `purge`,
`retryInstallCheck`), `ios/Hasala/Live/Account/LiveAccountService.swift` (`init`,
`loadProfile`), `ios/Hasala/Live/Runtime/BootController.swift` (`start`).

## The fresh-install purge needs protected data only when there is no install id

An `installID` that reads back from UserDefaults means that this install purged before.
Then the purge answers `.done` and does not ask for protected data.

The reasons are two facts about iOS:

- UserDefaults can read as empty only before the first unlock after a restart. So a value
  that reads back is real, but a missing value is trusted only when protected data is
  available.
- `isProtectedDataAvailable` is false on each locked iPhone that has a passcode. If the
  purge always needed it, a silent push or a background task that starts the app on a
  locked iPhone could not run.

When the purge cannot finish, the gate waits for
`protectedDataDidBecomeAvailableNotification`. A purge that fails while protected data is
available gets no such notification. Thus the gate also tries again on a timer, with a
delay that doubles up to 30 seconds. Do not remove the timer: without it the app stays on
the launch view until the person leaves the app and opens it again.

Applies to: `ios/Hasala/Live/Runtime/AppEnvironment.swift` (`purge`),
`ios/Hasala/Live/Runtime/BootController.swift` (`waitForProtectedData`).

## Only an unsigned Debug simulator build keeps secrets in memory

An unsigned simulator build has no `keychain-access-groups` entitlement, and each
Keychain call fails with `errSecMissingEntitlement`. For that case only, a Debug
simulator run keeps its secrets in memory for the process. A relaunch starts signed out,
and there is nothing to purge. A signed simulator build ("Sign to Run Locally" embeds the
entitlements) uses the Keychain as a device does.

The memory store is compiled only under `#if DEBUG && targetEnvironment(simulator)`. It
must not be in a device build or a Release build. Do not move it out of that condition
and do not make it a fallback for a Keychain error on a device: secrets would then be in
process memory with no Keychain protection, and a Keychain fault would look like a
sign-out.

Applies to: `ios/Hasala/Live/Runtime/AppEnvironment.swift` (`debugSecretStore`,
`secretsInMemory`).

## Account deletion and iPhone removal: the order of the steps

Delete account (spec 04 §4.7 row 4) and "Remove this iPhone" (§4.7 row 2) wipe the
account's store. The order of their steps is fixed.

1. The grant that this iPhone holds at the mail provider is read first, while its token
   is still in the Keychain.
2. The work of the open account is paused, and a run in flight ends, before the step-up.
   Nothing must run while the store is wiped. The deletion uses the context of the open
   account. It does not open a second store on the same files.
3. For a removal, the server stops the wakes for this iPhone (`#33`) before the writer is
   revoked at its verified head (`#25`).
4. The grant is ended only after the server accepted the deletion or the removal
   (for a deleted account: `users.stop`, then the revoke). A cancelled or failed step-up
   must leave Gmail and the watch in operation. The server drops the mailbox link with
   the account.
5. If the step-up is cancelled or fails, the work resumes. After a removal that did not
   occur, the iPhone registers for wakes again.

After a deletion the app only forgets its push registration. It does not call the server
to remove it, because the server dropped the push token with the account.

If the grant ends before the server's answer, a person who cancels Face ID loses the
mailbox connection. If the work is not paused, a sync run or a mail run can write into a
store that is being deleted.

Applies to: `ios/Hasala/Live/Account/LiveAccountService.swift` (`perform`,
`LiveAccountHooks.pause`, `LiveAccountHooks.resume`).

## The app does not ask to lift an operator freeze

The app never sends the unfreeze request (`#66`) for a freeze that the operator made
(spec 04 §6.11). It reads who froze the account from `GET /account` (`frozen_by`) before
the request. If the request is refused, it reads `frozen_by` again, because the operator
can freeze the account between the two calls.

When a run finds the account frozen, the gate reads `GET /account` first, because the
answer decides if the wall offers Unfreeze. If the server cannot be asked, the app keeps
what it knew, or else shows the holder's wall. That wall is safe: its Unfreeze reads
`frozen_by` again before any `#66`.

Only the operator lifts an operator freeze (`hasalad account unfreeze`,
`docs/runbooks/restore.md`). Do not remove the read before the request. Without it the
app offers the holder an action that the server refuses, and asks for a step-up that has
no effect.

Applies to: `ios/Hasala/Live/Account/LiveAccountService.swift` (`unfreeze`,
`freezeInfo`), `ios/Hasala/Live/Runtime/BootController.swift` (`stopped`).

## The step-up password prompt waits for a settled presenter

The mailbox step-up of a password account asks for the password in a `UIAlertController`
over the key window. Two UIKit facts decide how it is presented.

- UIKit does not present over a view controller that is in a transition. The prompt
  usually follows a tap in another alert (for example "Disconnect" in Bank alerts). If
  the round trip of `step-up/begin` is quicker than the dismissal of that alert, the
  alert is still on top. So the prompt waits until the top view controller is not being
  presented, is not being dismissed and has no transition coordinator. It waits at most
  two seconds.
- UIKit refuses a presentation with no error and no callback. Then nobody can answer the
  alert. So one second after `present`, an alert that has no presenting view controller
  counts as cancelled.

Without the wait, a quick server makes the disconnect look cancelled. Without the check
after one second, a refused presentation leaves the step-up, and the connect or
disconnect that waits for it, pending with no end.

Applies to: `ios/Hasala/Live/Account/LiveStepUp.swift` (`StepUpPrompt.present`,
`StepUpPrompt.settledPresenter`).

## UserDefaults holds no identifier of the account or of a transaction

Spec 04 §4.5 permits no identifier in UserDefaults except `installID`. Nothing there
names the account or a transaction. Thus a copy of the preferences does not show whose
account is on the iPhone or which transactions it has.

- The setup-finished flag is a Bool. This is sufficient because an iPhone holds one
  account.
- A key that must tell values apart keeps a digest: the review cards skipped today and
  the push registration. The digest is the first 8 bytes of SHA-256 over this install's
  `installID`, a separator and the value, as 16 hex digits. Equal values give equal
  digests on this iPhone, and a digest names nothing outside this install.
- These values are device preferences. They are never synced.
- Older builds kept transaction ids (`prefs.review.skipped.v1`) and user ids
  (`setup.finished.v1`). The app removes these keys when it reads the new ones, and moves
  the setup flag one time.

Do not add a user id, a transaction id, an email address or a merchant name to
UserDefaults. Use a Bool or a digest, and remove the value in
`LocalAccountData.forget` when the account's data leaves the iPhone.

Applies to: `ios/Hasala/Live/Runtime/LocalAccountData.swift` (`digest`, `salt`,
`migrate`, `forget`), `ios/Hasala/Live/Ledger/LiveLedgerStore.swift`
(`DevicePrefsStore`).

## An account has one mailbox link

The server keeps one mailbox link for each account. Thus the app has no second mailbox
and no "add a second mailbox" capability. A connect of the other provider replaces the
link.

- The replacement occurs only after the person confirmed it ("Change your email?").
  `admit` refuses a connect over a link that operates, or over a broken link of the other
  provider, without that confirmation.
- The two lanes share the mailbox tables in the ledger store. The new lane clears them
  only after its link is made. If the new connect fails or is cancelled, the old lane
  resumes with its state.
- The old lane ends its grant at its provider only after the new link is made.

If the tables are cleared before the new link exists, a failed switch leaves the account
with no mailbox state and a link that still points at the old provider.

`docs/decisions/past-mail-choice.md` gives what a switch reads, and
`docs/decisions/bank-texts.md` ("One source for each person") relies on the one link.

Applies to: `ios/Hasala/Live/Mailbox/LiveMailboxConnecting.swift` (`capabilities`,
`admit`, `connect`), `ios/Hasala/Live/Mailbox/MailboxLane.swift` (`connect`).

## An iPhone without the link can take it over

When another iPhone holds the account's mailbox link and this iPhone never read it (a new
install, a recovered account), this iPhone:

- shows no mailbox row and does not say that bank alerts operate;
- offers the connect, after the server answered who holds the link;
- takes the link over only after the person confirmed it. The server moves the link, and
  the other iPhone stops reading.

The reason: the holder can be an iPhone that the person no longer has, and the server
cannot know this. If this iPhone said "alerts work" or offered nothing, the account
could stay with no iPhone that reads its mail, and with no way to change that.

With no answer from the server (offline) the connect is refused, and no offer shows.

Applies to: `ios/Hasala/Live/Mailbox/LiveMailboxConnecting.swift` (`heldElsewhere`,
`mailboxes`, `offer`, `checkTakeover`).

## An iPhone that does not hold the link cannot disconnect it

The server's route that deletes the mailbox link has no holder check. It deletes the
account's link from any of the account's iPhones. An iPhone that does not hold the link
has no provider sign-in of its own to delete, so a disconnect from it would only stop the
reading on the other iPhone.

Thus the app refuses the disconnect when the lane's phase is `other_device`
(`checkDisconnect`), before the step-up. A mailbox row that another iPhone reads offers
no Disconnect and no switch of provider. The way to move the link is the takeover, which
asks the person first.

Do not remove this check on the ground that the server decides. The server does not.

Applies to: `ios/Hasala/Live/Mailbox/LiveMailboxConnecting.swift` (`disconnect`,
`checkDisconnect`, `mailboxes`).

## The first import outlives the setup screens

The first scan of a mailbox reports its progress as a stream to the setup screens. The
end of that stream does not stop the import. The work runs in a task that is not a child
of the stream's consumer, on purpose.

- When the person finishes setup or closes the sheet, the import continues to its end.
- The foreground part runs at most 50 cycles. The background processing task
  (`app.hasala.ios.processing`) and the next foreground runs do the remainder (spec 04
  §7.7 step 3).
- There is no cards step. The scan files what it reads.

Do not tie the import to the stream with structured concurrency, and do not cancel it
when the stream ends. If somebody does, the import of a person who leaves setup stops
part way, and the remainder waits for a background task or a later foreground run.

Applies to: `ios/Hasala/Live/Mailbox/MailboxLane.swift` (`firstScan`),
`ios/Hasala/Live/Mailbox/LiveMailboxConnecting.swift` (`firstScan`).

## A mailbox connect waits for the grant endings of accounts that left

When an account leaves an iPhone (deleted, removed, erased, wiped), the app ends the
grant that the iPhone held at the mail provider. An ending is not scoped to the Hasala
account that left:

- Google's revoke ends the whole grant of this app for the Google account. All Hasala
  accounts share one iOS client id.
- `users.stop` ends the watch of the mailbox for the whole Google project.

If an ending ran as a detached task, it could reach Google after the next account on this
iPhone linked the same mailbox. It would end the grant and the watch of that new link.
The first scan of the new account would stop on `reconnect_required` and import nothing.

Thus:

- All endings run through one queue (`MailGrantEnds`), one after another.
- A departure waits for its ending, at most 10 seconds (`departureWait`), then continues.
- `MailboxLane.connect` waits for all earlier endings before the provider sign-in, at
  most 20 seconds (`connectWait`). If one still runs, the connect is refused with "Try
  again". A sign-in at that time is not safe.
- Each ending is bounded inside that wait. An ending sends at most 5 requests
  (`requestsPerEnding`: for Gmail the refresh, `users.stop` and the revoke; for Outlook
  the refresh and the subscription delete), and each request has a limit of 3 seconds
  from start to end (`requestLimit`). That is 15 seconds, below `connectWait`.
- The limit is `timeoutIntervalForResource`. `timeoutIntervalForRequest` limits only the
  time between bytes, so a slow answer could go on with no end.

If you change one of these numbers, keep `requestsPerEnding × requestLimit` below
`connectWait`. Do not start an ending outside the queue.

Applies to: `ios/Hasala/Live/Mailbox/MailboxLane.swift` (`MailGrantEnds`, `connect`),
`ios/Hasala/Live/Account/LiveAccountService.swift` (`grantEnds`).

## A grant is ended before the local wipe, and Outlook has no revoke

When an account leaves an iPhone (spec 04 §4.7 rows 2 to 4), the app ends the provider
grant before it wipes the local secrets, because the ending needs the refresh token. If
the app is stopped during the ending, the token stays on the iPhone and the next
departure ends it. A wipe first would leave a grant at the provider that nothing on the
iPhone can end.

The ending is best effort. An account must be able to leave the iPhone when the provider
cannot be reached, so a failed request does not stop the departure. Then the grant stays
in the provider's list, but its token is gone from the iPhone. A provider with no client
id in the build gets no request.

- Gmail: `users.stop` first, but only when this iPhone deletes the account itself. Then
  the refresh token is revoked at Google. When only this iPhone leaves (a removal, an
  erase, a deletion made on another device), `users.stop` is not sent.
- Outlook: Microsoft gives no revoke endpoint. When this iPhone deletes the account, the
  app deletes this iPhone's Graph subscription. The tokens are only forgotten. The person
  ends the consent at `account.live.com/consent/Manage`.

Do not tell the person that Hasala removed its access to an Outlook mailbox. It cannot.

Applies to: `ios/Hasala/Live/Mailbox/MailboxLane.swift` (`endGrant`,
`endGrantThenWipe`), `ios/Hasala/Live/Runtime/BootController.swift` (`stopped`),
`ios/Hasala/Live/Runtime/AppEnvironment.swift` (`eraseLocalData`).

## The live net worth history comes from the check-ins (2026-11-25)

The projection keeps each check-in of an account with its time (`checkin`, `as_of_ms`). The
live mapper makes the net worth history from them (issue 310; the owner decided on
2026-11-25 to build this part alone, before Add an account and the check-in sheet).

- The balance of an account at a time is its latest check-in before that time that is not
  void. This is the rule that already gives the balance of today. A check-in whose date
  cannot be read is not used.
- A month ends when the next month starts in UAE time (`LocalClock`). A check-in at
  00:00 on the first day belongs to the new month.
- The net worth at a time is known only when each account that has a check-in has one
  before that time. An account with no check-in counts as zero at each time, as it does in
  the net worth of today, so it does not hide the history. Only active accounts count, as
  in the net worth of today.
- The change this month is the net worth of today minus the net worth at the start of this
  month. It is absent (`NetWorthHistory.monthChange` is nil) when the start of this month
  is not known. Hasala does not show a first check-in as money that came in this month.
- The chart has 12 points: the ends of the 11 months before this one, then today. It is
  absent (`spark` is empty) when one of these month ends is not known. So the change can
  show before the chart does. The mapper gives each point as a part of 1000 between the
  lowest and the highest point, and 500 for each when all are equal, because the Home
  sparkline draws the value as it is.
- Each point uses the rates of today (`Money.homeTotal`), as the net worth of today does.
  The ledger keeps no rate history. A balance in a currency with no rate is left out of
  each point.

The Home widget and the Insights report still read an absent change as zero. Their copy
for that state is not decided.

Applies to: `ios/Hasala/Live/Ledger/LedgerStateMapper+NetWorth.swift`
(`netWorthHistory`, `permille`),
`ios/HasalaKit/Sources/HasalaModels/Ledger/LedgerState.swift` (`NetWorthHistory`),
`ios/HasalaKit/Sources/HasalaModels/Engines/AccountsEngine.swift` (`snapshot`),
`ios/HasalaKit/Sources/HasalaModels/Engines/HomeEngine.swift` (`netWorthWidget`),
`ios/HasalaKit/Sources/HasalaModels/Engines/InsightsEngine.swift` (`reports`).
