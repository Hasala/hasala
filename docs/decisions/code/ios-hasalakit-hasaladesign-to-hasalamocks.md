# HasalaDesign foundation and icons: decisions from the code (2026-11-21)

These decisions were code comments under `ios/HasalaKit/Sources/HasalaDesign/Foundation/` and
`ios/HasalaKit/Sources/HasalaDesign/Icons/`. Code comments are not permitted
(`scripts/comment-lint.ts`), thus the decisions are here.

## Paper gives CSS values, and their SwiftUI equivalents are different numbers

The app must agree with the Paper design. Paper gives its values as CSS. Some CSS values do
not go into SwiftUI unchanged. A change that "corrects" one of these values to the number on
the board makes the app different from the board.

- **Gradient colour space.** Paper draws the hue gradients as
  `linear-gradient(in oklab 160deg, start, end)`. In SwiftUI this is a gradient with
  `.colorSpace(.perceptual)`. Without it, the middle of the gradient has a different colour.
- **Gradient angle.** CSS 160° on a square goes from a point a small distance left of the top
  centre to a point a small distance right of the bottom centre. The unit points are
  (0.33, 0) and (0.67, 1).
- **Fade to clear.** A wash fades to the same colour at opacity 0. It does not fade to
  `Color.clear`, which is transparent black and makes the middle of the fade grey.
- **Shadow blur.** A CSS blur is two times the SwiftUI shadow radius. Paper's near shadow is
  `0 1 2` and its far shadow is `0 8 24`, thus the radii are 1 and 12.
- **Line height.** A CSS line height is the full height of a line. SwiftUI adds line spacing
  to the natural height of the font. Inter's ascent and descent are 1.21 em together, and SF
  Pro Rounded's natural line height is approximately 1.19 em. Thus the added space is the
  leading minus 1.21 (or 1.19) times the size. Examine these ratios again when the bundled
  Inter changes.

Applies to: `ios/HasalaKit/Sources/HasalaDesign/Foundation/Color.swift` (`Hue.perceptual`,
`Hue.gradientStart`, `Hue.gradientEnd`),
`ios/HasalaKit/Sources/HasalaDesign/Foundation/Materials.swift` (`hElevation`,
`HRGBA.withOpacity`, `HRGBA.clear`),
`ios/HasalaKit/Sources/HasalaDesign/Foundation/Typography.swift` (`interLineRatio`,
`roundedLineRatio`).

## Inter is one bundled variable font with automatic optical size

The text face is Inter 4.1 as one variable font file (`InterVariable.ttf`, with a weight axis
and an optical-size axis), under the SIL Open Font License 1.1 (`LICENSES/OFL-1.1.txt`,
`NOTICE`; spec 04 §14.3). The four weights of the type scale are its named instances Regular,
Medium, SemiBold and Bold.

Paper sets Inter with automatic optical sizing. Core Text does the same for a font that has
an `opsz` axis: each point size gets its own cut, and the display cut starts at 32 pt. Thus a
title has the same width and the same line breaks as on the boards. Do not replace the
variable font with static Inter files. Static files have one optical size, so titles become
wider and break at other words.

Figures use the system's SF Pro Rounded. It is not bundled.

Applies to: `ios/HasalaKit/Sources/HasalaDesign/Foundation/Fonts.swift` (`HasalaFonts`).

## Bold Text steps the Inter weight in code

A bundled font does not follow the Bold Text accessibility setting by itself. Only system
fonts do. Thus the text style reads `legibilityWeight` and uses the next heavier Inter weight
when Bold Text is on (spec 01 §2.4: "Inter steps up one weight"). If a change removes this
step, Bold Text has no effect on Inter text.

Applies to: `ios/HasalaKit/Sources/HasalaDesign/Foundation/Typography.swift` (`HTypeModifier`,
`HWeight.bolder`).

## Overline text is upper case only in its styling

The overline style ("DAY 10 OF 31") shows upper-case letters through `textCase`. The source
string stays in sentence case. VoiceOver reads the source string, so it reads words. If the
source string is upper case, VoiceOver can read it letter by letter. Do not write an
upper-case string for this style.

Applies to: `ios/HasalaKit/Sources/HasalaDesign/Foundation/Typography.swift`
(`HType.overline`).

## Display and hero figures stop growing at accessibility3

The display figure, the hero figure and the unit beside a display figure grow with Dynamic
Type only up to `.accessibility3`. At larger sizes the layout reflows instead (spec 04
§14.4). This is on purpose.

- The cap is applied outside the figure modifier. The `@ScaledMetric` inside the modifier
  then reads the capped size. If the cap moves inside the modifier, the metric reads the
  uncapped size and the figure grows past the cap.
- Text with a cap carries the accessibility identifier `hasala.cappedFigure`. The
  accessibility audit of the UI tests accepts "Dynamic Type partially unsupported" only on
  elements with this identifier. Do not put the identifier on text that has no cap on
  purpose, and do not change its value without the UI tests.

Applies to: `ios/HasalaKit/Sources/HasalaDesign/Foundation/Typography.swift`
(`HFigure.maxDynamicTypeSize`, `hFigure`, `cappedDynamicType`,
`hasalaCappedFigureIdentifier`), `ios/HasalaUITests/UITestSupport.swift`.

## Glass is the system material, not a copy of Paper's layers

Chrome that floats (the tab bar, search, header buttons, sheet controls, toasts, review
pills) uses the native Liquid Glass material. Content uses solid cards (spec 01 §4.1–4.7,
B1.5). Paper draws glass as five layers. Those layers are Paper's drawing of the iOS 26
material. The build uses the material itself and does not build the five layers again
(decision 2). With Reduce Transparency, the material becomes a solid fill with a hairline
outline, so the edge still shows.

Applies to: `ios/HasalaKit/Sources/HasalaDesign/Foundation/Materials.swift` (`GlassModifier`,
`hGlass`).

## Motion durations are the owner's motion policy

The durations in `HMotion` follow the owner's motion policy of 2026-10-15 (spec 01
§4.8–4.11). This policy has priority over the longer "Proposed for app" values on Paper page
04. `MotionTests` pins each value. Change a value only when the owner changes it on purpose.

- Micro-interactions are 100 to 150 ms. Standard UI motion is 150 to 250 ms.
- UI motion stays below 300 ms. Only a bar fill and a figure count reach 300 ms.
- The exception is a first-time moment that celebrates (the Welcome deal-in, a badge that
  settles). It can be longer, at most 600 ms.
- Sheets, pushes, alerts, menus and the tab bar keep the system timing. The design system
  does not restyle them.
- A button scales to 0.97 while pressed (decision 1). Rows, list groups and keypad keys only
  show the pressed fill. They never scale.
- The deal spring and the bouncy spring are only for the Welcome stories.
- The idle float of the Welcome cards is the only loop in the app. Do not add a second loop.

Paper has no motion tokens. Thus the values are constants in `HMotion`, not generated tokens.

Applies to: `ios/HasalaKit/Sources/HasalaDesign/Foundation/Motion.swift` (`HMotion`),
`ios/HasalaKit/Tests/HasalaKitTests/MotionTests.swift`.

## Reduce Motion removes travel, not colour, opacity or haptics

With Reduce Motion, each kind of motion has a substitute (B1.2):

- A change of colour or opacity is not motion. A press, a row highlight, a fade, a state swap
  and Hide amounts keep their usual timing.
- Travel, scale, rotation and springs become one short cross-fade.
- Fills, the today tick, counts, jumps and the loop show the final state at once.

The motion modifiers read the system's Reduce Motion setting together with the policy from
the environment. Thus a view tree whose root did not set the policy still obeys the person's
setting. Do not make the modifiers read only the policy.

Applies to: `ios/HasalaKit/Sources/HasalaDesign/Foundation/Motion.swift` (`HMotion.reduced`,
`ResolvedMotion`).

## A haptic answers only an action of the person

Each haptic answers one thing that the person did, and it plays when the motion of that
action settles (spec 01 §4.11, B1.4, the owner's motion policy). Nothing plays a haptic by
itself: auto-advance, a timer and the end of a scan have none. Reduce Motion and the Debug
settled-motion switch remove travel, but they do not remove haptics. Each haptic goes through
`.sensoryFeedback`, so the system haptics setting applies. Do not play a haptic through a
feedback generator, and do not add a haptic to an event that the person did not cause.

Applies to: `ios/HasalaKit/Sources/HasalaDesign/Foundation/Haptics.swift` (`HHaptic`,
`hHaptic`).

## Mail provider marks keep their own form and colours

The mark of a mail provider is the mark of another company: the Google "G" and the four
Microsoft squares (Paper page 15 · Mailboxes, page 05). The app shows each mark in its own
colours on a white plate. Do not recolour, outline or tint a mark, and do not let it take the
colour of its container. Do not use a general mail icon in its place. The marks belong to
those companies, so the app does not change them. A disconnected mailbox shows the full plate
at half opacity.

Microsoft's mark covers Outlook.com, Hotmail and Live. There is no separate Outlook mark.

Applies to: `ios/HasalaKit/Sources/HasalaDesign/Icons/ProviderMark.swift` (`ProviderMark`),
`ios/HasalaKit/Sources/HasalaDesign/Icons/HIcon.swift` (`HIcon.google`, `HIcon.microsoft`).
