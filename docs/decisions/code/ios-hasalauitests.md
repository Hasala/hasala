# iOS UI tests: decisions from the code (2026-11-21)

These decisions were code comments under `ios/HasalaUITests/` and in `ios/project.yml`.
Code comments are not permitted (`scripts/comment-lint.ts`), thus the decisions are here.

## The shared accessibility audit: what it does not count, and when it runs

Each UI test audits each screen that it reaches with the system accessibility audit
(`performAccessibilityAudit`, spec 04 §17). All tests use one helper, `audit`. A finding
fails the test and names its element.

The helper does not count these findings:

- Clipped text at the default text size. At that size the audit can only predict that
  text "may be clipped at larger Dynamic Type sizes". Paper sets one-line text, and the
  layouts let that text wrap above the default size. The tests at `.accessibility3`
  (`atLargeText: true`) check clipping at the size where it is decided.
- Clipped text in the system search field, at every size. The system lays out that field
  and sizes its text.
- Contrast. The audit samples the pixels on the screen. Under the scroll-edge blur and
  the glass bars it fails ink on the grey canvas, a pair with a ratio above 14:1. Thus it
  cannot be a gate. `ContrastTests` in HasalaKit checks each pair of a text token and a
  surface token exactly.
- "Dynamic Type partially unsupported" on the figures that stop growing at
  `.accessibility3` on purpose (spec 04 §14.4). These figures have the identifier
  `hasala.cappedFigure`.
- "Dynamic Type partially unsupported" on text in the navigation bar and the tab bar. The
  bars keep their size and offer the Large Content Viewer, as system bars do.
- The keyboard and its prediction bar. iOS lays them out. The prediction bar is three
  empty cells (`TUIPredictionViewCell`, "Element has no description") along the top edge
  of the keyboard. On iOS 27, autocorrection off on the field does not remove them. The
  helper skips only elements with no label in the 44 pt band at the top edge of the
  keyboard. The app's own controls just above the keyboard (a dock, the word list) are
  still audited. Do not make the band larger, and do not skip an element that has a label.
- A finding with no element while content is scrolled under the header. Labelled text
  there shows faintly through the scroll-edge blur of the bar. The audit reads those
  pixels as text that it cannot match to an element ("Potentially inaccessible text"),
  and the result depends on which glyphs the blur lets through. Each screen is also
  audited at the top, where nothing is under the header, so text with no element is
  still found there. Keep one audit at the top of each screen.
- With `overSheet`, a finding with no element while a sheet that fits its content is up
  (setup's "Choose your email"). The page behind shows above the sheet. It is dimmed and,
  correctly, not in the accessibility tree, so the audit reads its text as text with no
  element. The test audits that page alone before the sheet opens. A finding that names
  an element of the sheet still fails.

The audit runs only when the screen is still (`waitForStill`: two snapshots of the
hierarchy in a row have each element in the same place). When it reports findings, it
runs again. Only findings that a second audit of the same still screen reports again
fail the test.

The reason is that the audit changes the text size while it runs. If the content still
moves (a tab or sheet transition, a scroll that coasts, an animation of a figure, a toast
that leaves), the audit sees text change place. It then reports text in motion as clipped,
or reports Dynamic Type as "partially unsupported" on text that does scale, the title of
the page included. This was seen on a slow CI runner. A real defect is reported again on
a still screen. On a slow runner the audit can also stop with "Audit failed to complete
in time" (code -56 in `com.apple.xcode.xctest.accessibilityAudit`). It gets three tries.

Two rules for a test follow from this:

- A helper that drags a page before an audit holds each drag before the finger lifts. A
  fling that still coasts gives false "clipped" findings.
- The audit can move the scroll position. A test that audits down a long page scrolls to
  its own element before each audit. It does not continue from where the last audit
  stopped.

Do not remove the wait or the second audit to make the tests faster. The false findings
come back. Do not add an exclusion unless a different test checks the excluded property.

Applies to: `ios/HasalaUITests/UITestSupport.swift` (`audit`, `auditIssues`,
`waitForStill`, `contentUnderHeader`), `ios/HasalaUITests/ProfileUITests.swift`
(`bringUp`), `ios/HasalaUITests/SmokeTests.swift` (`testAccessibilityAtLargeTextSizes`).

## Local exceptions to the accessibility audit

Four places in the UI tests do not use the plain audit. Each one has a reason and a
proof. Do not copy an exception to a different screen.

- **The "Ready to assign" overline on Plan at `.accessibility3`.** At the top of Plan the
  audit reports this overline as text that may be clipped at larger sizes. The overline
  is not clipped. It wraps. `testReadyToAssignWrapsAtTheLargestSize` is the proof: at the
  largest size the overline takes two lines. Thus `testPlanAtLargeTextSizes` runs all
  checks except clipped text at the top of Plan. Then it runs the clipped-text check
  alone, and lets through only the element with that label. All other clipped text still
  fails. Do not delete the wrap test while this exception stays.
- **The Dining budget sheet in `testPlanMoveMoneyAndBudget`.** This test opens the sheet
  from a page that is scrolled down, and does not audit the sheet there. From that
  position, rows behind the scrim are across the edge of the sheet, and the audit reads
  their cut words as text that no element describes.
  `testABudgetRiseCanComeFromAnotherCategory` audits the same sheet over the top of
  Dining, where Paper draws it.
- **The Day by day chart.** The chart is one accessibility element with a summary. The
  audit cannot examine its parts. For the labels at AX3 and AX5, the attached
  screenshots are the check. The test asserts only that the chart stays on the screen
  and grows by the height of its key. After a change to the chart, a person must look at
  the screenshots.
- **"Confirm it's you" over Sign-in & security** (a fitted sheet over the large sheet of
  the profile). Over that page the audit reports "Potentially inaccessible text" with no
  element. The accessibility tree gives the elements of the sheet frames of
  approximately 0.9 of their drawn size, so the text that the audit finds and the
  elements do not align. Each element of the sheet is in the tree with its label (the
  test asserts the title and the line). The same sheet over the password page passes the
  plain audit. Thus `auditOverThePage` lets findings with no element through, in this
  place only. A finding that names an element still fails.

Applies to: `ios/HasalaUITests/PlanUITests.swift` (`testPlanAtLargeTextSizes`,
`testReadyToAssignWrapsAtTheLargestSize`, `testPlanMoveMoneyAndBudget`,
`testABudgetRiseCanComeFromAnotherCategory`,
`testDayByDayKeepsItsLabelsOffTheBarsAtLargeSizes`),
`ios/HasalaUITests/SignInSecurityUITests.swift` (`auditOverThePage`).

## UI test waits and gestures allow for a slow CI runner

The shared helpers of the UI tests are slower than the simplest XCUITest calls. Each
difference comes from a failure that was seen on a loaded CI runner. Do not make a
helper simpler to save time.

- **The default wait is 15 s (`uiWait`), not 5 s.** On a loaded runner, one snapshot of
  the hierarchy can take seconds. A 5 s wait can end after one or two looks at a screen
  that has not arrived yet. This was seen with the saved note of a sheet and the verdict
  of the split sheet.
- **A tap that must open something gets one more try** (`tap(_:_:opening:)`). A slow
  runner can swallow a tap that lands while the keyboard leaves or the page settles. The
  second tap occurs only while the tapped element is still on the screen.
- **A field is tapped until it has the keyboard focus** (`type(_:into:)`, three tries). A
  tap that lands while a sheet settles, or while the app is busy, can leave the field
  with no focus. `typeText` then fails with "Neither element nor any descendant has
  keyboard focus".
- **A page is moved with a drag that rests, not with `swipeUp()`** (`dragUntilHittable`,
  `scroll(_:toShow:)`, `reveal`). A fling leaves the page in motion after the gesture. A
  tap that lands while the page moves only stops the scroll, and the row does not open.
  This was seen at large text sizes. Each drag holds before the finger lifts, so the page
  stops where the drag put it. The drag starts in the middle of the screen, above the
  position of a keyboard. After a drag, `dragUntilHittable` waits until the page is
  still. A drag past the end of the page springs back when the finger lifts, and a tap
  during that bounce only stops it (seen on "about.continue" at large text).
- **A new mailbox is checked on its row, not on the toast** (`assertMailboxAdded`). The
  row on Bank alerts reads Syncing or Connected. The toast "… connected. Checking for
  alerts." leaves after 4 s, and the waits of a slow runner can last longer than that.
  `AppModelTests` checks the words of the toast.

Applies to: `ios/HasalaUITests/UITestSupport.swift` (`uiWait`, `tap`, `type`,
`dragUntilHittable`, `scroll`, `reveal`, `assertMailboxAdded`).

## A split handle is dragged by a step that comes from the width of the bar

`nudge` drags a handle of the starting split sideways, as a finger does. One step is 5%.
The app computes the track as the width of the bar minus the two 20 pt handle slots
(`SplitHandles.slot`, `splitHandleSlot` in the tests) and snaps the handle to the nearest
5%, so one step is a twentieth of the track. `nudge` reads the width of the bar
(`plan.split.bar`) from the hierarchy and drags by exactly that step, to the middle of the
range that snaps to it. The drag does not depend on the width of the screen or on the
margins of the bar. A fixed 17 pt for each step was correct only for a 322 pt track, on a
screen 402 pt wide.

The bar is an accessibility container (`children: .contain`), so its identifier names the
bar and does not replace the identifiers of the handles (`plan.split.handle.0`,
`plan.split.handle.1`).

Applies to: `ios/HasalaUITests/UITestSupport.swift` (`nudge`, `splitHandleSlot`),
`ios/Hasala/Features/Setup/SplitHandles.swift` (`SplitHandles`).

## Live end-to-end tests: the harness contract, the order and the scope

`LiveE2ETests` run the Debug app against a local `hasalad`, on two simulators, A and B.
The harness is `ios/scripts/e2e-app.sh`.

- **The order is fixed.** The harness runs one test for each
  `xcodebuild test-without-building` call, in the order of the test names. Each test
  builds on the tests before it: E1 makes the account that all later tests use. Do not
  change the order, and do not run these tests in parallel or alone.
- **The environment names have two forms.** The harness sets
  `TEST_RUNNER_HASALA_E2E_*`. `xcodebuild` removes the `TEST_RUNNER_` prefix, so the test
  runner reads `HASALA_E2E_*`. Without `HASALA_E2E_API`, each live test is skipped, so a
  plain `xcodebuild test` of the UI tests is not affected. The result is that a wrong
  name in the harness makes the live tests skip. They do not fail. Keep the names in the
  harness and in `LiveE2EEnvironment` the same.
- **The test runner does not call the server.** The emailed codes, the account that E1
  makes, the wake requests and the op log position go through files in the temporary
  directory of the harness. The processes of the simulator can read and write that
  directory.
- **E2 waits for its upload.** The test writes `oplog-request`, and the harness answers
  with the number of rows in `op_log` in `oplog-position` (`oplog-failed` when the query
  fails). E2 reads the position before it sorts the card, and then it reads again until
  the position is larger, for 60 s at most. E2 fails when it is not, so E3 does not start
  with the edit still in the outbox of B. The server cannot read an op, thus a larger
  position proves that B uploaded a batch after the read. It does not prove which op the
  batch has.
- **Passwords only.** A passkey needs the real relying party (`hasala.app`), and a local
  server cannot be that. Gmail and the full chain from mail to upload, pull and replay
  are tested in the core (`HasalaCoreE2ETests`). In these tests, the data is the sample
  of the review account.

Applies to: `ios/HasalaUITests/LiveE2ESupport.swift` (`LiveE2EEnvironment`,
`LiveE2ECase`, `oplogPosition`, `waitForUpload`), `ios/HasalaUITests/LiveE2ETests.swift`
(`LiveE2ETests`).

## Live end-to-end tests: a simulator push needs notification permission

The simulator delivers a push only when the push has visible content, and only to an app
for which the user allowed notifications. Thus `ios/scripts/e2e/wake.apns` has an alert
together with `content-available`, and E1 allows notifications on simulator A. A
reviewer taps "Not now" there. The test does not, because E3 needs the push.

The permission alert does not always show on a new simulator. The request then never
returns. `allowNotifications` taps "Allow notifications" again until the alert shows,
because a tap that lands while the step still slides in is lost. After 30 s it answers
"Not now", and the run records that notifications are not allowed.

Without the permission, the simulator refuses each push to the app (`UNErrorDomain`
2003). E3 reports that refusal as an expected failure (`XCTExpectFailure`). It is shown
in the report, and it is not a pass of the push. When notifications were allowed and the
push is refused, E3 fails.

There is one known limit. The pull of E3's own sign-in can bring the card that B sorted
before the push arrives. Thus E3 proves that the push was accepted and that the figures
are correct after it. It does not prove that the wake brought the change.

Applies to: `ios/HasalaUITests/LiveE2ESupport.swift` (`allowNotifications`,
`requestWake`, `notificationsAllowed`), `ios/HasalaUITests/LiveE2ETests.swift`
(`test01_pathB`, `test03_rebind`).

## The reveal timing test holds the order exactly and the times loosely

`testTheFirstRevealKeepsItsTimingWithAmountsShown` reads the marks that the app stamps
for the first reveal of Home (`-HasalaRevealTiming`). The sequence itself (0, 300, 420
and 570 ms) is in "Home's launch reveal keeps its own sequence" in
`docs/decisions/code/ios-hasala-features-home-to-mailbox.md`.

The marks are frames that the app drew, in milliseconds from the frame on which the fill
started. A frame is 17 ms. A CI runner that drops some frames can stamp one mark late and
the next mark on time. The gap between the tick and the verdict was seen at 85 ms, not
120 ms.

Thus the test holds the order of the marks exactly (fill, tick, verdict, end), and each
gap and each bound allows some frames. The fill ends between 250 and 360 ms. The tick
comes at or after the end of the fill, and by 400 ms. The verdict comes 50 ms or more
after the tick, and by 510 ms. The reveal ends by 620 ms, near the owner's limit of
600 ms. Do not set the bounds to the nominal values: the test then fails on a busy
runner. Do not remove the order checks: they are the part that finds a real regression.

Applies to: `ios/HasalaUITests/SmokeTests.swift`
(`testTheFirstRevealKeepsItsTimingWithAmountsShown`).
