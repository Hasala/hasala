# iOS app, Security to SignIn features: decisions from the code (2026-11-21)

These decisions were code comments under `ios/Hasala/Features/Security/`,
`ios/Hasala/Features/Setup/`, `ios/Hasala/Features/Shared/`, `ios/Hasala/Features/Shell/`
and `ios/Hasala/Features/SignIn/`. Code comments are
not permitted (`scripts/comment-lint.ts`), thus the decisions are here.

## Delete account is reachable from the profile itself

"Delete your account" has a row on the profile and a row on Sign-in & security. The row
on the profile must stay. App Review asks that a person can start the deletion of the
account in the app, from a place that is easy to find (Guideline 5.1.1(v)). A build that
keeps the row only on a deeper page can fail the review.

The deletion asks one time in an alert, then it goes through "Confirm it's you".

Applies to: `ios/Hasala/Features/Security/DeleteAccountView.swift` (`DeleteAccountView`).

## The account's fitted sheet leaves the bottom safe area out of its detent

`FittedSheet` is a floating sheet with one detent, the height of its content. iOS adds the
bottom safe area under a custom detent. Thus the content ignores the bottom safe area and
lays out over it, and the detent is the content height minus that inset. The bottom
padding of the content is then the only space under its last control, as Paper draws it.
If the inset stays in the detent, the sheet is too tall by the height of the home
indicator area.

The sheet keeps only the inset of the home indicator. A keyboard gives a much larger
bottom inset. The sheet does not keep an inset of 60 pt or more, because the detent must
not get smaller while the keyboard is up.

At the accessibility text sizes the sheet is large, the content respects the safe area
and it scrolls. The Plan sheets follow the same rule with their own code
(`docs/decisions/code/ios-hasala-features-plan-to-search.md`).

Applies to: `ios/Hasala/Features/Security/ConfirmItsYouSheet.swift` (`FittedSheet`).

## A typed password and the viewed words leave memory when their screen goes

A password or a phrase stays in the app's memory only while its screen needs it (c2 §12
rule 7). The rule has these parts:

- Set or change the password: the new password and its repeat stay while the page is
  open, so a cancelled confirmation leaves the page as it was. When the page closes, by
  Back, by a swipe or after the change, the two values are emptied
  (`SecurityModel.editingPassword`).
- "Confirm it's you" with a password: the password is emptied after each attempt. This
  includes a wrong password, a closed Face ID prompt and a closed passkey sheet. A
  password that was sent is used, and the person types it again for a new attempt.
- Sign in: the password is emptied after a failure. The box then shows its placeholder
  under the error ring.
- "View your 12 words": the words are dropped when the cover disappears
  (`SecurityModel.closePhrase` in `onDisappear`). This is true for Done, for Close and for
  a session that ends below the cover.

Do not keep one of these values to make a retry easier. A value that stays is readable in
memory after the person left the screen.

Applies to: `ios/Hasala/Features/Security/SecurityModel.swift` (`editingPassword`,
`confirm`, `savePassword`), `ios/Hasala/Features/Security/PhraseViewer.swift`,
`ios/Hasala/Features/SignIn/SignInViews.swift` (`SignInView.passwordBox`),
`ios/Hasala/Features/SignIn/UnlockViews.swift` (`UnlockModel.addPasskey`).

## What a confirmation opens waits until the confirmation sheet is gone

A confirmation can lead to a full-screen cover: "View your 12 words" or the change of the
email address. SwiftUI does not present a cover while a sheet of the same page is up or
is closing. Thus `SecurityModel` holds the result (`pendingPhrase`, `pendingEmailChange`)
and `confirmationDismissed()` gives it to the cover only after the sheet has gone. If the
model sets the cover's value at once, the cover does not open.

For the same reason the confirmation is presented by the page that is on top
(`SecurityModel.Host`: the Sign-in & security page, the password page or the lockdown
page). A sheet that a page below another page presents does not show. The only
presentation below the confirmation is the large sheet of the profile.

Applies to: `ios/Hasala/Features/Security/SecurityModel.swift` (`Host`, `pendingPhrase`,
`pendingEmailChange`, `confirmationDismissed`),
`ios/Hasala/Features/Security/SecurityView.swift` (`confirmSheet`).

## Sign out everywhere ends this iPhone's session too

"Sign out everywhere" ends each session of the account on the server, and the session of
the iPhone that asks is one of them (`02` §9.3). Thus the app signs this iPhone out after
the call succeeds, as it does after the deletion of the account. The keys and the local
copy stay on each device. If the app keeps the session after this call, each later
request fails with an ended session.

Applies to: `ios/Hasala/Features/Security/SecurityModel.swift` (`performed`).

## The app's words differ from Paper where Paper's words would be untrue

In these places the copy is not Paper's, because Paper's sentence is false for the live
app. Do not change them back to agree with the design file.

- The confirmation to remove a passkey. Paper's mock passkey has the name of a device,
  and its bullet says that this device cannot sign in any more. A live passkey has the
  name of its provider (a keychain or a password manager). That provider can still sign
  in to all other things. Thus the bullet names the passkey: "The <provider> passkey
  can't sign in any more".
- The alert "Sign out of this iPhone?". Paper I1C-0 says that the data is erased. Sign
  out keeps the data of this iPhone, locked (S-26). The alert says that. The profile and
  Sign-in & security use one string (`AccountCopy.signOutMessage`), so the two cannot
  become different.
- The honest end (Paper H9F), the line about another signed-in device. Paper's line
  ("add a passkey or show your words") is true only for a passkey account in a build that
  can add passkeys. Only the device of a passkey account can show the words (S-41). The
  device of a password account cannot show them, and a passkey that it adds holds no
  keys. When the person is signed out, the app does not always know the method, and the
  line must be true for the two methods.

Applies to: `ios/Hasala/Features/Security/SecurityModel.swift` (`words(for:email:state:)`),
`ios/Hasala/Features/Shared/AccountCopy.swift` (`signOutMessage`),
`ios/Hasala/Features/SignIn/SignInViews.swift` (`HonestEndScreen.otherDevice`).

## The honest end offers a person and deletion, not a fresh start

The honest end (Paper H9F) has a link "Start fresh with this email" and a warning that the
old sealed data is deleted after 7 days. The app does not have them. No start-fresh
ceremony exists: the server has no route for it and `AccountService` has no method. A
Debug build showed the link as a placeholder that only gave the failure "Not in the beta
yet", and a Release build showed the two links below. The owner decided on 2026-11-25 to
remove the placeholder and not to build the ceremony (issue #324).

Thus each build shows the same two links (`HonestEndScreen.helpLinks`): "Talk to a
person" opens the support page, and "Delete my account instead" starts a mail to the
privacy address. Do not add the link again without the ceremony behind it.

Applies to: `ios/Hasala/Features/SignIn/SignInViews.swift` (`HonestEndScreen.helpLinks`).

## A password reset on a new iPhone uses the 16-character code, and the new password comes first

The forgot-password ceremony (C9) has two rules that Paper does not show.

The code. Paper lets the person compare a two-digit number on the two iPhones. The reset
code of the service is 16 characters that the new iPhone shows (spec 04 §6.1.4). The
iPhone that approves asks the person to type these characters, and the new iPhone shows
them in four groups of four. A person who cannot read the screen of the new iPhone cannot
approve its request. A two-digit number does not give this property. The approving iPhone
compares the code before any Face ID prompt
(`docs/decisions/code/ios-hasala-features-account-to-bills.md`).

The order. The person chooses the new password before the app asks the other iPhone. The
service binds the new password to the request (spec 04 §16.4), and the password has effect
when the other iPhone says yes. A flow that asks for the approval first has nothing to
bind. The request lives 10 minutes.

Applies to: `ios/Hasala/Features/Security/ResetApprovalViews.swift` (`ResetApprovalSheet`),
`ios/Hasala/Features/SignIn/SignInViews.swift` (`ForgotNewPasswordView`, `ForgotWaitingView`),
`ios/Hasala/Features/SignIn/SignInModel.swift` (`requestApproval`).

## Recovery takes the words first, and its code is bound to the new way to sign in

Access recovery (C4) follows the order of the service, not the order of Paper.

- The service takes the 12 words first. It sends the code to the email address of the
  account that the recovery key belongs to. Thus the recovery screens have no email field
  (Paper asks for the email first), and the code screen is step 2 of 3.
- `recover/verify` needs the code and the kind of the new way to sign in, a passkey or a
  password (spec 04 §6.2 C4 step 3). The ceremony is then bound to that kind (`02` #48).
- The app sends `recover/verify` one time. When a new passkey is the only way that the
  build offers, the code screen sends it. If not, the method screen sends it with the
  kind that the person chose.
- After the verification the code is spent. The app refuses a credential of the other
  kind and tells the person to go back to the words, which starts a new ceremony.

If a change sends the verification again or changes the kind after it, the service
refuses and the person cannot complete the recovery.

Applies to: `ios/Hasala/Features/SignIn/SignInModel.swift` (`submitRecoveryCode`,
`finishRecovery`, `verifiedRecoveryKind`), `ios/Hasala/Features/SignIn/SignInViews.swift`
(`RecoverIntroView`), `ios/Hasala/Features/SignIn/SignInEntryPoints.swift`
(`RecoverCodeView`).

## A CSV export is built in memory when the person shares it

A CSV export (spec 04 §16.2 T5, X6) is a `Transferable` with a data representation. The
bytes are made from the rows on the screen at the moment the person shares the file. The
app writes no file to disk first. A file representation would leave a plaintext copy of
the transactions in a temporary directory.

Applies to: `ios/Hasala/Features/Shared/CSVFile.swift` (`CSVFile`).

## Chip rows break with one rule, with half a point of rounding

`FlowLayout` measures its rows and places its chips with the same function
(`FlowLayout.rows`). That function lets a row be half a point wider than the width
offered.

The reason: the layout reports the width of its widest row, and SwiftUI then places it in
a box that is rounded to the pixel grid. This box can be a fraction of a point narrower.
With two different rules, or without the half point, the last chip of that row moves to a
new row at placement. The layout did not reserve that row, so the chip is drawn on top of
the view below (a chip on a checkbox, in the pick sheet).

Do not write a second row-break rule for placement, and do not remove the half point.

Applies to: `ios/Hasala/Features/Shared/FlowLayout.swift` (`FlowLayout`, `rows`).

## Memo stays outside Observation, and its key reads the store's revision

`Memo` keeps the last value that a view model derived from a key. A screen reads its
snapshot many times in one redraw, and the engine must run one time for each change of
the ledger or of an input (spec 04 §18.3).

Two conditions make this correct:

- The view model holds the memo as `@ObservationIgnored`. The memo changes during a read.
  If Observation tracks it, each read invalidates the view that reads.
- The key includes the `revision` of the store, and the view model reads `revision` while
  it builds the key. That read is what Observation tracks. If the key does not read it,
  the screen does not update when the ledger changes.

Applies to: `ios/Hasala/Features/Shared/Memo.swift` (`Memo`).

## The wash is drawn behind the scroll view, not in its content

A screen's wash starts at the top of the screen and scrolls away with the content. It is
a background of the scroll view, and `WashPin.offset` moves it up by the distance that the
content has scrolled. It moves only up.

The wash is not a part of the scrolled content. In the content, it went down with a pull,
with the hold of the refresh spinner and with the bounce back, at each moment where the
offset that undid the pull was late. Behind the scroll view, these movements do not carry
it.

Applies to: `ios/Hasala/Features/Shared/ScreenParts.swift` (`WashPin`, `washBehind`),
`ios/Hasala/Features/Shared/TabScreen.swift`.

## A support mail link is followed by the support page

Where the build does not offer an account action, the screen shows a mail link to
support. A mail link does nothing on an iPhone that has no mail account. Thus a link to
the support page follows the mail link, and that page also gives the address. A screen
that already has a link to the support page sets `web: false`.

Without the second link, a person on such an iPhone has no way to ask for an action that
the beta hides. Nothing is sent from the app: a person writes the mail.

Applies to: `ios/Hasala/Features/Shared/SupportLink.swift` (`SupportLink`),
`ios/Hasala/Features/Shared/BuildSurface.swift` (`supportPage`).

## The 12-word entry keeps the words away from the keyboard and clears a pasted phrase

The entry of the recovery phrase follows spec 04 §6.7.

- The keyboard does not correct and does not learn. The field has autocorrection off, no
  capitalization, no content type and the ASCII keyboard. Suggestions come only from the
  recovery word list of the app, in the app's own bar above the keyboard. If the system
  keyboard learns a word, the phrase goes into the keyboard's dictionary.
- "Paste" is the system paste button. iOS then reads the pasteboard one time, on the tap
  of the person, with no prompt.
- After a pasted phrase is accepted, the code that accepts it empties the pasteboard
  (`clearPastedPhrase(changeCount:)`), but only if the pasteboard still holds that paste.
  The app keeps the `changeCount` from the moment of the paste and compares it. An equal
  count means the same contents. The app reads nothing from the pasteboard for this, and
  a write does not show the paste prompt of iOS.
- A typed phrase leaves the pasteboard alone. The app does not empty a pasteboard that
  holds other data of the person.

Applies to: `ios/Hasala/Features/SignIn/PhraseEntry.swift` (`PhraseEntryGrid`,
`clearPastedPhrase`, `PhrasePasteboard`), `ios/Hasala/Features/SignIn/SignInModel.swift`
(`pastedPhraseChangeCount`).
