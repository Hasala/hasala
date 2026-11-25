# iOS app, Plan, Profile, Review and Search screens: decisions from the code (2026-11-21)

These decisions were code comments under `ios/Hasala/Features/Plan/`,
`ios/Hasala/Features/Profile/`, `ios/Hasala/Features/Review/` and
`ios/Hasala/Features/Search/`. Code comments are
not permitted (`scripts/comment-lint.ts`), thus the decisions are here.

## Search stays on this iPhone, and recent searches stay in memory

Search finds everything in the ledger that is on the iPhone (`ActivityEngine`, through
`SearchResults`). No query leaves the device. Do not add a search that sends the typed
words to the server or to a cloud model.

The recent searches (`SearchHistory`) live only in the memory of the process. Nothing
about what a person searched is written to disk. They also belong to the open account
only: they are cleared when the account's runtime closes (`BootController.closeRuntime`)
and when the account's data leaves the iPhone (`LocalAccountData.forget`).

A change that persists the list, or that removes one of the two clears, shows one
person's searches to the next person who signs in on the same iPhone.

Applies to: `ios/Hasala/Features/Search/SearchView.swift` (`SearchView`, `SearchHistory`).

## Search results use an empty navigation title

While the search field is empty, Search keeps its large title "Search" over the field
(spec 13 S1). From the first typed letter the results take that room and there is no
large title (S3). In that state the navigation title is the empty string, not "Search".

The reason is a fault of the navigation bar: on a CI simulator the hidden bar left its
large title drawn over the top result. An empty title leaves nothing to draw. Do not put
the title text back for the results state.

Applies to: `ios/Hasala/Features/Search/SearchView.swift` (`SearchView.body`).

## Every figure goes through MoneyText or MoneyPhrase, and only inputs show a real value

Hide amounts must reach every money figure on a screen (spec 04 §12). Thus each figure is
drawn through `MoneyText` or `MoneyPhrase`, and a figure that is set inside a sentence
takes its hidden form and its dot count from `MoneyPhrase` too. A figure drawn as plain
text stays readable when the person hid the amounts.

Two details follow from the same rule:

- An input shows its real value with amounts hidden: the amount field of the budget sheet
  and of Move money. The quick chips that fill the field hide their figures.
- A shortfall is drawn with a leading "−" (U+2212), as `MoneyText` draws a debt. With
  amounts hidden, the sign goes with the figure. A sign that stays tells that the result
  is below zero.

Applies to: `ios/Hasala/Features/Plan/PlanParts.swift`,
`ios/Hasala/Features/Plan/PlanSheetParts.swift` (`PlanAmountField`),
`ios/Hasala/Features/Plan/BudgetEditSheet.swift` (`chips`, `preview`),
`ios/Hasala/Features/Review/ReviewDoneView.swift` (`figure`).

## A budget sheet refuses a move itself, and Ready to assign may go below zero

No toast can show over a sheet. Thus the budget sheet refuses an amount that its source
category does not have on the sheet itself, before anything is sent to the store.

The sheet does not refuse a rise that Ready to assign cannot pay. Ready to assign may go
below zero: that state is the plan asking for more than the income, and Plan shows it
("Lower a budget below to fit your income"). Do not add a refusal for it. It is not a
missing check.

Applies to: `ios/Hasala/Features/Plan/BudgetEditSheet.swift` (`refusal`).

## A fitted sheet sets its detent through UIKit and leaves out the bottom safe area

A medium sheet has one detent, the height of its content. `planMediumSheet` sets that
detent in two ways, and both stay:

- SwiftUI's `.presentationDetents([.height(...)])`.
- `FittedSheetDetent`, which sets one custom detent on the sheet's own
  `UISheetPresentationController`.

The shell presents the budget sheet with `.presentationDetents([.large])` (`MainView`),
and the outer modifier wins over the one inside the sheet. Without the controller the
sheet is large. The controller also takes the bottom safe area off the detent, which
SwiftUI's `.height` alone does not do.

The detent is the content height minus the bottom safe area of the sheet. The content
ignores the bottom safe area and runs into it, with its own 28 pt margin under the
button, so the sheet ends 28 pt under the button as Paper draws it. At the accessibility
text sizes the sheet is large, the content respects the safe area and scrolls clear of
the home indicator. The pick sheet of Review follows the same rule with its own detent:
its content ignores the bottom safe area, and the detent is exactly the content.

The budget sheet sets its draft amount and its source in `init`, not when it appears.
The content then has its final height in the first frame, the sheet is measured one
time, and it does not change size after it rises.

Applies to: `ios/Hasala/Features/Plan/PlanSheetParts.swift` (`planMediumSheet`,
`FittedSheetDetent`), `ios/Hasala/Features/Plan/BudgetEditSheet.swift`,
`ios/Hasala/Features/Review/ReviewPickSheet.swift`.

## A quick chip's target is 46 tall on a medium sheet

A quick chip is drawn 40 pt tall, and its button is 46 pt tall: 3 pt past the drawn chip
above and below (`QuickChip.reach`). The usual 44 pt target is not sufficient there. The
medium sheet that holds the chips is inset, and the system draws it at 386/402 of its
size (`UIDropShadowView` scales it by 0.96). 46 × 0.96 is the 44 pt that a finger needs,
and that the accessibility audit measures.

The extra 3 pt goes into the gaps between the chips and under the stepper. It does not
add to them: the callers subtract `2 * QuickChip.reach` from the line spacing. Do not
lower the target to 44.

Applies to: `ios/Hasala/Features/Plan/PlanSheetParts.swift` (`QuickChip`, `GrowingChipRows`),
`ios/Hasala/Features/Plan/BudgetEditSheet.swift` (`chips`).

## What the accessibility audit and the UI tests need from a view

The UI tests run the accessibility audit on each screen. Three constructs exist only
because of how the audit and XCUITest read a view:

- A pushed Plan screen with no More items adds no toolbar at all. A toolbar with an empty
  item still leaves a zero-sized item in the bar, and the audit reads it as a control
  that is too small to tap.
- A label that is one combined accessibility element gets the static text trait (the
  bucket labels under "Your split"). The audit reads an element with no trait as a
  control that is too small to tap.
- The modifier that drags the review card makes it an accessibility container
  (`children: .contain`). The identifier of the card then names the card and does not
  replace the identifiers of its elements (`review.merchant`, `review.use`), which the
  UI tests use.

Applies to: `ios/Hasala/Features/Plan/PlanParts.swift` (`MoreMenu`),
`ios/Hasala/Features/Plan/PlanView.swift` (`SplitSection`),
`ios/Hasala/Features/Review/ReviewDeckView.swift` (`LiveCard`).

## A layout that reflows keeps the same views

Paper draws many pairs side by side. At larger text sizes the pair stacks. The layout
that does this must lay out the same views in the two arrangements, so that their
identity holds while the text size changes. `SideBySideOrStacked` is a `Layout` for this
reason, the header of the Ready to assign card uses one `AnyLayout`, and the match line
of a rule is one `Text` whose words change.

`ViewThatFits` is not used for this. It swaps in a second copy of the views. VoiceOver
and the accessibility audit see that copy as new text that never grew, because the audit
follows the text node, and the Dynamic Type audit fails. A rule row may use
`ViewThatFits` only below the accessibility sizes.

Whether the match line fits is measured in the face and the size that it is drawn in.

Applies to: `ios/Hasala/Features/Plan/PlanParts.swift` (`SideBySideOrStacked`),
`ios/Hasala/Features/Plan/PlanView.swift` (`ReadyToAssignCard`),
`ios/Hasala/Features/Profile/RulesPage.swift` (`MatchLine`).

## Pace bars fill from empty one time

The fill of a pace bar from empty is an owner rule (B1.3): it must not play on every
appearance.

- Plan: the slim bars fill from empty the first time Plan appears in the process. After
  that they show where they are.
- A category's month: the bar fills one time for each push (300 ms). The figure rolls
  with it, then the tick drops in and the verdict fades in. A return from a sheet or
  from another tab shows the bar as it is.
- In the two places a changed budget moves its bar with `.fillUpdate`. It does not play
  the fill from empty again.

Do not start the reveal from `onAppear` without this guard.

Applies to: `ios/Hasala/Features/Plan/PlanView.swift` (`reveal`),
`ios/Hasala/Features/Plan/CategoryDetailView.swift` (`CategoryHero`).

## The review card flies out at an even pace

A filed review card travels and turns on a linear curve over the 200 ms of `.cardCommit`,
and fades on ease-in-out. It does not use ease-out-soft.

The card always leaves from rest (it is held toward its pill, or it is still for "Use").
From rest, ease-out-soft covers 60% of the way in the first two frames, and the card was
gone before a person saw it. At an even pace the card is readable for about eight frames
before it clears the screen, and the fade keeps it solid at the start. A skip, and every
card with Reduce Motion, only fades in place.

Applies to: `ios/Hasala/Features/Review/ReviewDeckView.swift` (`FlyingCard.fly`).

## Bank alerts has a row in Settings as well as its card

Your profile shows the mailbox two times: the Bank alerts status card at the top, and a
Bank alerts row under Settings. The two open the same page, with the sign-in and
Disconnect.

The row is not a duplicate to remove. Settings is where a person looks to stop Hasala
reading their email, and that control must be easy to find.

Applies to: `ios/Hasala/Features/Profile/ProfileSheet.swift`.

## The review cover's route carries the start card, and its id is constant

The card where a review session starts is the payload of the route
(`CoverRoute.review(start:)`). The cover makes its session from the route
(`CoverRoute.session(for:)`). Do not keep the start card in static state or in the
model: the request then outlives the navigation state that made it (issue #322).

All review routes have the same `id`. SwiftUI closes and presents a
`fullScreenCover(item:)` again when the id of its item changes. A start that arrives
while the deck is open (a widget link, a second tap) must not do that, so the payload
is not part of the id. The open deck keeps the session it has.

A Debug screen that drives the deck uses `CoverRoute.scriptedReview`. Its `ReviewScript`
runs one time, on the first session that the route makes. SwiftUI can build the cover's
view more than one time, and the steps write to the ledger.

Applies to: `ios/Hasala/App/Routes.swift` (`CoverRoute`),
`ios/Hasala/Features/Review/ReviewModel.swift` (`CoverRoute.session(for:)`, `ReviewScript`),
`ios/Hasala/Features/Shell/MainView.swift` (`ReviewCover`),
`ios/Hasala/App/Debug/ScreenLaunch+Activity.swift` (`startDeck`).

## Accepted differences from the Paper design

The app must agree with the Paper design. These differences are accepted:

- Sign out in Your profile is the kit's 54 pt pill. Paper draws 52, which is not a height
  of the pill set.
- Start on the Review tab is the kit's Large pill, 54 pt. Paper draws 50, which is not a
  height of the pill set.
- Paper draws no Get help page. The page is built from the parts of the profile: a white
  card of rows on the grey of the large sheet.

Do not add a pill height to the kit for one of these buttons.

Applies to: `ios/Hasala/Features/Profile/ProfileSheet.swift` (`footer`),
`ios/Hasala/Features/Review/ReviewTabView.swift` (`startCard`),
`ios/Hasala/Features/Profile/ProfilePages.swift` (`HelpPage`).
