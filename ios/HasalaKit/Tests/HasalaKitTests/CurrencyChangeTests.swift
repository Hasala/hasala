import HasalaMocks
import HasalaModels
import Testing

@MainActor
@Suite("Currency change")
struct CurrencyChangeTests {
  static func row(_ id: TxnID, _ minor: Int64, _ ccy: String = Money.home, home: Int64?? = nil) -> Txn {
    Txn(id: id, merchant: "Shop", amount: Money(minor: minor, currency: ccy), homeMinor: home,
        homeSource: ccy == Money.home ? nil : .some(.rate), homeRateMicro: 3_672_500,
        postedAt: LocalDateTime(2026, 10, 10, 12, 0), accountID: "dib", categoryID: "dining")
  }

  static func state(_ txns: [Txn]) -> LedgerState {
    var s = MayaLedger.state
    s.txns += txns
    s.rates = [
      CurrencyRate(currency: "USD", rateMicro: 3_672_500), CurrencyRate(currency: "JPY", rateMicro: 24_500),
      CurrencyRate(currency: "EUR", rateMicro: nil), CurrencyRate(currency: "AED", rateMicro: 1_000_000),
    ]
    return s
  }

  @Test func theListIsHomeThenRatedCurrenciesWithoutTheCurrentOne() {
    let aed = Self.row("a", 1_500_00)
    let usd = Self.row("u", 45_99, "USD", home: .some(168_90))
    let s = Self.state([aed, usd])
    #expect(CurrencyChange.options(for: aed, in: s) == ["JPY", "USD"])
    #expect(CurrencyChange.options(for: usd, in: s) == ["AED", "JPY"])
  }

  @Test func aCurrencyWithNoRateIsNotOffered() {
    let aed = Self.row("a", 1_500_00)
    var s = Self.state([aed])
    #expect(!CurrencyChange.options(for: aed, in: s).contains("EUR"))
    s.rates = []
    #expect(CurrencyChange.options(for: aed, in: s).isEmpty)
    #expect(CurrencyChange.options(for: Self.row("k", 7_50, "KWD", home: .some(nil)), in: s) == ["AED"])
  }

  @Test func rowsWhoseLinkOrBankFigureWouldBreakAreNotEligible() {
    var held = Self.row("h", 10_00)
    held.heldCopy = HeldCopy(of: "a", fromOtherInbox: false)
    var same = Self.row("s", 10_00)
    same.samePurchase = SamePurchaseMatch(of: "u")
    var merged = Self.row("m", 10_00)
    merged.mergedInto = "u"
    var stated = Self.row("u", 45_99, "USD", home: .some(170_00))
    stated.setStatedHome(170_00)
    let s = Self.state([held, same, merged, stated])
    #expect(CurrencyChange.block(held) == .heldCopy)
    #expect(CurrencyChange.block(same) == .samePurchase)
    #expect(CurrencyChange.block(merged) == .countedOnce)
    #expect(CurrencyChange.block(stated) == .statedHome)
    for t in [held, same, merged, stated] {
      #expect(!CurrencyChange.isEligible(t))
      #expect(CurrencyChange.options(for: t, in: s).isEmpty)
    }
    var split = Self.row("p", 100_00)
    split.splits = [SplitLine(id: 0, categoryID: "dining", amount: .aed(60_00)), SplitLine(id: 1, categoryID: "groceries", amount: .aed(40_00))]
    var transfer = Self.row("t", 10_00)
    transfer.isTransfer = true
    transfer.isMatchedTransfer = true
    var bill = Self.row("b", 10_00)
    bill.billID = "netflix"
    var refund = Self.row("r", 10_00)
    refund.isRefund = true
    refund.refundOf = "a"
    for t in [split, transfer, bill, refund] { #expect(CurrencyChange.isEligible(t)) }
  }

  @Test func theChangeKeepsTheNumberAndCountsItAtTheRate() throws {
    let ledger = InMemoryLedger(state: Self.state([Self.row("a", 1_500_00)]))
    let token = try #require(try ledger.apply(.changeCurrency("a", to: "JPY")))
    #expect(token.title == "Changed to JPY")
    let t = try #require(ledger.state.txn("a"))
    #expect(t.amount == Money(minor: 1_500_00, currency: "JPY"))
    #expect(MoneyFormat.string(t.amount) == "1,500.00")
    #expect(t.homeMinor == 36_75)
    #expect(t.homeSource == .rate)
    #expect(t.homeRateMicro == 24_500)
    #expect(t.isEstimate)
    ledger.undo(token)
    let back = try #require(ledger.state.txn("a"))
    #expect(back.amount == .aed(1_500_00))
    #expect(back.homeMinor == 1_500_00)
    #expect(back.homeSource == .identity)
    #expect(back.homeRateMicro == nil)
  }

  @Test func aChangeToHomeCountsTheAmountAsItIsAndUndoGivesBackTheEstimate() throws {
    let ledger = InMemoryLedger(state: Self.state([Self.row("u", 45_99, "USD", home: .some(168_90))]))
    let token = try #require(try ledger.apply(.changeCurrency("u", to: "AED")))
    let t = try #require(ledger.state.txn("u"))
    #expect(t.amount == .aed(45_99))
    #expect(t.homeMinor == 45_99)
    #expect(t.homeSource == .identity)
    ledger.undo(token)
    let back = try #require(ledger.state.txn("u"))
    #expect(back.amount == Money(minor: 45_99, currency: "USD"))
    #expect(back.homeMinor == 168_90)
    #expect(back.homeSource == .rate)
    #expect(back.homeRateMicro == 3_672_500)
  }

  @Test func aSplitKeepsItsPartsAndSharesTheNewHomeAmount() throws {
    var split = Self.row("p", 342_15)
    split.splits = [
      SplitLine(id: 0, categoryID: "groceries", amount: .aed(297_00)), SplitLine(id: 1, categoryID: "dining", amount: .aed(45_15)),
    ]
    let ledger = InMemoryLedger(state: Self.state([split]))
    try ledger.apply(.changeCurrency("p", to: "JPY"))
    let t = try #require(ledger.state.txn("p"))
    #expect(t.homeMinor == 8_38)
    #expect(t.splits.map(\.amount) == [Money(minor: 297_00, currency: "JPY"), Money(minor: 45_15, currency: "JPY")])
    #expect(t.splits.map(\.homeMinor) == [7_27, 1_11])
    #expect(TransactionEngine.splitAddsUp(t.splits, total: t.amount))
  }

  @Test func refusedChangesLeaveTheRowAlone() throws {
    var stated = Self.row("u", 45_99, "USD", home: .some(170_00))
    stated.setStatedHome(170_00)
    let ledger = InMemoryLedger(state: Self.state([Self.row("a", 1_500_00), stated]))
    let before = ledger.state.txns
    let refused = ActionError.refused(CurrencyChange.refusedText)
    #expect(throws: refused) { try ledger.apply(.changeCurrency("a", to: "EUR")) }
    #expect(throws: refused) { try ledger.apply(.changeCurrency("a", to: "AED")) }
    #expect(throws: refused) { try ledger.apply(.changeCurrency("a", to: "jpy")) }
    #expect(throws: refused) { try ledger.apply(.changeCurrency("u", to: "AED")) }
    #expect(throws: ActionError.notFound) { try ledger.apply(.changeCurrency("nope", to: "JPY")) }
    #expect(ledger.state.txns == before)
  }
}
