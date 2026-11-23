# iOS onboarding: decisions from the code (2026-11-21)

These decisions were code comments under `ios/Hasala/Features/Onboarding/`. Code comments are
not permitted (`scripts/comment-lint.ts`), thus the decisions are here.

## The invite code field is a UIKit text view

The invite code field is a `UITextView` behind a `UIViewRepresentable`, not a SwiftUI
`TextField`. The field shows the 24 characters of the code in groups. It takes each edit in
`shouldChangeTextIn`, applies it through `InviteCodeEntry`, sets the grouped text and the
caret itself, and refuses UIKit's own edit. Thus the text and the caret are correct before
the next key arrives.

A SwiftUI `TextField` that grouped its text from `onChange` wrote the text back one render
pass later. By then more keys had landed at a caret that the rewrite then moved, so fast
typing came out in the wrong order. Do not move this field to a `TextField`.

UIKit also changes the text without a call to `shouldChangeTextIn` (dictation is one case).
`textViewDidChange` groups the text again at the caret for these changes. Do not remove it
because `shouldChangeTextIn` refuses each edit: dictated text would then stay ungrouped and
the model would not get it.

Applies to: `ios/Hasala/Features/Onboarding/InviteCodeField.swift` (`InviteCodeField`,
`InviteCodeField.Coordinator`).

## The new-password field is a UIKit field

"Create a password" uses `RuledNewPasswordField`, a UIKit field, not a SwiftUI `SecureField`.
A SwiftUI field cannot carry password rules for AutoFill. The UIKit field gives iOS the
password rules of Hasala (spec 04 §6.1.2), so the strong password that AutoFill suggests is
one that the rules accept. With a SwiftUI field, iOS can suggest a password that "Create
account" refuses.

Applies to: `ios/Hasala/Features/Onboarding/SignupViews.swift` (`CreatePasswordView`),
`ios/Hasala/Features/Account/AccountFieldsUI.swift` (`RuledNewPasswordField`).

## Onboarding drafts stay for the life of the process

Owner requirement 4 (plan B3): what a person did in onboarding stays until the process ends
or the account that it describes is gone. This includes the page of the welcome stories,
each typed field of signup and sign-in, the banks, the connected mailbox, the salary, the
payday, the plan, the notification choice and the replacement phrase of an interrupted
signup. It stays through Back and Forward, a gate that SwiftUI makes again, the passcode
wall, the launch view and a wall overlay.

Thus there is one `OnboardingStore` for each process. The live `BootController` makes it
with its services, and the Debug `MockGraph` makes it with the mock's. `AccountRootView`
passes it down. No onboarding model is made in a `body` or in the `init` of a view, because
SwiftUI makes views again and a model made there loses what the person typed.

Only one event drops the drafts: the phase becomes signed out after a signed-in phase (a
sign-out, an erase, a wipe, a session that the server ended). The account that the drafts
described is gone (plan B3.4). The page of the stories stays. Nothing else drops a draft:
not a wall, the passcode wall, the launch view, a failed sign-in or Back.

If a screen keeps its own model, or if another phase change clears the store, a person who
goes Back or unlocks the phone finds empty fields, and Continue can begin a second signup
or a second mailbox connect.

Applies to: `ios/Hasala/Features/Onboarding/OnboardingStore.swift` (`OnboardingStore`,
`phaseChanged`, `forgetAccountDrafts`).

## The store's lazy models are not observed

`OnboardingStore` makes its setup model, its replacement-phrase model, its unlock model and
its finish-setup model on first use. That first use is in the `body` of the gate. These
properties are `@ObservationIgnored`. A write to an observed property while a `body` runs
changes observed state in the middle of a view update, and the view that reads the property
is drawn again for no reason. Do not remove `@ObservationIgnored` from them, and do not
make these models in an observed property.

Applies to: `ios/Hasala/Features/Onboarding/OnboardingStore.swift` (`setup`, `replacement`,
`unlock`, `finish`).

## An invite link's key proves only the code of that link

An invite link carries a code and a key. The key proves the address that the invite went
to, so a signup with it needs no email code for that address (spec 04 §13.5).

- The model keeps the key until the account is made. A new signup on the link's path (Back,
  then a changed name) sends the key again. Thus the address still needs no code, and the
  "no code" line on About you stays true.
- An edit that makes the code in the field different from the link's code drops the key at
  once. A typed code is never proven by a key that came with a different code.
- The key is dropped when the account is made.

If the key outlives an edit of the code, the app tells the person that no email code is
necessary and sends a key that does not belong to the code. If the key is dropped too
early, a signup that began from a link asks for a code that the screen said was not
necessary.

Applies to: `ios/Hasala/Features/Onboarding/SignupModel.swift` (`inviteText`, `linkKey`,
`linkProvesAddress`).

## Back and Forward never begin a second signup

A signup has one ticket. Continue on About you begins a new signup only when the invite,
the name or the address changed, or the ticket expired. In all other cases the open ticket
carries on where it was: at its email code, or at the sign-in method when the address is
confirmed. The model keeps the invite that the ticket was begun with (`ticketInvite`) for
this comparison.

The model also keeps the ticket for which a passkey was saved (`passkeyTicketID`). Back and
Forward through the method screen do not ask Face ID to save a second passkey for the same
signup.

The reasons: each begin sends an email with a new code and makes the code that the person
already has useless, and each passkey registration leaves one more passkey in the person's
keychain for one account. Do not begin a signup or register a passkey without these checks.

Applies to: `ios/Hasala/Features/Onboarding/SignupModel.swift` (`submitAboutYou`,
`reusableTicket`, `ticketInvite`, `passkeyTicketID`, `passkeyRegistered`).

## The join screens differ from Paper where the facts differ

Three join screens do not agree with the Paper boards. Each difference is on purpose. Do not
change them to agree with Paper.

- **Enter your invite code.** The server's code is 24 letters and numbers. The screen has
  one grouped field in Paper's field style. Paper draws a fixed prefix and four cells, which
  cannot hold the code (plan decision 3).
- **Your invite is ready.** The link carries the code and a key. It does not carry the
  address that the invite went to, or how long the invite lasts. Thus the card says where
  the code came from, and it shows no address and no date, although Paper draws them. The
  copy promises "no code" only for the address that the invite went to, because the key
  proves only that address. The code from a link is never submitted by itself: the person
  taps "Create my account" or "Use a different code".
- **About you.** The person types the email, because the app does not know where the invite
  went. The "Confirmed" chip shows only after a link or a code confirmed the address.

Applies to: `ios/Hasala/Features/Onboarding/SignupViews.swift` (`InviteCodeView`,
`AboutYouView`), `ios/Hasala/Features/Onboarding/Join/InviteReadyView.swift`
(`InviteReadyView`).

## Onboarding copy promises only what the build can do

The lines about the 12 words follow `AccountService.capabilities`. They do not follow Paper
when the build cannot do what Paper says.

- "Why it matters" uses Paper's line (the words alone unlock the data on a new iPhone) only
  with the capability `recoverAccess`. The beta does not have it. There the line says that
  the words unlock the data after the person signs in on the new iPhone (a Release copy
  exception, plan P1).
- "Your account is ready" says that the words can be seen again only with the capability
  `viewPhrase` and a passkey that holds the keys. A passkey that a person adds later on the
  iPhone signs in but holds no keys. Thus a password account is told that the words cannot
  be shown again.
- No line is longer than Paper's line, so the screen still fits above the dock.

If these lines go back to Paper's copy, the app promises a recovery or a second view of the
words that the build cannot give. A person who believes it can lose the data.

Applies to: `ios/Hasala/Features/Onboarding/PhraseViews.swift` (`PhraseIntroView.newIPhone`,
`AccountReadyView.subtitle`).

## The welcome stories and "Who can see what" say what the privacy policy says, or less

Each claim in the welcome stories is one that the design makes and the privacy policy
supports. Each line of "Who can see what" says what `docs/legal/privacy.md` says, or less.

The sheet differs from Paper in two rows. Paper's row for our server leaves out the name,
and Paper's row for Cloudflare leaves out the emails that we send. Our server and Cloudflare
do see these, so the sheet adds them. The mail row names only the providers that the build
can connect: Google alone until Outlook can be connected (plan B4.6 rule 4).

Do not remove a line to agree with Paper. When the privacy policy changes, change the sheet
and the stories with it. A sheet that says less than the truth about who sees what is a
false privacy statement.

Applies to: `ios/Hasala/Features/Onboarding/Join/WhoCanSeeSheet.swift` (`WhoCanSeeSheet`),
`ios/Hasala/Features/Onboarding/WelcomeViews.swift` (`Stories`).

## The welcome stories: pacing, haptics and motion

**Pacing.** Each story plays for 6 seconds, then the pager moves on. It stops after story 4.
The clock runs only while a person can watch the story: not during a drag, not under the
"Who can see what" sheet, not under a pushed screen and not in the background. A paused
clock keeps its time.

The stories do not advance by themselves in these cases: VoiceOver runs, the text is at an
accessibility size, Reduce Motion is on, or the person moved the pager by hand. At the
accessibility sizes the copy of a story fills the screen and takes longer than 6 seconds to
read, so the words would change while the person reads them. In these cases the progress
shows only the page ("Page n of 4"). Do not start the timer again in these cases.

**Haptics.** A swipe or a tap that changes the story plays a selection haptic when it
settles. The key moment of a story plays its haptic only when the person brought the story
there (plan B1.4, `StoryRun.byUser`). The timer never plays a haptic, because the person did
nothing. The haptics stay with Reduce Motion.

**Motion.** The welcome stories are a first-time moment. The owner's motion policy
("delight") lets them keep Paper's spring-deal choreography (spec 04 §3). Thus the timings
in `StoryTiming` are longer than the app's UI motion on purpose. Do not shorten them to the
durations of the design system. With Reduce Motion, each piece fades in place, the pages
cross-fade, nothing turns, nothing counts and the cards do not float.

Applies to: `ios/Hasala/Features/Onboarding/WelcomeViews.swift` (`StoriesView`,
`handPaced`), `ios/Hasala/Features/Onboarding/Join/StoryArt.swift` (`StoryRun`,
`StoryTiming`), `ios/Hasala/Features/Onboarding/Join/StoryClock.swift`.

## The story drawings do not grow with Dynamic Type

The drawings of the welcome stories and the join screens (the background, the orbit, the
slot mark, the app icon tile and the four story stages) are decorative. Their text uses
fonts at a fixed size (`artInter`, `artRounded`, `ArtText`, `ArtFigure`), at Paper's
coordinates in a box 402 points wide. The pager makes the box smaller when the copy needs
the room, and removes it at the largest text sizes.

The drawings do not grow with Dynamic Type, because a drawing is a picture and its layout
breaks when its text grows. The copy next to a drawing carries the words and does grow.
VoiceOver reads each stage as one image with a sentence that describes it, and the other
drawings are hidden from VoiceOver. Do not change these fonts to scaled text styles.

Applies to: `ios/Hasala/Features/Onboarding/Join/OrbitArt.swift` (`artInter`, `artRounded`),
`ios/Hasala/Features/Onboarding/Join/StoryArt.swift` (`ArtText`, `ArtFigure`, `StoryArt`).

## Only the orbit observes the pager's position

The position of the stories pager during a drag is in its own observable object
(`StoryPagerMotion`), not in the state of `StoriesView`. Only the orbit reads it. Thus a
drag draws the orbit again for each frame, and not the full screen. If the position moves
into the state of the screen, each frame of a drag draws the screen again.

Applies to: `ios/Hasala/Features/Onboarding/WelcomeViews.swift` (`StoryPagerMotion`,
`SharedOrbit`).

## The stories pager goes to its page after layout

The page of the welcome stories is kept in the onboarding store, so the pager must open on
that page. SwiftUI does not apply the first id of a scroll position while the pages have no
width. Thus the pager waits until the pages are laid out
(`onScrollGeometryChange`), then scrolls to the page of the store one time, with no
animation. A change between the usual layout and the layout for accessibility text sizes
makes a new pager, so it is put on the page again. Without this step the pager opens on
story 1 while the store says another page.

Applies to: `ios/Hasala/Features/Onboarding/WelcomeViews.swift` (`StoriesView.paged`).

## Small labels scale with the footnote text style

The small uppercase labels in "Who can see what" have a size of 11 points and use the text
style `.footnote` for Dynamic Type. The text style `.caption2` stops its growth early at the
accessibility sizes, so a label with that style stays small while the text around it grows.
Do not change the style to `.caption2` because of the size of the label.

Applies to: `ios/Hasala/Features/Onboarding/Join/WhoCanSeeSheet.swift` (`section`).
