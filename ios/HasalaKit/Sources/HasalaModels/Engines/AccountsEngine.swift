public struct AccountRowModel: Sendable, Hashable, Identifiable {
  public enum Plate: Sendable, Hashable {
    case initials(String)
    case cash
  }

  public var id: AccountID
  public var name: String
  public var plate: Plate
  public var hue: Hue
  public var balance: Money
  public var detail: String
}

public struct NetWorthChart: Sendable, Hashable {
  public var points: [Int]
  public var months: [String]
}

public struct AccountsSnapshot: Sendable, Hashable {
  public var netWorth: Money
  public var netWorthMark: TotalMark?
  public var monthChange: Money?
  public var chart: NetWorthChart?
  public var everyday: [AccountRowModel]
  public var everydayTotal: Money
  public var everydayMark: TotalMark?
  public var tracking: [AccountRowModel]
  public var count: Int
  public var hasBalances: Bool
}

public enum AccountsEngine {
  public static func snapshot(_ s: LedgerState, now: LocalDateTime) -> AccountsSnapshot {
    let rows = s.accounts.map(row)
    let everyday = zip(s.accounts, rows).filter { $0.0.inPlan }.map(\.1)
    let tracking = zip(s.accounts, rows).filter { !$0.0.inPlan }.map(\.1)
    let netWorth = s.homeTotal(s.accounts.map(\.balance))
    let everydayTotal = s.homeTotal(s.accounts.filter(\.inPlan).map(\.balance))
    return AccountsSnapshot(
      netWorth: netWorth.money,
      netWorthMark: netWorth.mark,
      monthChange: s.netWorth.monthChange,
      chart: s.netWorth.spark.isEmpty
        ? nil : NetWorthChart(points: Array(s.netWorth.spark.suffix(12)), months: months(ending: now.date.yearMonth)),
      everyday: everyday,
      everydayTotal: everydayTotal.money,
      everydayMark: everydayTotal.mark,
      tracking: tracking,
      count: s.accounts.count,
      hasBalances: s.accounts.contains { !$0.balance.isZero }
    )
  }

  static func row(_ a: Account) -> AccountRowModel {
    let plate: AccountRowModel.Plate = a.kind == .cash ? .cash : .initials(initials(a.shortName))
    let detail = [a.last4.map { "···\($0)" }, a.detail.isEmpty ? nil : a.detail].compactMap { $0 }
      .joined(separator: " · ")
    return AccountRowModel(id: a.id, name: a.name, plate: plate, hue: hue(a.kind), balance: a.balance, detail: detail)
  }

  static func initials(_ name: String) -> String {
    let marks = name.split(whereSeparator: \.isWhitespace).compactMap { word -> String? in
      let letters = word.filter(\.isLetter)
      guard let first = letters.first, first.isUppercase else { return nil }
      return letters.count <= 4 && letters.allSatisfy(\.isUppercase) ? String(letters) : String(first)
    }.joined()
    let fallback = name.first(where: \.isLetter).map { String($0).uppercased() } ?? String(name.prefix(1))
    return String((marks.isEmpty ? fallback : marks).prefix(4))
  }

  static func hue(_ kind: AccountKind) -> Hue {
    switch kind {
    case .current: .sky
    case .credit: .sand
    case .cash: .mint
    case .investment: .lilac
    }
  }

  static func months(ending month: YearMonth) -> [String] {
    var out: [String] = []
    var m = month
    for _ in 0..<12 {
      out.insert(String(m.shortName.prefix(1)), at: 0)
      m = m.previous
    }
    return out
  }
}
