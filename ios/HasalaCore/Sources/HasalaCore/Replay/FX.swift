import HasalaText
import OrderedCollections

public enum FX {
  public static func convert(_ amountMinor: Int64, _ rateMicro: Int64) -> Int64? {
    guard amountMinor >= 0, rateMicro >= 0 else { return nil }
    let wide = Int128(amountMinor) * Int128(rateMicro) + 500_000
    return Int64(exactly: wide / 1_000_000)
  }
}

extension State {
  mutating func markPending(_ t: Txn) {
    if t.unparsed || t.amountHomeMinor != nil { return }
    pendingByCurrency[t.currency, default: []].append(t.id)
  }

  mutating func clearPending(_ t: Txn) {
    guard var set = pendingByCurrency[t.currency] else { return }
    set.remove(t.id)
    pendingByCurrency[t.currency] = set.isEmpty ? nil : set
  }

  mutating func onHomeCurrencySet(_ ccy: String, seq: Int64) {
    homeCurrency = ccy
    rates[ccy] = .some(homeIdentityMicro)
    backfill(ccy, homeIdentityMicro, seq: seq)
  }

  mutating func onRateSet(_ ccy: String, _ micro: Int64, seq: Int64) {
    rates[ccy] = .some(micro)
    backfill(ccy, micro, seq: seq)
  }

  mutating func onRateUnset(_ ccy: String) {
    rates[ccy] = .some(nil)
  }

  mutating func freezeIfPossible(_ id: String, seq: Int64) {
    guard let t = txns[id] else { return }
    if case .some(.some(let rate)) = rates[t.currency] {
      if let home = FX.convert(t.amountMinor, rate) {
        txns[id]!.amountHomeMinor = home
        setRateSource(id, t.currency, rate)
        clearPending(txns[id]!)
        return
      }
      anomaly(seq, "money_overflow", "\(id): the home amount does not fit int64")
    }
    txns[id]!.amountHomeMinor = nil
    txns[id]!.homeSource = nil
    txns[id]!.homeRateMicro = nil
    markPending(txns[id]!)
  }

  private mutating func setRateSource(_ id: String, _ ccy: String, _ micro: Int64) {
    if let home = homeCurrency, utf8Equal(home, ccy) {
      txns[id]!.homeSource = .identity
      txns[id]!.homeRateMicro = nil
    } else {
      txns[id]!.homeSource = .rate
      txns[id]!.homeRateMicro = micro
    }
  }

  private mutating func backfill(_ ccy: String, _ micro: Int64, seq: Int64) {
    guard let waiting = pendingByCurrency[ccy] else { return }
    pendingByCurrency[ccy] = nil
    var still: OrderedSet<String> = []
    for id in waiting {
      guard let t = txns[id] else { continue }
      if let home = FX.convert(t.amountMinor, micro) {
        txns[id]!.amountHomeMinor = home
        setRateSource(id, ccy, micro)
      } else {
        anomaly(seq, "money_overflow", "\(id): the home amount does not fit int64")
        still.append(id)
      }
    }
    if !still.isEmpty { pendingByCurrency[ccy] = still }
  }
}
