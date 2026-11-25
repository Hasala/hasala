public struct BillAttention: Sendable, Hashable, Identifiable {
  public enum Kind: Sendable, Hashable { case late(days: Int), priceChange(usual: Money) }

  public var billID: BillID
  public var name: String
  public var glyph: Glyph
  public var kind: Kind
  public var billKind: String
  public var amount: Money
  public var body: MoneyPhrase
  public var pill: StatusPill

  public var id: String {
    switch kind {
    case .late: "late.\(billID)"
    case .priceChange: "price.\(billID)"
    }
  }
}

public struct BillCandidateModel: Sendable, Hashable, Identifiable {
  public var id: String
  public var name: String
  public var amount: Money
  public var evidence: [String]
  public var seenCount: Int
}

public struct BillsIncome: Sendable, Hashable {
  public var label: String
  public var amount: Money
  public var expected: String

  public init(label: String, amount: Money, expected: String) {
    self.label = label
    self.amount = amount
    self.expected = expected
  }
}

public struct BillsSnapshot: Sendable, Hashable {
  public enum Range: Int, Sendable, Hashable, CaseIterable, Identifiable {
    case week = 7, fortnight = 14, month = 30
    public var id: Int { rawValue }
    public var title: String { "\(rawValue) days" }
  }

  public var next14: Money
  public var next14Mark: TotalMark?
  public var incomeLine: MoneyPhrase?
  public var income: BillsIncome?
  public var needsALook: [BillAttention]
  public var found: [BillCandidateModel]
  public var upcoming: [BillRowModel]
  public var range: Range
  public var tracked: Int
  public var recentlyPaid: [BillRowModel]
  public var paidThisMonth: Money
  public var tags: [String: StatusPill]
  public var paidMark: TotalMark?
  public var paused: [BillRowModel] = []
  public var next14Estimates: Int = 0

  public var next14Caption: String? {
    next14Estimates > 0 ? "Includes \(next14Estimates) estimate\(next14Estimates == 1 ? "" : "s")" : nil
  }
  public var ended: [BillRowModel] = []
}

public struct BillDetail: Sendable, Hashable, Identifiable {
  public enum State: Sendable, Hashable {
    case late(days: Int)
    case priceChange(usual: Money)
    case upcoming
    case income
    case paused(since: LocalDate?, until: LocalDate?)
    case ended(on: LocalDate?)
  }

  public var id: BillID
  public var name: String
  public var kind: String
  public var glyph: Glyph
  public var hue: Hue
  public var state: State
  public var pill: StatusPill
  public var amount: Money
  public var approximate: Bool
  public var cadence: String
  public var noticed: MoneyPhrase?
  public var history: [BillHistoryStep]
  public var historyNote: String?
  public var footnote: String
  public var source: Bill.Source = .detected
  public var banners: [BillBanner] = []
  public var notices: [BillNoticeCard] = []
  public var nextDue: LocalDate? = nil

  public var isPaused: Bool {
    if case .paused = state { return true }
    return false
  }

  public var isEnded: Bool {
    if case .ended = state { return true }
    return false
  }

  public var hasPriceNotice: Bool { notices.contains(where: \.isPriceNotice) }

  public var isLate: Bool {
    if case .late = state { return true }
    return false
  }

  public var isPriceChange: Bool {
    if case .priceChange = state { return true }
    return false
  }

  public var isIncome: Bool { state == .income }
}

public struct BillHistoryStep: Sendable, Hashable, Identifiable {
  public enum Kind: Sendable, Hashable {
    case expected(late: Bool)
    case paid
  }

  public var id: String { "\(kind == .paid ? "paid" : "expected").\(date.ordinal)" }
  public var date: LocalDate
  public var kind: Kind
  public var note: String?
  public var amount: Money?

  public var title: String { date.short }
}

public struct BillBanner: Sendable, Hashable, Identifiable {
  public var id: String
  public var icon: BillBannerIcon
  public var text: MoneyPhrase

  public init(id: String, icon: BillBannerIcon, text: MoneyPhrase) {
    self.id = id
    self.icon = icon
    self.text = text
  }
}

public enum BillBannerIcon: String, Sendable, Hashable { case clock, calendar, tag }

public struct BillNoticeCard: Sendable, Hashable, Identifiable {
  public enum Action: Sendable, Hashable {
    case acceptPrice(Money, from: LocalDate)
    case resume, reactivate, reapply, dismiss
  }

  public struct Button: Sendable, Hashable {
    public var title: String
    public var action: Action

    public init(title: String, action: Action) {
      self.title = title
      self.action = action
    }
  }

  public var id: String
  public var title: String
  public var tone: StatusTone
  public var body: MoneyPhrase
  public var primary: Button
  public var secondary: Button?

  public init(id: String, title: String, tone: StatusTone, body: MoneyPhrase, primary: Button, secondary: Button?) {
    self.id = id
    self.title = title
    self.tone = tone
    self.body = body
    self.primary = primary
    self.secondary = secondary
  }

  var isPriceNotice: Bool {
    if case .acceptPrice = primary.action { return true }
    return false
  }
}

public enum BillsEngine {
  public static func snapshot(_ s: LedgerState, now: LocalDateTime, range: BillsSnapshot.Range = .month)
    -> BillsSnapshot
  {
    let today = now.date
    let tracked = s.bills.filter { $0.state == .tracked }
    let in14 = today.adding(days: 14)
    let next14 = s.homeTotal(tracked.filter { !$0.isIncome && $0.nextDue <= in14 }.map(\.amount))

    let incomeBill = tracked.filter { $0.isIncome && $0.nextDue >= today && $0.nextDue <= in14 }.min { $0.nextDue < $1.nextDue }
    let incomeLine = incomeBill.map {
      MoneyPhrase([.signedMoney($0.amount, style: .exact, hiddenGlyphs: 4), .text(" expected \($0.nextDue.short)")])
    }
    let income = incomeBill.map {
      BillsIncome(label: $0.kind, amount: $0.amount, expected: "expected \($0.nextDue.short)")
    }

    let attention = attention(s, today: today)

    let found = s.billCandidates.map { c in
      BillCandidateModel(
        id: c.id, name: c.name, amount: c.amount,
        evidence: ["Seen \(c.seenCount)×", "Every ~\(c.everyDays) days", "Last on \(c.last.dayMonth)"],
        seenCount: c.seenCount
      )
    }

    let horizon = today.adding(days: range.rawValue)
    let upcoming = tracked.filter { $0.nextDue <= horizon && $0.priceChangeFrom == nil }
      .filter { s.category($0.categoryID)?.role != .saving }
      .sorted { $0.nextDue < $1.nextDue }
      .map { upcomingRow($0, s, today: today) }

    let month = today.yearMonth
    let paid = s.txns.filter {
      $0.countsInPlan && $0.billID != nil && $0.postedAt.date.yearMonth == month && $0.direction == .out
        && s.category($0.categoryID)?.role == .bill
    }.sorted { $0.postedAt > $1.postedAt }
    var tags: [String: StatusPill] = [:]
    let paidRows = paid.map { t in
      let b = t.billID.flatMap(s.bill)
      if b?.priceChangeFrom != nil { tags[t.id] = StatusPill("Price change", tone: .warning, showsDot: false) }
      let detail: [PlanDetailPart] = [.text(MoneyPhrase(stringLiteral:
        "\(t.postedAt.date.short)" + (s.account(t.accountID).map { " · \($0.shortName)" } ?? "")))]
      let c = s.category(t.categoryID)
      return BillRowModel(
        id: t.id, name: b?.name ?? t.merchant, glyph: c?.glyph ?? .utilities,
        hue: c?.hue ?? .sand, detail: detail, amount: t.amount, approximate: false,
        isIncome: false, trailingNote: nil
      )
    }

    let marked = markedPaid(s, month: month)
    var dated = zip(paid, paidRows).map { ($0.postedAt.date, $1) }
    for (b, p) in marked {
      let c = s.category(b.categoryID)
      dated.append((p.due, BillRowModel(
        id: "marked:\(b.id):\(p.due)", name: b.name, glyph: c?.glyph ?? .utilities, hue: c?.hue ?? .sand,
        detail: [.text(MoneyPhrase(stringLiteral: "\(p.due.short) · Marked paid"))], amount: p.amount ?? b.amount,
        approximate: false, isIncome: false, trailingNote: nil)))
    }
    let rows = dated.enumerated().sorted { x, y in x.element.0 == y.element.0 ? x.offset < y.offset : x.element.0 > y.element.0 }
      .map(\.element.1)
    let markedTotal = s.homeTotal(marked.map { $0.1.amount ?? $0.0.amount })
    var paidMark = TotalMark.unrated(paid)
    if let m = markedTotal.mark, m.leftOutCount > 0 {
      var merged = paidMark ?? TotalMark()
      for (k, v) in m.leftOut { merged.leftOut[k, default: 0] += v }
      paidMark = merged
    }
    let estimates = tracked.filter { !$0.isIncome && $0.approximate && $0.nextDue <= in14 }.count

    var out = BillsSnapshot(
      next14: next14.money, next14Mark: next14.mark, incomeLine: incomeLine, income: income, needsALook: attention, found: found,
      upcoming: upcoming, range: range, tracked: tracked.count, recentlyPaid: rows,
      paidThisMonth: .aed(Fils.sum(paid) { $0.homeMinor ?? 0 }.plus(markedTotal.minor)), tags: tags, paidMark: paidMark,
      paused: pausedRows(s), ended: endedRows(s)
    )
    out.next14Estimates = estimates
    return out
  }

  static func markedPaid(_ s: LedgerState, month: YearMonth) -> [(Bill, BillPayment)] {
    s.bills.filter { $0.state != .dismissed && !$0.isIncome }.flatMap { b in
      b.payments.filter { $0.link == .marked && $0.txnID == nil && $0.due.yearMonth == month }.map { (b, $0) }
    }
  }

  public static func toCheck(_ s: LedgerState, today: LocalDate) -> Int {
    Set(attention(s, today: today).map(\.billID)).count + s.billCandidates.count
  }

  static func attention(_ s: LedgerState, today: LocalDate) -> [BillAttention] {
    let tracked = s.bills.filter { $0.state == .tracked }
    var attention: [BillAttention] = []
    for b in tracked where !b.isIncome && b.nextDue < today {
      let days = b.nextDue.days(until: today)
      attention.append(BillAttention(
        billID: b.id, name: b.name, glyph: ActivityEngine.glyph(b, s), kind: .late(days: days), billKind: b.kind,
        amount: b.amount,
        body: MoneyPhrase(stringLiteral:
          "\(b.kind) usually arrives on the \(PlanEngine.ordinal(b.usualDay)). No bank email yet."),
        pill: StatusPill(pastUsual(days), tone: .error)
      ))
    }
    for b in tracked where !b.isIncome {
      guard let usual = b.priceChangeFrom else { continue }
      attention.append(BillAttention(
        billID: b.id, name: b.name, glyph: ActivityEngine.glyph(b, s), kind: .priceChange(usual: usual),
        billKind: b.kind, amount: b.amount, body: priceChange(b, usual: usual),
        pill: StatusPill("Price change", tone: .warning)
      ))
    }
    return attention
  }

  static let farFuture = LocalDate(9999, 12, 31)

  static func pausedRows(_ s: LedgerState) -> [BillRowModel] {
    s.bills.filter { $0.state == .paused }
      .sorted { ($0.pausedUntil ?? farFuture, $0.name) < ($1.pausedUntil ?? farFuture, $1.name) }
      .map { stateRow($0, s, line: $0.pausedUntil.map { "Paused until \($0.dayMonth)" } ?? "Paused") }
  }

  static func endedRows(_ s: LedgerState) -> [BillRowModel] {
    s.bills.filter { $0.state == .ended }
      .sorted { ($0.endedOn ?? farFuture, $0.name) > ($1.endedOn ?? farFuture, $1.name) }
      .map { stateRow($0, s, line: $0.endedOn.map { "Ended \($0.dayMonth)" } ?? "Ended") }
  }

  static func stateRow(_ b: Bill, _ s: LedgerState, line: String) -> BillRowModel {
    BillRowModel(id: b.id, name: b.name, glyph: ActivityEngine.glyph(b, s), hue: ActivityEngine.hue(b, s),
                 detail: [.text(MoneyPhrase(stringLiteral: line))], amount: b.amount,
                 approximate: b.approximate, isIncome: b.isIncome)
  }

  static func upcomingRow(_ b: Bill, _ s: LedgerState, today: LocalDate) -> BillRowModel {
    let detail: [PlanDetailPart]
    if b.nextDue < today {
      detail = [.status("Expected the \(b.usualDayPhrase)", .error)]
    } else {
      detail = [.text(MoneyPhrase(stringLiteral:
        "\(b.nextDue.short) · \(ActivityEngine.inDays(today.days(until: b.nextDue)))"))]
    }
    return BillRowModel(
      id: b.id, name: b.name, glyph: ActivityEngine.glyph(b, s), hue: ActivityEngine.hue(b, s), detail: detail,
      amount: b.amount, approximate: b.approximate, isIncome: b.isIncome, trailingNote: nil
    )
  }

  static func pastUsual(_ days: Int) -> String {
    "\(days) day\(days == 1 ? "" : "s") past usual"
  }

  static func priceChange(_ b: Bill, usual: Money) -> MoneyPhrase {
    charged(b.amount, usual: usual, currency: Money.home, after: b.history.first.map { " on \($0.short)" } ?? "")
  }

  static func charged(_ charged: Money, usual: Money, currency: String, after: String) -> MoneyPhrase {
    let difference = charged.minor.minus(usual.minor)
    return MoneyPhrase([
      .text("Charged "), .amount(Money(minor: Int64(clamping: difference.magnitude), currency: currency)),
      .text(" \(difference < 0 ? "less" : "more") than usual ("), .amount(usual), .text(")\(after)."),
    ])
  }

  static let onTimeWindow = 3

  public static func detail(_ s: LedgerState, now: LocalDateTime, bill id: BillID) -> BillDetail? {
    guard let b = s.bill(id), b.state != .dismissed else { return nil }
    let today = now.date
    let usualDay = b.usualDayPhrase
    let untilDue = today.days(until: b.nextDue)

    let state: BillDetail.State
    let pill: StatusPill
    switch b.state {
    case .paused:
      state = .paused(since: b.pausedSince, until: b.pausedUntil)
      pill = StatusPill("Paused", tone: .warning)
    case .ended, .dismissed:
      state = .ended(on: b.endedOn)
      pill = StatusPill("Ended", tone: .accent)
    case .tracked:
      if b.isIncome {
        state = .income
        pill = StatusPill("Expected \(ActivityEngine.inDays(max(0, untilDue)))", tone: .success)
      } else if b.nextDue < today {
        state = .late(days: -untilDue)
        pill = StatusPill(pastUsual(-untilDue), tone: .error)
      } else if let usual = b.priceChangeFrom {
        state = .priceChange(usual: usual)
        pill = StatusPill("Price change", tone: .warning)
      } else {
        state = .upcoming
        pill = StatusPill("Due \(ActivityEngine.inDays(untilDue))", tone: .accent)
      }
    }

    var cadence = [cadencePhrase(b), "usually the \(usualDay)"]
    if let account = s.account(b.accountID) { cadence.append(account.shortName) }

    let notices = noticeCards(b)
    let priceNotice = notices.contains(where: \.isPriceNotice)
    let noticed: MoneyPhrase?
    switch state {
    case .late:
      noticed = MoneyPhrase(stringLiteral: lateNotice(b) + " No bank email yet this month.")
    case .priceChange(let usual):
      noticed = priceNotice ? nil : priceChange(b, usual: usual)
    case .upcoming, .income, .paused, .ended:
      noticed = nil
    }

    var steps: [BillHistoryStep] = []
    switch state {
    case .late:
      steps.append(BillHistoryStep(date: b.nextDue, kind: .expected(late: true),
                                   note: "Expected · no bank email yet", amount: amount(b, on: b.nextDue)))
    case .upcoming, .income:
      steps.append(BillHistoryStep(date: b.nextDue, kind: .expected(late: false),
                                   note: "Expected · \(ActivityEngine.inDays(untilDue))", amount: amount(b, on: b.nextDue)))
    case .priceChange, .paused, .ended:
      break
    }
    steps += paidSteps(b, s)

    let onTime = arrivals(b).filter { abs($0.offset) <= onTimeWindow }.count
    let historyNote: String? = b.history.isEmpty
      ? nil : onTime == b.history.count ? "\(onTime) on time" : "\(onTime) of \(b.history.count) on time"

    var d = BillDetail(
      id: b.id, name: b.name, kind: b.kind, glyph: ActivityEngine.glyph(b, s), hue: ActivityEngine.hue(b, s),
      state: state, pill: pill, amount: b.amount, approximate: b.approximate,
      cadence: cadence.joined(separator: " · "), noticed: noticed, history: steps, historyNote: historyNote,
      footnote: b.source == .manual
        ? "You added this one. Nothing is shared with \(payee(b))."
        : "Found in your history. Nothing is shared with \(payee(b))."
    )
    d.source = b.source
    d.banners = banners(b)
    d.notices = notices
    d.nextDue = b.state == .tracked || b.state == .paused ? b.nextDue : nil
    return d
  }

  static func cadencePhrase(_ b: Bill) -> String {
    let unit = switch b.cadence {
    case .weekly: "week"
    case .monthly: "month"
    case .yearly: "year"
    }
    return b.every <= 1 ? "every \(unit)" : "every \(b.every) \(unit)s"
  }

  static func banners(_ b: Bill) -> [BillBanner] {
    var out: [BillBanner] = []
    if b.state == .paused {
      let since = b.pausedSince.map { " since \($0.dayMonth)" } ?? ""
      let until = b.pausedUntil.map { ", until \($0.dayMonth)" } ?? ". Nothing is expected until you resume it"
      out.append(BillBanner(id: "paused", icon: .clock, text: MoneyPhrase(stringLiteral: "Paused\(since)\(until).")))
    }
    if b.state == .ended {
      let on = b.endedOn.map { " on \($0.dayMonth)" } ?? ""
      out.append(BillBanner(id: "ended", icon: .calendar,
                            text: MoneyPhrase(stringLiteral: "Ended\(on). No more payments are expected.")))
    }
    if let next = b.nextAmount, let from = b.nextAmountFrom, b.state != .ended || (b.endedOn.map { from <= $0 } ?? true) {
      out.append(BillBanner(id: "nextAmount", icon: .tag,
                            text: MoneyPhrase([.text("Changes to "), .amount(next), .text(" from \(from.dayMonth)")])))
    }
    return out
  }

  static func noticeCards(_ b: Bill) -> [BillNoticeCard] {
    b.notices.map { n in
      switch n.kind {
      case .priceChange(let usual, let charged, let from):
        return BillNoticeCard(
          id: n.id, title: "Price change", tone: .warning,
          body: Self.charged(charged, usual: usual, currency: charged.currency, after: " on \(from.short)"),
          primary: .init(title: "Accept from \(from.dayMonth)", action: .acceptPrice(charged, from: from)),
          secondary: .init(title: "Not now", action: .dismiss))
      case .chargedWhilePaused(let charged, let on):
        return BillNoticeCard(
          id: n.id, title: "Charged while paused", tone: .warning,
          body: MoneyPhrase([.text("A payment of "), .amount(charged), .text(" arrived on \(on.short) while \(b.name) was paused.")]),
          primary: .init(title: b.state == .paused ? "Resume" : "Got it", action: b.state == .paused ? .resume : .dismiss),
          secondary: b.state == .paused ? .init(title: "It's fine", action: .dismiss) : nil)
      case .chargedAfterEnd(let charged, let on):
        return BillNoticeCard(
          id: n.id, title: "Charged after you ended it", tone: .error,
          body: MoneyPhrase([.text("A payment of "), .amount(charged), .text(" arrived on \(on.short).")]),
          primary: .init(title: "Start tracking again", action: .reactivate),
          secondary: .init(title: "It's fine", action: .dismiss))
      case .changedOnTwoDevices(let summary):
        return BillNoticeCard(
          id: n.id, title: "Changed on two iPhones", tone: .accent,
          body: MoneyPhrase(stringLiteral: summary),
          primary: .init(title: "Re-apply", action: .reapply),
          secondary: .init(title: "Keep", action: .dismiss))
      }
    }
  }

  static func paidSteps(_ b: Bill, _ s: LedgerState) -> [BillHistoryStep] {
    guard !b.payments.isEmpty else {
      return b.history.enumerated().map { i, date in
        BillHistoryStep(date: date, kind: .paid, note: nil, amount: paidAmount(b, s, on: date, index: i))
      }
    }
    var used = Set<LocalDate>()
    return b.payments.sorted { $0.due > $1.due }.enumerated().compactMap { i, p in
      let txn = p.txnID.flatMap(s.txn)
      let date = txn?.postedAt.date
        ?? b.history.first { BillDueDates.nearest(b, to: $0) == p.due }
        ?? p.due
      guard used.insert(date).inserted else { return nil }
      let figure: Money?
      let note: String?
      switch p.link {
      case .linked, .matched:
        if p.txnID == nil {
          figure = p.amount
        } else if let txn, !txn.archived {
          figure = txn.amount
        } else {
          figure = nil
        }
        note = p.link == .linked ? "Linked by you" : nil
      case .marked:
        figure = paidAmount(b, s, on: date, index: i)
        note = "Marked paid"
      }
      return BillHistoryStep(date: date, kind: .paid, note: note, amount: figure)
    }
  }

  static func lateNotice(_ b: Bill) -> String {
    let order = arrivals(b).sorted { ($0.offset, $0.date.day) < ($1.offset, $1.date.day) }
    guard let low = order.first?.date.day, let high = order.last?.date.day else {
      return "It usually arrives on the \(b.usualDayPhrase)."
    }
    let count = order.count
    let subject = count == 1 ? "Your last payment" : "Your last \(count) payments"
    return low == high
      ? "\(subject) arrived on the \(PlanEngine.ordinal(low))."
      : "\(subject) arrived between the \(PlanEngine.ordinal(low)) and \(PlanEngine.ordinal(high))."
  }

  static func arrivals(_ b: Bill) -> [(date: LocalDate, offset: Int)] {
    b.history.map { ($0, BillDueDates.nearest(b, to: $0).days(until: $0)) }
  }

  static func paidAmount(_ b: Bill, _ s: LedgerState, on date: LocalDate, index: Int) -> Money {
    if let t = s.txns.first(where: { $0.billID == b.id && $0.postedAt.date == date }) { return t.amount }
    if let usual = b.priceChangeFrom, index > 0 { return usual }
    return b.amount
  }

  static func payee(_ b: Bill) -> String {
    guard let range = b.name.firstRange(of: " · ") else { return b.name }
    return String(b.name[range.upperBound...])
  }
}
