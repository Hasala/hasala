# HasalaKit ledger models and tests: decisions from the code (2026-11-21)

These decisions were code comments under `ios/HasalaKit/Sources/HasalaModels/Ledger/` and
`ios/HasalaKit/Tests/HasalaKitTests/`. Code comments are not permitted
(`scripts/comment-lint.ts`), thus the decisions are here.

## A ledger store changes `revision` with each change of `state` or `now`

Each `LedgerStore` changes its `revision` each time its `state` or its `now` changes. A
change of the clock alone (for example a new day) counts too, because the engines read
`now`.

The reason: a screen keeps the snapshot that an engine made and uses `revision` as its key
(spec 04 §18.3). Thus an engine runs one time for each change of the ledger, not one time
for each read. The reader's side of this rule is "Memo stays outside Observation, and its
key reads the store's revision" in
`docs/decisions/code/ios-hasala-features-security-to-signin.md`.

If a store changes `state` or `now` and does not change `revision`, the screens continue
to show the old snapshot. A new store, and each new code path that sets `state` or `now`
in a store, must obey this rule.

Applies to: `ios/HasalaKit/Sources/HasalaModels/Ledger/LedgerStore.swift`
(`LedgerStore.revision`), `ios/Hasala/Live/Ledger/LiveLedgerStore.swift`,
`ios/HasalaKit/Sources/HasalaMocks/InMemoryLedger.swift`.

## The Bills chip on Activity counts the payments in the data, not the number on the board

Paper's Activity board draws "Bills 8". The data of that same board has six payments in
the month that are linked to a bill. Spec 03b §12 #1 leaves the definition of this count
open, and the read in 03b §7 counts the linked payments. Thus the chip shows the number of
payments that the Bills filter lists, which is six in the Maya ledger.

Do not change the expectation to 8 to agree with the board. The chip and its list would
then disagree. Change the count only when the owner changes the board or the definition
in 03b.

Applies to: `ios/HasalaKit/Tests/HasalaKitTests/ActivityReviewEngineTests.swift`
(`theBillsChipCountsPaymentsLinkedToABill`),
`ios/HasalaKit/Sources/HasalaModels/Engines/ActivityEngine.swift`
(`ActivityEngine.snapshot`, `isBill`).

## Text contrast is a unit test on the tokens, because the accessibility audit cannot judge it

Text must have a contrast of 4.5:1 or more on each surface, washes included (spec 04 §17).
`ContrastTests` is the gate for this rule. It lists each text colour on each surface on
which the screens draw it, and it computes the WCAG 2.x ratio exactly from the tokens. A
translucent colour is first composited over the surface below it.

The accessibility audit of the UI tests cannot be this gate. The audit samples rendered
pixels. Under the scroll-edge blur and the glass bars, it fails primary ink on the grey
canvas, and the real ratio of that pair is more than 14:1. Thus the UI tests leave
contrast out of the audit.

The results of a change:

- If somebody deletes `ContrastTests` because "the audit does it", nothing checks contrast.
- If somebody adds contrast to the audit again, the UI tests fail on correct screens.
- When a screen draws a text colour on a new surface, add that pair to `ContrastTests`.
  Nothing else finds a pair that is not in the list.

Applies to: `ios/HasalaKit/Tests/HasalaKitTests/ContrastTests.swift` (`ContrastTests.pairs`),
`ios/HasalaUITests/UITestSupport.swift` (the accessibility audit).

## Motion durations are the owner's values, not the values on page 04

The durations, springs and distances in `HMotion` follow the owner's motion policy of
15 October 2026. That policy replaces the longer "Proposed for app" values on page 04 of
spec 01. The policy document is not in this repository.

The policy says that UI animations stay under 300 ms. Only fills and counts are as long as
300 ms. Only the first-time moments (the Welcome deal-in, a celebration) and the one idle
loop are longer.

`MotionTests` pins each value. Do not change a value to agree with page 04. A value
changes only when the owner changes it on purpose, and then the test changes in the same
commit.

Applies to: `ios/HasalaKit/Tests/HasalaKitTests/MotionTests.swift`,
`ios/HasalaKit/Sources/HasalaDesign/Foundation/Motion.swift` (`HMotion`, `MotionPolicy`).

## Inter keeps automatic optical sizing

Paper sets Inter with automatic optical sizing. Core Text does the same for a font that
has an `opsz` axis, so each size gets its own cut and a title takes the display cut. The
app uses this behaviour as it is.

The reason is the width of the titles. The headline of welcome story 4 is approximately
353 pt wide at the large title size, and its column is 354 pt. With Inter's text cut
(optical size 14) the same headline is approximately 376 pt wide, and it wraps. Body text
is within 1.5% of the width of the text cut, so body text does not change.

Do not set the `opsz` axis to a fixed value, and do not replace the variable font with
static instances of the text cut. The titles would become wider, and their line breaks
would not agree with the boards. `titlesTakeTheDisplayCut` measures these widths.

Applies to: `ios/HasalaKit/Tests/HasalaKitTests/TokenTests.swift`
(`titlesTakeTheDisplayCut`), `ios/HasalaKit/Sources/HasalaDesign/Foundation/Fonts.swift`
(`HasalaFonts`).
