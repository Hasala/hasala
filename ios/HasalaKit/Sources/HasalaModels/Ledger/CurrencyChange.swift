public enum CurrencyChange {
  public enum Block: Sendable, Hashable {
    case heldCopy
    case samePurchase
    case countedOnce
    case statedHome
  }

  public static let refusedText = "The currency of this transaction can't be changed."

  public static func block(_ t: Txn) -> Block? {
    if t.isHeldCopy { return .heldCopy }
    if t.samePurchase != nil { return .samePurchase }
    if t.mergedInto != nil { return .countedOnce }
    if t.homeSource == .stated { return .statedHome }
    return nil
  }

  public static func isEligible(_ t: Txn) -> Bool { block(t) == nil }

  public static func isAwaited(_ t: Txn, in s: LedgerState) -> Bool {
    s.txns.contains { $0.samePurchase?.of == t.id || $0.heldCopy?.of == t.id }
  }

  public static func options(for t: Txn, in s: LedgerState) -> [String] {
    guard isEligible(t), ExchangeRates.isCurrencyCode(t.amount.currency), !isAwaited(t, in: s) else { return [] }
    let rated = Set(s.rates.filter { $0.rateMicro != nil && ExchangeRates.isCurrencyCode($0.currency) }.map(\.currency))
    return ([Money.home] + rated.subtracting([Money.home]).sorted()).filter { $0 != t.amount.currency }
  }

  public static func title(_ currency: String) -> String { "Changed to \(currency)" }
}

public extension LedgerState {
  mutating func changeCurrency(_ id: TxnID, to currency: String) throws(ActionError) {
    guard let i = txns.firstIndex(where: { $0.id == id }) else { throw .notFound }
    guard CurrencyChange.options(for: txns[i], in: self).contains(currency) else {
      throw .refused(CurrencyChange.refusedText)
    }
    var t = txns[i]
    t.amount = Money(minor: t.amount.minor, currency: currency)
    if currency != Money.home, let micro = rates.first(where: { $0.currency == currency })?.rateMicro,
      let home = ExchangeRates.convert(t.amount.minor, micro)
    {
      t.homeMinor = home
      t.homeSource = .rate
      t.homeRateMicro = micro
    }
    t.splits = t.apportioned(t.splits)
    txns[i] = t
  }
}
