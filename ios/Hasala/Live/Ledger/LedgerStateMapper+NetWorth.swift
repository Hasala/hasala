import CoreReplay
import CoreTime
import Foundation
import HasalaModels

nonisolated extension LedgerStateMapper {
  static let netWorthMonths = 12

  static func netWorthHistory(
    accounts: [CoreReplay.Account], checkins: [Checkin], rates: [CurrencyRate], month: CivilMonth
  ) -> NetWorthHistory {
    var byAccount: [String: [(ms: Int64, minor: Int64)]] = [:]
    for c in checkins where !c.void {
      guard let ms = try? parseInstantMs(c.asOf) else { continue }
      byAccount[c.account, default: []].append((ms, c.balanceMinor))
    }
    let tracked: [(currency: String, checkins: [(ms: Int64, minor: Int64)])] = accounts.compactMap { a in
      byAccount[a.id].map { (a.currency, $0.sorted { $0.ms > $1.ms }) }
    }
    guard !tracked.isEmpty else { return NetWorthHistory() }

    func total(before cutoff: Int64?) -> Int64? {
      var balances: [Money] = []
      for account in tracked {
        guard let found = account.checkins.first(where: { c in cutoff.map { c.ms < $0 } ?? true }) else { return nil }
        balances.append(Money(minor: found.minor, currency: account.currency))
      }
      return Money.homeTotal(balances, rates: rates).minor
    }
    func start(_ m: CivilMonth?) -> Int64? {
      m.flatMap { CivilDate(year: $0.year, month: $0.month, day: 1) }.map(LocalClock.startOfDay)
    }

    guard let now = total(before: nil) else { return NetWorthHistory() }
    let change = start(month).flatMap { total(before: $0) }.map { Money.aed(now.minus($0)) }
    let ends = (0..<(netWorthMonths - 1)).reversed().map { back in
      start(month.adding(months: -back)).flatMap { total(before: $0) }
    }
    let known = ends.compactMap { $0 }
    return NetWorthHistory(monthChange: change, spark: known.count == ends.count ? permille(known + [now]) : [])
  }

  static func permille(_ values: [Int64]) -> [Int] {
    guard let low = values.min(), let high = values.max() else { return [] }
    let span = Int128(high) - Int128(low)
    guard span > 0 else { return values.map { _ in 500 } }
    return values.map { Int((Int128($0) - Int128(low)) * 1000 / span) }
  }
}
