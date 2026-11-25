# HasalaModels engines and read models: decisions from the code (2026-11-21)

These decisions were code comments under `ios/HasalaKit/Sources/HasalaModels/Engines`
and `ios/HasalaKit/Sources/HasalaModels`. Code comments are not permitted
(`scripts/comment-lint.ts`), thus the decisions are here.

## A bill past its day is never called late

Hasala reads the bank's alerts. When a bill's day passes and no payment was read, Hasala
knows only that it saw no payment. The person can have paid in a way that sent no alert.
Hasala cannot know for sure (spec 01 §07, page 18 §14).

Thus the copy says what Hasala noticed, and never that the bill "is late":

- A row or a pill says "3 days past usual" or "Expected the 7th" (page 16 §12).
- A notification says that the bill "may be late". A bill may be late from the day after
  its due day with no payment read.

The code keeps a `late` case as its own name for this state. That name does not go on
the screen. Copy that says "late" or "is late" tells the person something that Hasala
does not know, and it is wrong each time a payment was made with no alert.

Applies to: `ios/HasalaKit/Sources/HasalaModels/Engines/ActivityEngine.swift`
(`comingUp`), `ios/HasalaKit/Sources/HasalaModels/Engines/BillsEngine.swift`
(`BillAttention.pill`, `pastUsual`),
`ios/HasalaKit/Sources/HasalaModels/Engines/NotificationsEngine.swift` (`snapshot`).

## CSV export neutralizes spreadsheet formulas in text cells only

The export writes text that comes from outside the app: the merchant as the bank wrote
it, and names and notes that the person typed. A spreadsheet runs a cell as a formula
when it starts with certain characters. So each text cell (description, category,
merchant, note, project, account) gets a `'` in front when one of these is true
(spec 04 §16.2 T5, F5, R-14):

- Its first scalar is TAB, CR or LF.
- Its first scalar after the blanks at the start is `=`, `+`, `-` or `@`, or the
  full-width form of one of them.

The cell is neutralized first and quoted (RFC 4180) second. In the opposite order, a
value that needs quotes starts with `"`, the rule does not see its first character, and
the formula stays.

The amount cells are not neutralized. Money out has a minus sign in front, and a `'`
before it makes the spreadsheet read the amount as text. The app writes these cells
from integers, so they cannot contain a formula.

Without the rule, a merchant name in a bank alert can run a formula on the computer of
a person who opens the export.

Applies to: `ios/HasalaKit/Sources/HasalaModels/Engines/CSVExport.swift`
(`neutralize`, `text`, `csv`).

## Home says Ahead of pace, cards and rows say Over pace

The pace verdict `overPace` has two wordings (plan decision 9). The Home hero says
"Ahead of pace". Each card and each row says "Over pace" (`Verdict.label`). The hero
does not use `Verdict.label` for this verdict. This is on purpose: do not make the two
the same.

Applies to: `ios/HasalaKit/Sources/HasalaModels/Engines/HomeEngine.swift` (`hero`),
`ios/HasalaKit/Sources/HasalaModels/Home.swift` (`Verdict.label`).

## Home's tick counts the bills charged so far

The tick on the Home bar is the planned spend by today (page 06 §6.4):

    tick = bills charged so far + (plan − all bills this month) × day ÷ days

The result is rounded to the fil. "All bills this month" is the bills charged so far
plus the tracked bills that are still to come this month, late ones included. Only the
bills of needs and wants categories count, because savings are not on the bar.

- Bills are not spread over the days. A bill moves the tick by its full amount on the
  day that it is charged. Thus rent on the 1st does not read as overspending.
- "So far" means the bills that were charged, not the bills that were due. A late bill
  is not in the tick until its payment arrives. Then the tick and the spending go up by
  the same amount, so the arrival of a late bill never changes the verdict. The figures
  of the Paper board use the same rule.

A tick that spreads the full plan over the days shows "ahead of pace" after each large
bill. A tick that counts bills when they are due changes the verdict when a late bill
arrives.

Applies to: `ios/HasalaKit/Sources/HasalaModels/Engines/HomeEngine.swift` (`tick`,
`billsThisMonth`).

## A goal's percent rounds down

The percent label of a goal is the whole percent, rounded down. A goal at 99.9% shows
"99%". It shows "100%" only when the goal is complete. Rounding to the nearest percent
tells the person that a goal is done while money is still missing.

Applies to: `ios/HasalaKit/Sources/HasalaModels/Home.swift` (`GoalWidget.percentLabel`).

## The match count of a rule is the payments that the rule filed

The rules page, the rules of a category and Search show "N matches" for a rule. N is the
number of payments that the rule filed and that are not archived: the rows whose `ruleID` is
the rule. This is the `match_count` of the view `rule_stats` in the projection.

The read model does not run the patterns of a rule against merchant names. Only
CoreCategorize's `Matcher` decides if a pattern matches a merchant (spec 03c §5.2), and
HasalaKit cannot import HasalaCore. A second matcher in HasalaModels gave a count that
differed from the rows that the rule sorted (issue #339). Do not add one.

Two results follow:

- A payment that the person filed by hand does not count, also when a pattern matches its
  merchant. A rule that was learned from one payment shows "0 matches" until it files a row.
- A payment that a rule with a higher priority filed counts for that rule only.

The mock ledger obeys the same rule. A seeded row that a rule filed has the `ruleID` of the
rule (`MayaLedger.keyed` fills it from the pattern that the row names), and `InMemoryLedger`
applies a learned rule with `GroupRule.reaches`.

Applies to: `ios/HasalaKit/Sources/HasalaModels/Engines/ProfileEngine.swift`
(`matchCounts`, `rules`), `ios/HasalaKit/Sources/HasalaModels/Engines/PlanEngine.swift`
(`rules`), `ios/Hasala/Features/Search/SearchView.swift` (`SearchResults`),
`ios/HasalaKit/Sources/HasalaMocks/MayaLedger.swift` (`keyed`),
`ios/HasalaKit/Sources/HasalaMocks/InMemoryLedger.swift` (`reachBack`).
