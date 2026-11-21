# Sample seed generator and HasalaDesign components: decisions from the code (2026-11-21)

These decisions were code comments under `ios/HasalaCore/Tools/SampleSeedExport/` and
`ios/HasalaKit/Sources/HasalaDesign/Components/`. Code comments are
not permitted (`scripts/comment-lint.ts`), thus the decisions are here.

## The sample seed generator is a package of its own and reads the Maya mock

The bundled sample seed (`Resources/sample/maya-v1.json` and `SampleManifest.swift` in
HasalaCore) is the output of a generator. The generator builds the seed from `MayaLedger`
in HasalaMocks (owner decision 5 of the TestFlight plan). The reason: the sample that a
reviewer loads must show the same figures as the Debug screens and the Paper boards. Do
not edit the seed manually, and do not build it from a second data set.

The generator is a Swift package of its own (`ios/HasalaCore/Tools/SampleSeedExport`).
HasalaCore must not depend on HasalaKit, because the mocks are Debug-only app code. If the
generator moves into the HasalaCore package, HasalaCore gets a dependency on the mocks.

- `swift test --package-path ios/HasalaCore/Tools/SampleSeedExport` examines that the
  committed seed and manifest are exactly the output of the generator.
- `HASALA_WRITE_SAMPLE=1` before the same command writes them.
- `HASALA_KIT_PATH` points the generator at a different HasalaKit checkout. The default is
  `ios/HasalaKit` of this repository.

The generator and the loader (`SampleSeed` in CoreDomain) are the two halves of one
contract. These rules of the generator are not visible in the loader:

- A built-in category that the mock does not change gets no op. Each other category is a
  user category with a placeholder id.
- The amount of a bill is its usual amount (the price before a change). Each payment is a
  paid occurrence on its scheduled due date, not on the day of the payment.
- A transaction with provenance is a mailbox row with a `sample-<n>` message id. A
  transaction without provenance is a manual row. A review row has no category.
- The seed does not carry bill candidates, "new merchant" flags, review suggestions and
  row detail overrides. No op family holds them. The screens derive them.

Applies to: `ios/HasalaCore/Tools/SampleSeedExport/Package.swift`,
`ios/HasalaCore/Tools/SampleSeedExport/Tests/SampleSeedExportTests/MayaSeedExport.swift`.

## A disabled pill in a dock has an opaque base

The disabled fill of a pill button is a translucent grey (`appleFillsSecondary`). In the
dock of a screen, content scrolls behind the pill, and that content shows through the
grey. Thus a dock sets the environment value `pillDisabledBase` to its canvas colour, and
the pill draws that opaque colour under the grey. Without a value, the pill draws the grey
alone.

Do not remove the base as a layer that does nothing. On a plain card it has no effect, but
in a dock the text behind a disabled button becomes readable through the button.

Applies to: `ios/HasalaKit/Sources/HasalaDesign/Components/Buttons.swift`
(`PillButtonBody`, `EnvironmentValues.pillDisabledBase`).

## A Dynamic Type cap goes outside the view that it caps

A view that stops its growth at a text size gets the cap (`dynamicTypeSize(...)` or
`cappedDynamicType`) from its parent, not in its own body. A `@ScaledMetric` property
reads the text size of the environment that its own view gets. A cap in the body of the
same view comes too late: the font stops, but the scaled height, padding and figure size
continue to grow.

For this reason `StyledBadge` and `FigureLineBody` are views of their own, and
`CountBadge` and `FigureLine` apply the cap around them. Do not merge the inner view into
the outer view.

A count badge on an icon stops at `accessibility1` (page 17 §02). A larger badge covers
the icon that it sits on.

Applies to: `ios/HasalaKit/Sources/HasalaDesign/Components/Chips.swift` (`CountBadge`,
`StyledBadge`), `ios/HasalaKit/Sources/HasalaDesign/Components/Money.swift` (`FigureLine`,
`FigureLineBody`).

## Text that does not grow to the largest size has the audit marker

The accessibility audit of the UI tests runs at the `.accessibility3` text size. It
accepts the issue "Dynamic Type partially unsupported" only on an element with the
accessibility identifier `hasala.cappedFigure` (`hasalaCappedFigureIdentifier`, spec 04
§14.4). Text that stops its growth on purpose must have this identifier:

- the figure of a count badge, which stops at `accessibility1`;
- the digits and the decimal point of the amount keypad, which stay 28 pt at each text
  size (page 11). The amount figure above the keypad is the text that grows.

If the identifier is removed, the audit fails. Do not put the identifier on text that
must grow: the audit then does not report a real defect.

Applies to: `ios/HasalaKit/Sources/HasalaDesign/Components/Chips.swift` (`StyledBadge`),
`ios/HasalaKit/Sources/HasalaDesign/Components/Keypad.swift` (`KeypadKey`),
`ios/HasalaUITests/UITestSupport.swift`.

## The bank plate draws its initials in a canvas

The initials on a bank plate ("ENBD", "DIB") are a picture of the mark of the bank. A
`Canvas` draws them. They are not a text node. The plate keeps its 40 pt size at each
text size, as the glyph plates do. A code too wide for the plate is drawn smaller on one
line; it does not wrap.

A text node that shrinks in the plate made the accessibility audit report "Dynamic Type
partially unsupported", also in a row that hides the plate from accessibility
(requests/p8.md 1). The row beside the plate names the bank in text that grows, so the
person loses nothing.

Do not change the canvas back to a `Text` view. The audit fails again.

Applies to: `ios/HasalaKit/Sources/HasalaDesign/Components/Discs.swift` (`BankPlate`).

## The toast has the system material under the frost

The glass toast draws two layers behind its words: the system material
(`.regularMaterial`), then Paper's frost-strong fill (white 76 %) over it. Paper draws
the frost over a 12 pt blur. The system material is that blur.

The frost alone is not sufficient. Without the blur, dark content that scrolls behind the
toast showed through its words: the title of the dark Net worth widget was readable
through the action "Show". Do not remove the material layer. With Reduce Transparency the
toast draws a solid fill and not these two layers.

Applies to: `ios/HasalaKit/Sources/HasalaDesign/Components/Feedback.swift` (`GlassToast`).

## A money figure becomes smaller and is never cut

A figure that is too long for its space becomes smaller, down to the floor of its figure
style (`minimumScale`). It does not truncate and it does not wrap. A cut amount is a wrong
amount.

- The unit ("AED") and the digits are one text. Thus the two parts shrink by the same
  factor and stay on one baseline. Do not split them into two `Text` views.
- A row figure and a compact figure have no floor below 1, because their row reflows. If a
  container squeezes one of them, it can still shrink to 0.75. Do not change this fallback
  to 1: then the amount truncates.

Applies to: `ios/HasalaKit/Sources/HasalaDesign/Components/Money.swift` (`MoneyText`,
`FigureLine`, `FigureLineBody`).

## The steps of a pace bar reveal start together

The reveal of a pace bar has three steps: the fill (300 ms), then the today tick
(120 ms), then the verdict (150 ms). The code starts the three animations in the same
moment. The tick and the verdict have a delay (`HMotion.fill`, then
`HMotion.fill + HMotion.marker`), so the render clock keeps the times between them.

The rejected alternative: start each step from the completion of the step before it. Then
each step landed two or three frames late. A frame trace showed the tick at 375 ms and the
verdict at 540 ms; the design gives 300 ms and 420 ms (requests/p5.md 4). Do not chain the
steps with completion handlers.

Applies to: `ios/HasalaKit/Sources/HasalaDesign/Components/Pace.swift`
(`PaceFillSequence`).
