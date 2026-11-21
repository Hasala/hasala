# iOS Home and Mailbox screens: decisions from the code (2026-11-21)

These decisions were code comments under `ios/Hasala/Features/Home/` and
`ios/Hasala/Features/Mailbox/`. Code comments are not permitted
(`scripts/comment-lint.ts`), thus the decisions are here.

## Home's launch reveal keeps its own sequence

The hero's first reveal after launch follows the owner's motion policy (B1.3). The bar
fills in 300 ms and the figure rolls with it. The today tick drops in as the bar lands
(120 ms). Then the verdict fades in (150 ms). The steps start at 0, 300 and 420 ms and
the last one ends at 570 ms.

The reveal plays one time for each process. Home is seen many times a day, so each later
appearance, a tab switch and a return from a sheet show the final state at once. Reduce
Motion and settled motion also show the final state. A change while Home is open moves
the bar on `fillUpdate` (250 ms) and does not play the reveal again.

The three animations start together. The tick and the verdict have delays. Do not start
a step from the completion of the step before it. A frame trace of a launch with that
design put the tick at 375 ms and the verdict at 540 ms. With delays, the render clock
keeps the spacing, whatever the main thread does.

Home does not use the design system's `paceFillSequence` for the launch, although that
modifier starts its steps in the same way (requests/p5.md 4). Home's fill waits for the
first frame to be on screen (`DisplayFrame.next`). A display link callback that is asked
for while a frame is built comes after that frame is committed. Thus the work of the
launch cannot take the first frames of the fill. If Home changes to `paceFillSequence`,
the start of the fill can be lost at launch.

`SmokeTests` holds the 0–300–420–570 sequence through `RevealTimingProbe` (Debug only,
`-HasalaRevealTiming`). The app times its own frames, because an XCUITest query takes
longer than the 120 ms tick. The probe times frames, not state. It calculates the start
of the fill from the first frame that moves, because an animation starts when it is first
drawn, which can be some time after the state change.

Applies to: `ios/Hasala/Features/Home/HeroReveal.swift` (`HeroReveal`, `DisplayFrame`),
`ios/Hasala/Features/Home/HomeHero.swift` (`HomeHero`),
`ios/Hasala/Features/Home/Mocks/RevealTimingProbe.swift` (`RevealTimingProbe`).

## The hero figure trims its line to Paper's 58 pt

The hero figure is 56 pt bold and Paper puts it on a 58 pt line. The line of SF Rounded
at 56 pt is approximately 66.6 pt (56 × 1.19). The design system can add leading, but it
cannot remove leading. Thus `HeroFigure` gives a negative vertical padding of 4.32 pt,
which is half of 56 × 1.19 − 58. The trim scales with the text size, and it has the same
AX3 limit as the figure.

A hidden figure gets no trim, because its six 38 pt dots are on the 58 pt line already.
If the size or the face of the figure changes, calculate the trim again. Without the
trim, the hero is approximately 9 pt taller than Paper's.

Applies to: `ios/Hasala/Features/Home/HomeHero.swift` (`HeroFigure`).

## A sheet does not present a second sheet

A sheet never opens a second sheet. A bell row closes the Notifications sheet first. A
destination that can open below a sheet that closes (a tab, a push, the next sheet)
opens at once. `AppRouter.open` puts the Profile sheet, with Bank alerts pushed in it, in
a queue behind the bell's sheet. A destination that needs the sheet to be gone (the
review cover) comes back from `HomeModel.openNotification` as a closure, and the sheet
runs it after it closed.

For the same reason, the connect screen of the profile is a page pushed in the profile
sheet, not a sheet over it. Then a password step-up can present over that page. If a
change presents these screens as sheets from a sheet, the step-up and the review cover
have no place to present.

Applies to: `ios/Hasala/Features/Home/HomeModel.swift` (`HomeModel.openNotification`,
`HomeViewModel`), `ios/Hasala/Features/Home/NotificationsSheet.swift`,
`ios/Hasala/Features/Mailbox/ConnectMailPage.swift` (`ConnectMailPage`).

## A connect from the profile asks for the banks first

An account can have no bank yet (manual entry, or bank texts set up with no bank list).
When such an account connects a mailbox from the profile, the screen asks "Which bank do
you use?" before the provider's screen, as setup does before its email step. Continue
sends the same bank ops as setup's step.

The reason is that the mail lane reads only the alert senders of the chosen banks. With
no bank, the lane reads nothing, and the provider's screen lists no bank. Do not move
the connect before the bank step, and do not remove the step for these accounts.

Applies to: `ios/Hasala/Features/Mailbox/ConnectMailPage.swift` (`ConnectMailPage`,
`MailBanksStep`).

## Setup's connect screen never starts a second sign-in

In setup, Back from the first scan goes to the connect screen. That screen then shows
the connected mailbox and "Continue" (`mail.continue`). It does not show the provider's
sign-in again (plan B3.2 rule 2). `MailConnectCoordinator.connectedMailbox` reads the
mailbox from the service, so a relaunch that finds the lane linked shows the same screen.

Only the setup context carries a connect over from before the screen. In the profile, a
second mailbox of the same provider is a real new connect, so the profile context shows
the sign-in. If the setup context loses this rule, a person runs a second sign-in and a
second step-up for a mailbox that is linked already. If the profile context gets this
rule, a person cannot add a second account of one provider. `MockMailbox.connectCalls`
lets the tests count the sign-ins.

Applies to: `ios/Hasala/Features/Mailbox/MailConnectCoordinator.swift`
(`connectedMailbox`), `ios/Hasala/Features/Mailbox/ConnectProviderView.swift`
(`ConnectProviderView`).

## Release copy does not promise the new-mail wake

Paper's caption below the read-only card says that our server is told when new mail
arrives. Paper's detail below the Mailboxes card says that the server sees when mail
arrives. The comments recorded that a Release build relays no new-mail push. Thus the
Release surface uses different sentences: new alerts are checked when the person opens
Hasala and sometimes in the background, and the server never sees the mail. Only the
Debug surface (`BuildSurface.showsUnfinished`) keeps Paper's sentences.

The rule is that the copy makes no promise that the beta does not keep. The live lane
sets a Gmail watch or a Graph subscription only when `/meta` gives the push settings.
Change the Release sentences to Paper's only when the release build and the release
server relay wakes for each account. The caption has two lines, as Paper draws it, so
the screen fits above its dock.

Applies to: `ios/Hasala/Features/Mailbox/MailParts.swift` (`MailCopy.readNote`,
`MailCopy.mailboxesFootnoteDetail`).

## The success haptic plays when the motion settles

The success haptic of a new or repaired mailbox plays when its motion comes to rest, not
when the motion starts (the owner's motion policy; spec 01 §4.11). Thus the code waits
for `MotionPolicy.settleDelay(kind)` and then increments the count that triggers the
haptic. The wait is zero when the policy shows the change at once.

This wait is the design, not a workaround. If a change removes it, the haptic plays
before the row lands or before the page changes.

Applies to: `ios/Hasala/Features/Mailbox/MailParts.swift` (`MotionPolicy.settleDelay`),
`ios/Hasala/Features/Mailbox/BankAlertsPage.swift` (`land`, `signInAgain`),
`ios/Hasala/Features/Mailbox/MailboxDetailPage.swift` (`signInAgain`).

## The read-only card uses a 9 pt gap, not Paper's 10

The rows of the "Hasala reads / Never" card have a 9 pt gap between the badge and the
text. Paper's gap is 10 pt. On iOS, Inter sets the longest line of the card 0.6 pt wider
than the 300 pt that a 10 pt gap leaves on a 402 pt screen, and the line then breaks in
a different place. The 9 pt gap keeps Paper's line breaks. It also keeps the screen 20 pt
shorter, so the caption does not go below the dock.

Do not change the gap to 10 to agree with Paper. Examine the line breaks on a 402 pt
screen if the copy, the face or the padding of the card changes.

Applies to: `ios/Hasala/Features/Mailbox/MailParts.swift` (`ReadsNeverCard`).

## Mailbox parts that the accessibility audit shaped

The UI tests do the accessibility audit at the default text size and at
`.accessibility3`. Three constructions in the mailbox screens exist because of an audit
finding. A change that removes one of them brings the finding back.

- `TextLinkLabel` draws the sentence and its link as one text of two runs. Two texts
  side by side, or a switch between layouts that fit, made the audit report text that
  stops growing with Dynamic Type. Up to the large sizes, no-break spaces hold the words
  of the link together, so the link goes to the next line as a whole, as Paper's row
  does. At the accessibility sizes it wraps word by word, because its words can be wider
  than one line.
- `dockPill()` gives a pill in the dock of an account screen the height that its label
  needs. The dock does not scroll. A label with less height than it needs was cut at
  AX3, where the provider's button takes two lines, and the audit reported "Text
  clipped".
- `MailboxFactRow` combines its key and its value into one accessibility element with no
  value. A label with a value reads as a control to the audit, and the audit then
  reports that its 20 pt text is too small to tap. The row is text, not a control.

Applies to: `ios/Hasala/Features/Mailbox/MailParts.swift` (`TextLinkLabel`, `dockPill`),
`ios/Hasala/Features/Mailbox/MailboxDetailPage.swift` (`MailboxFactRow`).

## The screens use the app's own mailbox contract

The mailbox screens use a contract that belongs to the app and does not name a provider
library (`MailboxConnecting`, `MailboxSnapshot`, `MailProviderKind`; plan B4.3). The
views do not import `CoreMailbox` and do not use its `MailProviderID`. The mapping from
the contract to the mail lanes is only in `ios/Hasala/Live/Mailbox/`. The mock
(`MockMailbox`) implements the same contract, so Debug scenarios, previews and UI tests
run the same screens.

No lint enforces this rule. If a view starts to use `CoreMailbox` types, the mock can no
longer stand in for the live lane.

The contract also sets the words. Lists and settings say "mailbox". Steps and buttons
say "your email".

Applies to: `ios/Hasala/Features/Mailbox/MailboxContracts.swift`.

## The live build holds one mailbox link for each account

The live server holds one mail link for each account. Thus the live lane and the Release
surface never have the `.addSecond` capability, and "Add a mailbox" beside a mailbox
that works shows only in the mock. They have `.replace`: a connect of another provider
replaces the link, and the server swaps it in one step. The swap occurs only after the
person confirms it in the system alert "Change your email?". Without the confirmation
the connect fails and the link stays.

Paper's boards with two mailboxes are true only for the mock. Do not give `.addSecond`
to the live lane until the server can hold a second link.

Applies to: `ios/Hasala/Features/Mailbox/MailboxContracts.swift`
(`MailboxCapabilities`, `holdsOneLink`).

## A mailbox that another iPhone reads is not changed from this iPhone

When another iPhone reads a mailbox of the account, this iPhone holds no sign-in for it.

- The mailbox page shows no Disconnect for it. The server's delete of the link would
  stop the reading on the other iPhone. The page says where to disconnect: on that
  iPhone, or in the provider's own settings.
- Bank alerts does not offer "Use another email", and `replaced(by:)` gives no mailbox,
  because this iPhone cannot switch that link (the connect is refused).

A takeover is a different case. When this iPhone reads nothing and the server still
names an earlier iPhone (a new install or a recovered account), a connect takes the link
over after the person confirms it in a system alert. The server cannot tell if the
person still has the other iPhone. Thus the copy of the alert covers the two cases
("maybe one you no longer have").

Applies to: `ios/Hasala/Features/Mailbox/MailboxDetailPage.swift` (`disconnect`),
`ios/Hasala/Features/Mailbox/BankAlertsPage.swift` (`offersChange`),
`ios/Hasala/Features/Mailbox/MailboxContracts.swift` (`replaced(by:)`),
`ios/Hasala/Features/Mailbox/MailParts.swift` (`MailCopy.takeoverMessage`).
