# iOS mailbox lane and model: decisions from the code (2026-11-21)

These decisions were code comments under `ios/HasalaCore/Sources/HasalaCore/Mailbox/` and
`ios/HasalaCore/Sources/HasalaCore/Model/`. Code comments are
not permitted (`scripts/comment-lint.ts`), thus the decisions are here.

The Outlook decisions (the `$filter` listing, the page check, immutable ids, the sender
rule, the download width of 3, `Retry-After`, the subscription) are in
`docs/decisions/outlook-mailbox.md`. This file does not repeat them.

## The mail listing always filters by sender

The lane asks the mail provider only for mail from the trusted set T (the rule "PO G";
spec 04 §7.5, §7.6; spec 03c §7.2). T is the `sender_trust_set` fold, minus forwarders,
minus shared public suffixes, and with only query-safe domains. T is also the listing
set. When T is empty, the lane lists nothing. It never lists everything.

The rules that follow from this:

- A `MailSource` refuses an empty sender list (`unfilteredListing`). It does not send an
  unfiltered request.
- There is no "list everything new" call. The Gmail client has no `history.list`, because
  that call returns the id of each new message in the mailbox. `users.getProfile` asks for
  `historyId` only, as a change detector.
- The Gmail metadata request asks for the `From` and `Authentication-Results` headers
  only. It asks for no snippet and no Subject (R-07). The raw request is made only for a
  listed id.
- Listing is not trust. A listed message files with no review only when the trust gate
  passes for a domain in T (`MessageDisposer`).
- A mail client does not retry and does not interpret. A non-2xx answer becomes a typed
  `MailAPIError` with the status, and the engine decides what it means.

The reason is privacy. The rest of the inbox, its message ids and its headers included,
must not reach the phone's code. If a change adds an unfiltered listing, a fallback that
lists all mail, or a wider metadata request, Hasala reads mail that is not bank mail.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Mailbox/BankDomains.swift`
(`effectiveTrusted`), `ios/HasalaCore/Sources/HasalaCore/Mailbox/GmailClient.swift`
(`messagesList`, `messageMetadata`), `ios/HasalaCore/Sources/HasalaCore/Mailbox/MailProvider.swift`
(`MailSource`).

## The Gmail listing includes Spam and leaves out Trash

`messages.list` is sent with `includeSpamTrash=true`. Bank mail that Gmail filed
incorrectly, or that a person forwarded, can be in Spam. Such a message must come to
Review, not disappear. Gmail has one switch for Spam and Trash together, thus the sender
query itself ends with `-in:trash`.

If a change removes `includeSpamTrash`, bank mail in Spam is lost with no notice. If a
change removes `-in:trash`, mail that the person deleted is imported.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Mailbox/GmailClient.swift`
(`messagesList`, `senderQuery`).

## A Gmail quota 403 is a rate limit

Gmail answers a per-user or per-project quota limit with 403 and also with 429. The
client reports such a 403 as a 429. The engine then waits and narrows its downloads. All
other 403 answers (for example `insufficientPermissions`) stay 403, which is fatal and
asks the person to connect again.

The client reads only the reason codes of the error body. Gmail still sends the legacy
shape (`error.errors[].reason`). The newer AIP-193 shape has `error.details[].reason` and
`error.status`. The client reads the three places.

If a change treats each 403 as fatal, a person who reaches the Gmail quota during the
first import is told to connect again, although the grant is good.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Mailbox/GmailClient.swift`
(`isRateLimit`, `rateLimitReasons`).

## Gmail downloads: four at a time, and longer waits after a 429

Each message costs two `messages.get` calls of 5 quota units each. Gmail permits 250
units for each user in each second. Six downloads at the same time on a fast connection
went over this limit. Thus the Gmail download width is 4.

Google's limit is a moving average. The short retries for a transport error (400 ms, then
1.2 s) only meet the limit again. Thus a 429 has its own waits: 1, 2, 4 and 8 seconds.

If a change raises the width or uses the short waits for a 429, a first import stops on
rate limits again and again.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Mailbox/MailboxEngine.swift`
(`MailboxEngineConfig.downloadWidth`, `rateLimitBackoffMs`).

## The mail OAuth clients are public clients, and the tokens stay in the Keychain and in memory

The Google client and the Microsoft client are public clients (PKCE S256, spec 04 §7.2,
A-23). No client secret is in the app. The client id comes only from `BuildInfo`. Do not
write it in the core.

- The refresh token is in the Keychain item of the account (spec 04 §7.3, §4.4).
- The access token is only in memory, in `RefreshingMailTokenProvider`. The provider gets
  a new one when fewer than 60 seconds remain. Do not write it to disk or to a log.
- Microsoft sends a new refresh token with each refresh, and the provider keeps the newest
  one. Google sends none. If the write of the new token fails, the old token stays. It
  operates until it expires.
- Each request to Google or Graph uses an ephemeral `URLSession`: no cookie store, no URL
  cache and no credential storage.
- The HTTP seam writes no log. A request can carry a bearer token or a refresh token.
  A token must not go into a log line, an error value or a report (spec 04 §2.4 R7). A
  failure of the token endpoint keeps the status only, not the body.

If a change adds a log of a request, a disk cache or a shared session, a mail token can
leave the Keychain.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Mailbox/GmailOAuth.swift`,
`ios/HasalaCore/Sources/HasalaCore/Mailbox/Outlook/MicrosoftOAuth.swift`,
`ios/HasalaCore/Sources/HasalaCore/Mailbox/HTTP.swift` (`URLSessionHTTPExchange.ephemeral`),
`ios/HasalaCore/Sources/HasalaCore/Mailbox/TokenProvider.swift`
(`RefreshingMailTokenProvider`).

## An absent mail secret and an unreadable mail secret are different

The refresh token (`.mailRefresh(provider, userID)`) and the Outlook link state
(`outlookClientState(userID:)`) are items of the account's `Secrets`. They use the same
store, access group and accessibility as all other items of the account. Thus
`Secrets.wipeAccount` (sign-out, deletion, a reset of foreign data) always removes them.
Do not keep a mail secret in another place.

A store has two different answers:

- `read()` returns nil: there is no token. The mailbox is not connected.
- `read()` throws: the item is there, but the Keychain cannot give it now (before the
  first unlock). The token provider reports `notNow`. Nothing changes, and a later trigger
  tries again.

Do not treat a throw as "absent". A locked phone would then show the mailbox as
disconnected.

An item that reads but holds no token (empty, or not UTF-8), or an Outlook link item that
does not decode, can never operate. The store deletes it and reads it as absent. The
account then shows "disconnected" and the person can link again. Without this, each cycle
ends in "not now" and the person has no way out.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Mailbox/TokenProvider.swift`
(`MailRefreshTokenStore`), `ios/HasalaCore/Sources/HasalaCore/Mailbox/SecretsMailRefreshTokenStore.swift`,
`ios/HasalaCore/Sources/HasalaCore/Mailbox/Outlook/GraphClient.swift`
(`SecretsOutlookLinkStore`).

## The app reads the id_token and does not verify it

The app does not verify the signature of a Google or Microsoft id_token. The server
verifies it (spec 02 §13.2; `googlejwt`, `msjwt`). The app reads only two things: the
address that Bank alerts shows, and the nonce. For Microsoft it also reads the tenant, and
a token of a tenant other than `consumers` gives no identity.

The app compares the nonce with the one it sent, in constant time, before the step-up.
This is not the security check. Its purpose is that a browser sheet which came back from a
different attempt fails before the person sees a step-up prompt.

The Microsoft scopes include `profile`, thus the token can carry `preferred_username`.
The app uses it only when `email` is absent and the value is an address.

Do not use these claims for a decision that needs trust. If a change adds signature
verification to the app, it adds key handling for no gain. If a change removes the
server's verification because "the app checks", nothing verifies the token.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Mailbox/GmailOAuth.swift`
(`GoogleIDTokenClaims`, `OAuthWire.claims`), `ios/HasalaCore/Sources/HasalaCore/Mailbox/MailProvider.swift`
(`MailIdentity`), `ios/HasalaCore/Sources/HasalaCore/Mailbox/Outlook/MicrosoftOAuth.swift`
(`MicrosoftIDTokenClaims`), `ios/HasalaCore/Sources/HasalaCore/Mailbox/MailboxEngine.swift`
(`connect`).

## A connect proves the mailbox before the step-up

After the code exchange, the engine asks the provider if the account has a mailbox that
the API can read (`checkMailbox`). It does this before the step-up and before
`PUT /mailbox/link`. An account with no mailbox ends the connect with `no_mailbox`, and
nothing is linked.

The order is necessary. A new link replaces the account's link to the other provider. If
the check came after the link, a connect of an account with no mailbox would replace a
link that operates with a link that can read nothing.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Mailbox/MailboxEngine.swift` (`connect`).

## A provider switch clears the old lane only after the new link is made

When the account changes its provider, the mailbox tables still hold the lane of the old
provider. The engine clears them only after the new link is made, and in the same commit
as the new state. The connect is then a first connect. A switch that the person cancels,
or that fails, leaves the tables as they were.

If a change clears the tables before the link is made, a cancelled switch loses the old
lane's accounting and watermark, and the old mailbox is scanned again.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Mailbox/MailboxEngine.swift` (`connect`,
`replacing`).

## An iPhone that lost the link does not revoke the grant or stop Gmail's watch

When another iPhone becomes the holder of the link, or the link is deleted from another
place, this iPhone deletes its refresh token from the Keychain. It does not revoke the
token at the provider. This is a deviation from spec 04 §7.4 ("revoke own refresh
token"). The two iPhones use the same iOS client id. Google's revoke ends the full grant
of that client for that Google account, thus it would also sign the new holder out. This
behaviour of Google is not confirmed on a real account yet (the AT-GMAIL run).

Push follows the same rule. Gmail's `users.stop` ends the watch of the mailbox for each
client, thus an iPhone that lost the link must not call it. An Outlook subscription has
its own id, and this iPhone keeps the id of the one it made. Thus Outlook's `stop` deletes
only this iPhone's subscription (`stopIsDeviceScoped`). The engine stops push on loss of
the link only for such a provider, and a failure there is permitted: the new holder's
subscription replaces an old one.

If a change adds a revoke or a `users.stop` to this path, a takeover on a second iPhone
breaks the mailbox on the iPhone that just connected.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Mailbox/MailboxEngine.swift` (`cycleLocked`,
`endLocalPush`), `ios/HasalaCore/Sources/HasalaCore/Mailbox/TokenProvider.swift` (`forget`),
`ios/HasalaCore/Sources/HasalaCore/Mailbox/MailProvider.swift` (`stopIsDeviceScoped`).

## Disconnect stops when the revoke fails

Disconnect has this sequence: step-up `mailbox.unlink`, stop push, revoke the refresh
token, `DELETE /mailbox/link`, delete the Keychain item, clear the mailbox tables.

If the revoke does not succeed (offline, a 5xx, or a Keychain that cannot be read now),
the disconnect stops there and reports a failure. The token stays in the Keychain, thus a
second try can still end the grant. The app must not say that access ended when it did
not. A token that the provider does not know any more counts as revoked (Google answers
400 `invalid_token`).

There is one exception. When another provider's link replaced this one, the iPhone stops
its use of the old grant in all cases. There the revoke is best effort, and the item is
deleted whatever the answer (`keepOnFailure: false`).

If a change deletes the token before the revoke succeeds, a failed revoke leaves a grant
at the provider that the app can no longer end.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Mailbox/MailboxEngine.swift` (`disconnect`,
`endGrant`), `ios/HasalaCore/Sources/HasalaCore/Mailbox/TokenProvider.swift`
(`revokeAndForget`).

## Microsoft has no revoke endpoint

The Microsoft identity platform has no endpoint that revokes a refresh token. Thus
`MicrosoftOAuthClient.revoke` sends nothing and succeeds. Disconnect shows the person
where to end the consent (`MicrosoftOAuthConfig.consentManagementURL`).

The empty function is not an error. Do not add a request to it, and do not remove the
pointer to the consent page from Disconnect: it is the only way to end the grant at
Microsoft.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Mailbox/Outlook/MicrosoftOAuth.swift`
(`revoke`, `consentManagementURL`).

## A message's op and its accounting commit in one transaction

Each `MailboxPersistence.commit` is one SQLite transaction. It holds the `pending_ops`
row or rows of a message and the accounting of that message (spec 04 §7.5 step 7f). The
op and the mark "this message is done" cannot disagree.

This is the reason that the mailbox tables are in `ledger.sqlite`, where `pending_ops`
is, and that persistence is a port which CoreStore implements (CoreMailbox does not
import GRDB, spec 04 §2.4 R6). The persistence does not build an op. It gets each op from
CoreDomain's `OpAuthor` (R5, the only op constructor) through the `author` closure.

If a change moves the accounting to a second transaction or a second database, a process
stop between the two writes gives a message with an op and no mark (the next cycle
authors it again) or a mark and no op (the payment is lost with no notice).

Applies to: `ios/HasalaCore/Sources/HasalaCore/Mailbox/LedgerMailboxPersistence.swift`,
`ios/HasalaCore/Sources/HasalaCore/Mailbox/MailboxState.swift` (`MailboxPersistence`,
`MailboxCommit`).

## Mailbox engine invariants

`MailboxEngine` is one actor for each bound account (spec 04 §7.4 to §7.9). Each entry
point is serialized. A cycle that is asked for while one runs waits for it and returns its
report. A cycle does not throw: each failure ends as `haltedOn` in the report and, when
the person must do something, in the stored phase.

A test in `CoreMailboxTests` pins each of these rules:

- Each listed message ends accounted (an op, set aside, unreadable, a duplicate or gone)
  in the same transaction as the enqueue of its op. A cycle that was cut does not download
  a message again.
- The cycle keeps this order: the holder check; a pull to head, so that the ops of other
  devices are visible to the duplicate check; the token; the change token, which is read
  before the listing; the listing and the accounting; the flush; the watermark.
- The watermark moves only after the listing of each sender group is exhausted, each id is
  accounted and the outbox is flushed. A run that was cut keeps the old watermark and
  lists again.
- 404 and 410 are `gone` (accounted). A 5xx or a transport error retries after 400 ms,
  then 1200 ms. A 429 retries after 1, 2, 4 and 8 seconds and narrows the download width
  to 1 for the remainder of the run. A 429 or 503 that gives `Retry-After` stops the run
  immediately, and no cycle starts before that time. 401 and 403 are fatal. Each other 4xx
  halts the lane.
- A 413 on the flush halts with `account_full`, and the watermark does not move.
- No token is `reconnect_required`. A Keychain that cannot be read is "not now".
- Downloads run at the same time, but the results are accounted one at a time, in the
  order of the listing.
- A run with a deadline, or a background processing run, lists one page, downloads it and
  then lists the next page. Thus a short run always makes progress. A foreground run lists
  all pages first, so that the first-scan board has a total.
- The page token of a listing lives only in one run. `mailbox_state` has no
  `list_page_token` column. A later run lists again from the start, and the accounted set
  makes this cheap (ids only, no downloads).
- When a reconnect, a takeover or a halt interrupts the first-connect setup, the engine
  records the phase (`halted_detail` is `resume:<phase>`) and continues that phase later.
  A backfill that started does not start again as a scan.
- There is no cards step. The phase `awaiting_cards` stays only because an older build
  can have stored it. The next cycle authors what that scan staged. Keep the case while
  such a stored state can exist.

If a change breaks one of these rules, the lane loses a message, authors a message two
times, or downloads the same mail on each cycle.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Mailbox/MailboxEngine.swift`,
`ios/HasalaCore/Sources/HasalaCore/Mailbox/MailboxState.swift` (`MailboxState`).

## A scan with no trusted sender waits

A first scan can run before the `sender_trust_set` ops of Setup's bank step have folded.
The trusted set is then empty. The scan lists nothing and stays in the scanning phase. It
does not finish as an empty scan (spec 03c §7.2: an empty T lists nothing).
`runFirstScan` stops when a cycle listed nothing and did not finish, and the next trigger
continues the scan.

If the scan finished here, the lane would become active with no past mail imported, and
the person would see an empty import.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Mailbox/MailboxEngine.swift` (`scan`,
`runFirstScan`).

## The first scan continues through passing stops

A 90-day backfill is a thousand or more mail API calls. A cycle stops at the first call
that outlives its retries (Gmail's rate limit for each user, a dropped connection, an
access token that expired during the run). Its work up to there is committed, and the next
cycle continues.

Thus a passing stop (`gmail`, `offline`, `quota`) does not end `runFirstScan`:

- When the last cycle read something, the next cycle runs immediately.
- When it read nothing, the next cycle runs after the next wait in
  `firstScanStallWaitsMs`, or after the provider's `Retry-After`. After the last wait the
  scan gives up.
- A pause longer than the longest wait (a long `Retry-After`) is left to the later
  triggers. The setup board says that the import continues in the background.
- During this time a passing stop is not shown as failed progress, because the scan
  continues.

If a change ends the first scan on the first passing stop, most first imports show an
error after some hundreds of messages.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Mailbox/MailboxEngine.swift`
(`runFirstScan`, `passing`).

## Mailbox ops are stamped under the account's shared author stamps

The mailbox persistence authors its ops in a closure that cannot wait for an actor. Thus
`MailboxAuthoring` keeps the inputs of the author rule (spec 03c §1.8.2) itself. The
newest stamp of this writer is the largest of three values: the newest pending op, the
fold's `maxAuthored` (which `RuntimeMailboxLedger` gives after each pull), and the
device's shared `AuthorStamps`. The blob is built inside the lock of `AuthorStamps`.

`stamps` must be the one shared instance of the account (`LedgerPageObserver.stamps`).
`MailboxAuthoring(observer:)` gives this. The `MailboxAuthoring` of the
`RuntimeMailboxLedger` must be the same object that `LedgerMailboxPersistence` uses.

The result: a mailbox blob and a blob that a screen authors never have the same stamp, and
the observer sees a mailbox stamp before the pull of the device's own ops folds it. If a
change gives the mailbox lane its own stamp memory, two blobs of one writer can have the
same stamp, and the author rule is broken.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Mailbox/MailboxAuthoring.swift`,
`ios/HasalaCore/Sources/HasalaCore/Mailbox/RuntimeMailboxLedger.swift` (`init`).

## The halt code `gmail` keeps its stored value

`MailboxHaltCode.gmail` means "the mail provider refused in a way that a retry does not
correct". It has the name of the first provider. The stored value is `gmail` for each
provider, Outlook included.

Do not change the raw value, and do not add a value for each provider. `mailbox_state`
rows on phones hold this value, and the screens read it.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Mailbox/MailboxState.swift`
(`MailboxHaltCode`).

## A Graph next link is followed only on the client's own origin

The page token of an Outlook listing is Graph's `@odata.nextLink`. It is a full URL that
comes from a response. The client uses it as it was returned, and it does not change it.
But the client sends the request only when the URL starts with its own API base and the
`/me/messages?` path. Each other value fails the listing.

The request carries the access token. If a change follows a next link with no check, a
response can send the person's mail token to another host.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Mailbox/Outlook/GraphClient.swift`
(`listMessages`).

## The session bearer goes only to the API origin

`SessionHTTPExchange` carries hasalad's mailbox routes on the app's session `Transport`.
Only the path and the query of a request travel. The transport sends them to its own API
origin, and the bearer is read from `Secrets` on each call. Thus a request that was built
for another host cannot carry the session there.

A path must start with exactly one `/`. A path that starts with `//` is a network-path
reference, and the URL resolution would make it a new host. The exchange refuses such a
path before it reads the bearer, and it sends nothing.

No session, or a logout that is pending, sends no bearer, and the server answers 401. A
Keychain that cannot be read now (before the first unlock) is `offline`: a later trigger
tries again, and the app does not show "signed out".

Applies to: `ios/HasalaCore/Sources/HasalaCore/Mailbox/SessionHTTPExchange.swift`
(`send`, `isOriginPath`).

## A midnight value from a template with timed and bare-date layouts is a bare date

A date layout with no time renders midnight. When a template has layouts with a time and
layouts without one, the reader cannot tell a bare date from a printed 12:00 AM. It reads
a midnight value as a bare date. A payment that the bank printed at exactly 12:00 AM
loses its time and keeps its day. The owner accepted this limit.

The other choice gives each bare date a false time of midnight with the precision
`time`, which is wrong for many more rows.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Mailbox/Disposition.swift`
(`MessageDisposer.postedAt`).

## Only Apple's on-device model, and its tag names the OS

`Model/` is the only code that imports FoundationModels (spec 04 §2.2;
`ios/scripts/check-imports.sh` enforces it). Only the app links it, and no core layer
depends on it.

- The code uses only `SystemLanguageModel`, the model on the device (spec 03c §8.6). The
  iOS 27 SDK also has a cloud model type. Do not refer to it (03c §8.6.1). A merchant name
  must not leave the phone through Apple's model.
- When the SDK says that the model is not available, the pipeline does not use this tier,
  and the rows stay in Review.
- Each suggestion uses its own session, so the calls are independent and run one after
  the other. `ModelTier.run` owns the budgets, the Latin gate and the removal of
  duplicates.
- The model tag is `apple-fm/<major>.<minor>` of the OS that runs (03c §8.6.6). The model
  comes with the OS, and the tag is part of the `fm_cache` key. Thus an OS update makes
  the old cached answers unused. A constant tag would keep the answers of an old model.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Model/HasalaModel.swift`
(`FoundationModelsCategoryModel`, `HasalaModelFactory.osModelTag`).

## GenerationOptions is built for two SDKs

The iOS 27 SDK changed the label of the sampling argument of `GenerationOptions` to
`samplingMode:` and deprecated `sampling:`. The iOS 26 SDK has only `sampling:`. The CI
job `swift` builds HasalaCore with Xcode 26 (Swift 6.3), and the app builds with Xcode 27.
Thus the code has the two forms behind `#if compiler(>=6.4)`.

Do not remove one of the branches while CI and the app use different Xcode versions. The
job `swift` is not a required check, thus a break there does not stop a merge.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Model/HasalaModel.swift`
(`GenerationOptions.greedy`).
