# iOS account, accounts, activity and bills screens: decisions from the code (2026-11-21)

These decisions were code comments under `ios/Hasala/Features/Account/`,
`ios/Hasala/Features/Accounts/`, `ios/Hasala/Features/Activity/` and
`ios/Hasala/Features/Bills/`. Code comments are not permitted
(`scripts/comment-lint.ts`), thus the decisions are here.

## The server knows no device name, model or place

The server holds no device name, no device model and no place for a device or for a
request. The screens show only what the phone can know:

- The sheet that asks an iPhone to approve a password reset (C9 side A, spec 04 §6.12)
  shows the account's email and how long ago the request was made. It shows no device
  model and no place.
- The rows of Sign-in & security › Devices come from the verified roster. They carry no
  device names from the server.

Do not add a device model, a device name or a location to these screens. The server would
have to collect them, which is a privacy change, and a value that only the server supplies
is not verified.

Applies to: `ios/Hasala/Features/Account/AccountContracts.swift` (`PendingReset`,
`DeviceRow`).

## The frozen wall names the email link unless this app made the freeze

`GET /account` says who froze an account and when. It does not say where the freeze was
made. The beta's only way to freeze is the "Freeze my account" link in our email, so the
frozen wall says that the link was used "from our email" (Paper MTO).

`FreezeInfo.inApp` is true only when this app made the freeze itself, from Sign-in &
security. Then the wall leaves the words "from our email" out. Its default is false.

Do not set `inApp` from a server answer: the server does not have this fact. If a build
offers Freeze in the app, a freeze made on another iPhone still reads "from our email" on
this one. Correct that in the answer of the server first, not in the default.

Applies to: `ios/Hasala/Features/Account/AccountContracts.swift` (`FreezeInfo.inApp`),
`ios/Hasala/Features/Security/FrozenWall.swift` (`holderBody`).

## The account's name and email are cached only in the Keychain binding item

The app shows the account's identity (`AccountProfile`: the display name, the email and
the sign-in method) on Profile and on the Done board. In the live build the name and the
address are cached in the account binding item of the Keychain (`AccountBinding`, spec 04
§4.4, §6.8). They are never written to UserDefaults.

The reason: the binding is deleted together with the session and the keys when the account
leaves the iPhone. A copy in UserDefaults has no Keychain protection and stays after that
delete, so a name and an address would stay on an iPhone that the account left.

Applies to: `ios/Hasala/Features/Account/AccountContracts.swift` (`AccountProfile`),
`ios/Hasala/Live/Account/LiveAccountService.swift`.

## A reset approval checks the code before any Face ID prompt

When an iPhone approves a password reset (C9 side A), `AccountService.approveReset` has a
fixed order:

1. Compare the typed or scanned reset code with the `ek_pub` of the pending request, in
   constant time. The code is the short form of the ephemeral public key of the iPhone
   that asked (`ResetCode`).
2. If they differ, throw `.codeMismatch`. Nothing is approved, and no Face ID prompt shows.
3. Only then, the approval key signs and `password/reset/approve` is sent.

The reason: the code proves that the request on the server is the request of the iPhone in
the person's hand. If the prompt or the signature came first, a person could give Face ID
to a request from another device.

The live service does not carry out this ceremony yet (it throws `.notInThisBuild`). The
code that binds it must keep this order. The mock already refuses a code that does not
match.

Applies to: `ios/Hasala/Features/Account/AccountContracts.swift`
(`AccountService.approveReset`).

## A field's box tap runs with the field's own tap

A tap anywhere in the box of an account field gives the field the focus. The box adds this
tap as a simultaneous gesture. It runs together with the tap of the text field inside. It
never replaces that tap.

The reason: the text field needs its own tap to put the caret where the person tapped. If
the box takes the tap alone (`onTapGesture` or a high-priority gesture), a tap on the text
only focuses the field, the caret cannot be placed, and the UI tests cannot type into the
field.

Applies to: `ios/Hasala/Features/Account/AccountFieldsUI.swift` (`BoxTap`).

## The new-password field is a UITextField, for the password rules

SwiftUI's `TextField` and `SecureField` cannot carry `passwordRules`. A `UITextField` can.
Thus the field for a new password is a `UIViewRepresentable` (`RuledNewPasswordField`). It
hands iOS the rules `minlength: 12; maxlength: 128;` (spec 04 §6.1.2), so that the strong
password that AutoFill suggests is one that Hasala's policy accepts.

Do not replace this field with a SwiftUI field. The rules would be lost and nothing
reports it. Keep the rules string equal to the creation policy (`PasswordPolicy`).

Applies to: `ios/Hasala/Features/Account/AccountFieldsUI.swift` (`PasswordInput`,
`RuledNewPasswordField`).

## Onboarding models belong to the store, not to the views

Each onboarding model (signup, setup, unlock, the interrupted setup) is made and held by
`OnboardingStore`, of which there is one for each process (plan B3). `AccountRootView` and
the flows under it get their models from the store. They do not hold them in `@State`.

The reason: SwiftUI can make the gate view again. The gate changes to the passcode wall
and back when the app returns, and the frozen wall can sit over setup. View state does not
survive these changes. With the models in the store, what the person typed or chose stays.

Do not hold an onboarding model in the state of a view under the gate.

Applies to: `ios/Hasala/Features/Account/AccountRootView.swift` (`AccountRootView`),
`ios/Hasala/Features/Onboarding/OnboardingStore.swift`.

## The lockdown sheet waits for the approval sheet to dismiss

When the person taps "No, that's not me" on the reset approval sheet, the "Let's lock it
down" sheet must follow. SwiftUI drops a sheet that is presented while another sheet of
the same view is still on the screen. Thus the button only sets a flag
(`lockdownAfterApproval`), and the lockdown sheet is presented from the `onDismiss` of the
approval sheet.

If the lockdown sheet is presented directly from the button, it does not show. Then the
person who refused a reset gets no lockdown steps.

Applies to: `ios/Hasala/Features/Account/AccountRootView.swift` (`AccountRootView`).

## The phone never turns an operator freeze into the holder's

Only the operator lifts a freeze that the operator made (spec 04 §6.11). The wall and the
banner offer Unfreeze only for a freeze of the holder.

- The service refuses to unfreeze an operator freeze before any step-up
  (`.frozenByOperator`). The person gets no Face ID or password prompt for an action that
  cannot succeed. The session then records the freeze as the operator's, and the wall
  shows it.
- An operator freeze revokes every session on the server. An unfreeze can thus answer
  `.sessionEnded`. Then this iPhone is signed out and the person signs in again.
- A run can find the account frozen when the server cannot be asked who froze it. With no
  answer, the phone keeps the freeze as it knew it. A freeze that it knew as the
  operator's never becomes the holder's.
- When nothing is known, the freeze counts as the holder's. The holder can then try
  Unfreeze, and the server still refuses an operator freeze.

If a missing answer set the freeze to the holder's again, the wall would offer Unfreeze
for an operator freeze after each run without a connection.

Applies to: `ios/Hasala/Features/Account/AccountSession.swift` (`runFoundFrozen`,
`learnedOperatorFreeze`, `unfreeze`).

## A screen with no way back also has no back swipe

The header of an account screen is the system navigation bar (plan decision 7). A screen
with `AccountBack.system` gets the system back button, its glass and the interactive
swipe from the system.

`AccountBack.none` is for a screen that a person must not leave backward: the account
exists, the step cannot be undone, or the screen is the root of a flow. Such a screen has
no back button and no swipe. Two system behaviours give this:

- A hidden system back button also turns the swipe off.
- A header with no back, no steps and no trailing action hides the whole bar. A hidden bar
  also keeps the swipe from going back.

Do not draw a custom back button over a visible system button for these screens, and do
not enable the pop gesture again. The swipe would take a person back to a step that is
done, for example to a screen from before the account was made.

Applies to: `ios/Hasala/Features/Account/AccountUI.swift` (`AccountBack`, `AccountScreen`,
`AccountHeader`).

## At the accessibility text sizes the actions leave the dock

The account template docks its actions above the home indicator, as Paper draws them. At
the accessibility text sizes it does not. Two wrapped buttons would fill half of the
screen and still clip, because the dock cannot scroll. At these sizes the actions follow
the content and scroll with it (spec 07 §8, plan 0.1 rule 11).

The `actions:` initializer of `AccountScreen` does this. The join screens and the phrase
screens use it. A screen whose dock must stay above the keyboard at every size keeps
`footer:`. The word list of unlock is such a screen.

Use `actions:` for a new account screen that has two actions. With `footer:`, the labels
clip at the accessibility sizes and the accessibility audit of the UI tests fails.

Applies to: `ios/Hasala/Features/Account/AccountUI.swift` (`AccountScreen`,
`ActionsAfterContent`, `DockedActions`).

## A sign-in failure never says which part of a credential was wrong

`AuthFailure` is the failure taxonomy of spec 04 §6.1.5. Each case has one block of copy.
Each case is content-free: it names what went wrong, and it never names which part of a
credential was wrong. A wrong address and a wrong password give the same case
(`wrongCredentials`) and the same copy.

The reason: a failure that says "no account has this address" or "the password is wrong"
tells a stranger which addresses have an account. The server gives one uniform answer, and
the app must not make the difference visible again.

Do not add a case or copy that separates an unknown address from a wrong password, or
that repeats a part of what the person typed for a credential.

Applies to: `ios/Hasala/Features/Account/AuthFailure.swift` (`AuthFailure`).

## Invite code edits apply to the characters, not to the grouped text

The invite field shows the code in groups of four with hyphens. Its state
(`InviteCodeEntry`) is only the code characters and a caret that counts characters (spec 04
§6.1.4).

- Each edit from UIKit (typed, pasted or deleted) is applied to the characters: the
  characters before the range, then those of the replacement, then those after it. The
  grouped text and the caret offset are made again from the characters after each edit.
  Thus typed characters cannot come out in another order, however fast they arrive and
  wherever a hyphen lands. An edit of the grouped text itself does not have this property.
- A delete that covers only a hyphen deletes the character next to it (the one before for
  Delete, the one after for a forward delete). Without this, Delete directly after a
  hyphen does nothing, because the hyphen is made again.
- The field drops only separators and invisible characters: spaces, line breaks, hyphens
  and other dashes, format and control characters. It keeps every other character, also
  one that no code can hold (`1`, `0`, `#`). The person then sees that character, and
  `SignupModel.inviteHint` says that it is wrong. If the field dropped it silently, a code
  with a typing error would only look too short, with no explanation.

Applies to: `ios/Hasala/Features/Account/CredentialRules.swift` (`InviteCodeEntry`,
`InviteCode.entryCharacters`).

## Recurring has no "All schedules" link

The Upcoming header of the Recurring page shows the fact "N tracked" in every build
(`BillsView.trackedFact`). N is `BillsSnapshot.tracked`.

- The Debug surface had a link "All schedules · N" in this header. The screen behind it
  (`AllSchedulesView`, spec 04 §16.2 B1) was never built, so the link only showed the
  toast "Every schedule comes in a later build". The owner decided on 2026-11-25 to
  remove the link and the toast and not to build the screen (issue #316).
- The page already lists the upcoming, paused and ended items, so the count needs no
  destination.
- `ReleaseSurfaceHomeTests` and `ReleaseSurfaceProfileTests` still assert that
  `bills.allSchedules` is absent. Thus the link cannot come back without a decision.

Applies to: `ios/Hasala/Features/Bills/BillsView.swift` (`BillsView.upcoming`,
`BillsView.trackedFact`).
