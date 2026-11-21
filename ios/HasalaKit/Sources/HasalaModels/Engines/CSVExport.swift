public struct ExportRow: Sendable, Hashable {
  public var date: LocalDate
  public var description: String
  public var amount: Money
  public var homeMinor: Int64?
  public var direction: Direction
  public var category: String
  public var merchant: String
  public var note: String
  public var project: String
  public var account: String

  public init(_ t: Txn, _ s: LedgerState) {
    date = t.postedAt.date
    description = t.provenance?.rawMerchant ?? t.merchant
    amount = Money(minor: t.direction == .out ? t.amount.minor.negated : t.amount.minor, currency: t.amount.currency)
    homeMinor = t.homeMinor.map { t.direction == .out ? -$0 : $0 }
    direction = t.direction
    category = s.category(t.categoryID)?.name ?? ""
    merchant = t.title
    note = t.note
    project = s.project(t.projectID)?.name ?? ""
    account = s.account(t.accountID)?.label ?? ""
  }
}

public enum CSVExport {
  public static let headers = [
    "Date", "Description", "Amount", "Currency", "\(Money.home) amount", "Direction", "Category", "Merchant", "Note", "Project", "Account",
  ]

  public static func csv(_ rows: [ExportRow]) -> String {
    var lines = [headers.map(field).joined(separator: ",")]
    for r in rows {
      let cells: [String] = [
        date(r.date),
        text(r.description),
        decimal(r.amount),
        r.amount.currency,
        r.homeMinor.map(decimal) ?? "",
        r.direction == .out ? "Spending" : "Income",
        text(r.category),
        text(r.merchant),
        text(r.note),
        text(r.project),
        text(r.account),
      ]
      lines.append(cells.joined(separator: ","))
    }
    return lines.joined(separator: "\r\n") + "\r\n"
  }

  public static func fileName(_ today: LocalDate) -> String { "hasala-\(date(today)).csv" }

  public static func text(_ value: String) -> String { field(neutralize(value)) }

  public static func neutralize(_ value: String) -> String {
    guard let first = value.unicodeScalars.first else { return value }
    if first == "\t" || first == "\r" || first == "\n" { return "'" + value }
    let blanks: Set<Unicode.Scalar> = [" ", "\t", "\n", "\u{0B}", "\u{0C}", "\r", "\u{A0}"]
    let triggers: Set<Unicode.Scalar> = ["=", "+", "-", "@", "\u{FF1D}", "\u{FF0B}", "\u{FF0D}", "\u{FF20}"]
    if let lead = value.unicodeScalars.first(where: { !blanks.contains($0) }), triggers.contains(lead) {
      return "'" + value
    }
    return value
  }

  public static func field(_ value: String) -> String {
    let needs = value.unicodeScalars.contains { $0 == "\"" || $0 == "," || $0 == "\r" || $0 == "\n" }
    guard needs else { return value }
    return "\"" + value.split(separator: "\"", omittingEmptySubsequences: false).joined(separator: "\"\"") + "\""
  }

  public static func decimal(_ minor: Int64) -> String {
    (minor < 0 ? "-" : "") + MoneyFormat.string(minor, style: .exact).replacingCommas()
  }

  public static func decimal(_ money: Money) -> String {
    (money.minor < 0 ? "-" : "") + MoneyFormat.string(money, style: .exact).replacingCommas()
  }

  public static func date(_ d: LocalDate) -> String {
    func two(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
    return "\(d.year)-\(two(d.month))-\(two(d.day))"
  }
}

extension String {
  fileprivate func replacingCommas() -> String { String(filter { $0 != "," }) }
}
