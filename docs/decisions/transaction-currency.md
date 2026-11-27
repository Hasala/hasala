# Changing a transaction's currency (2026-11-27)

**Status: proposed, the owner confirms in review.** Every example is synthetic.

## Why

Many bank texts show an amount with no currency mark. The reader then takes the home
currency, so a payment of 1,500.00 yen comes in as AED 1,500.00 and counts as that much
spending. The person could archive the row and add it again by hand, but then the row loses
its link to the bank text.

## Decision

The transaction sheet has a **Currency** row. It shows the row's currency code and opens a
list of the other currencies that the person can pick. A pick changes the currency of that
one transaction, and the toast offers **Undo**.

**The pick list.** AED first, then each currency that has a rate set on the rates page, from
A to Z, without the row's own currency (`CurrencyChange.options(for:in:)`). A currency with
no rate is not on the list, because the row could not be counted. When the list is empty,
the sheet shows no Currency row.

**The amount is not changed.** Schema v4 stores the amount of every currency in hundredths
(`docs/decisions/code/ios-money-to-projection.md`, "Minor-unit exponents are for display,
never for the fold"). The number that the person saw stays the same: AED 1,500.00 becomes
JPY 1,500.00. Only the home amount is computed again, at the rate of the new currency. For
AED it is the amount itself. A split keeps its parts, and each part gets its share of the
new home amount.

**Rows that are not offered.** The sheet shows no Currency row for them, and the app writes
nothing if an edit for one still arrives:

- A held copy. It waits for the answer "merge or keep both", and it is compared with the
  other row by its amount and currency.
- A row that waits for a same-purchase answer. The question is "is this AED row the same
  purchase as that foreign row", and a new currency would change the question.
- A row that was counted once with another row (a merged copy). It is archived and its
  amount is in the other row.
- A row with a home amount that the bank stated. That figure belongs to the first currency.
  The fold drops it on a currency edit, so the bank's own figure would be lost.
- An unparsed row. It has no amount and no currency yet, and the fold refuses a money edit
  on it.
- A row that a newer row replaced, and a row that the old ingest writer made. The fold
  refuses a money edit on them.

**No memory for a merchant.** A change applies to one transaction. The app does not learn
"this merchant is in yen", and it does not change other rows or later rows of that merchant.

**No new op type.** The edit is a `txn_edited` op whose payload has only `currency`
(`OpAuthor.editTxn(txnID:parentVersion:currency:)`). It has no `amount_minor`. Undo writes
a second `txn_edited` with the first currency, when the row still has the new one. The home
amount after an undo comes from the rate of that moment, not from the rate that the row had
before.

**Older builds.** The fold already reads `currency` in `txn_edited` (`applyMoneyEdit` in
`Replay/Causal.swift`). A build from before this decision folds the op to the same state.
It has no Currency row, but it shows the changed row correctly. The schema version does not
change.

## Where it is in the code

- `ios/HasalaKit/Sources/HasalaModels/Ledger/CurrencyChange.swift`: the pick list, the rows
  that are not offered, and the change of the screen state (`LedgerState.changeCurrency`).
- `ios/Hasala/Live/Ledger/LedgerEditAuthor.swift`: `.changeCurrency` writes the op.
  `takesCurrency` and `offersCurrency` examine the stored row and the stored rates again
  before the op is written. `Inverse.currency` is the undo.
- `ios/Hasala/Live/Ledger/LiveLedgerStore.swift` (`patch`): the change on the screen before
  the op is folded.
- `ios/Hasala/Features/Transaction/`: the Currency row (`TransactionSheet`), the list
  (`CurrencyPickerView`) and the model (`TransactionModel.currencyOptions`,
  `changeCurrency`).
- Tests: `ios/HasalaTests/LiveCurrencyTests.swift`,
  `ios/HasalaKit/Tests/HasalaKitTests/CurrencyChangeTests.swift`,
  `ios/HasalaCore/Tests/CoreReplayTests/CurrencyEditTests.swift`.
