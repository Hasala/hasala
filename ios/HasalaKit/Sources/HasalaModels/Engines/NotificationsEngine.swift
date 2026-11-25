public enum NotificationDestination: Sendable, Hashable {
  case review(PeriodPreset?)
  case bill(BillID)
  case bills
  case category(CategoryID)
  case bankAlerts
  case unreadMail
  case unreadTexts
}

public struct NotificationItem: Sendable, Hashable, Identifiable {
  public enum Disc: Sendable, Hashable {
    case hue(Hue, Glyph)
    case neutral(Glyph)
  }

  public var id: String
  public var disc: Disc
  public var title: String
  public var line: MoneyPhrase
  public var status: StatusTone?
  public var when: String?
  public var destination: NotificationDestination
  public var count: Int

  public init(
    id: String, disc: Disc, title: String, line: MoneyPhrase, status: StatusTone? = nil, when: String?,
    destination: NotificationDestination, count: Int = 0
  ) {
    self.count = count
    self.id = id
    self.disc = disc
    self.title = title
    self.line = line
    self.status = status
    self.when = when
    self.destination = destination
  }
}

public struct NotificationsSnapshot: Sendable, Hashable {
  public var needsALook: [NotificationItem]

  public init(needsALook: [NotificationItem]) {
    self.needsALook = needsALook
  }

  public var count: Int { needsALook.count }
}

public enum NotificationsEngine {
  public static func snapshot(_ s: LedgerState, now: LocalDateTime, review window: ReviewWindow = .all)
    -> NotificationsSnapshot
  {
    let today = now.date
    var dated: [(date: LocalDate, item: NotificationItem)] = []

    let queue = ReviewEngine.queue(s, in: window)
    if !queue.isEmpty {
      let newest = queue.map(\.postedAt.date).max() ?? today
      let unplanned = Fils.sum(queue.filter { $0.direction == .out && !$0.isHeldCopy }) { $0.homeMinor ?? 0 }
      dated.append((newest, NotificationItem(
        id: "review", disc: .hue(.sky, .review),
        title: "\(MoneyFormat.count(queue.count)) transaction\(queue.count == 1 ? "" : "s") to sort",
        line: MoneyPhrase([.text("AED "), .amount(.aed(unplanned), hidden: 3), .text(" to sort")]),
        when: when(newest, today: today), destination: .review(window == .all ? .allTime : nil), count: queue.count
      )))
    }

    let unread = ReviewEngine.unreadMail(s)
    if let newest = unread.first {
      dated.append((newest.receivedOn, NotificationItem(
        id: "unread", disc: .neutral(.envelope), title: ReviewEngine.unreadLine(unread.count),
        line: "Add each one by hand or dismiss it", when: when(newest.receivedOn, today: today), destination: .unreadMail,
        count: unread.count
      )))
    }

    let texts = ReviewEngine.unreadTexts(s)
    if let newest = texts.first {
      dated.append((newest.receivedAt.date, NotificationItem(
        id: "unreadTexts", disc: .neutral(.chat), title: ReviewEngine.unreadTextLine(texts.count),
        line: "Add each one by hand or dismiss it", when: when(newest.receivedAt.date, today: today),
        destination: .unreadTexts, count: texts.count
      )))
    }

    let tracked = s.bills.filter { $0.state == .tracked && !$0.isIncome }

    for b in tracked.filter({ $0.nextDue < today }).sorted(by: { $0.nextDue < $1.nextDue }) {
      let since = b.nextDue.adding(days: 1)
      let c = s.category(b.categoryID)
      dated.append((since, NotificationItem(
        id: "bill.\(b.id)", disc: .hue(c?.hue ?? .sand, c?.glyph ?? .bill),
        title: "\(Bidi.isolate(b.name)) may be late",
        line: MoneyPhrase(stringLiteral: "Usually on the \(PlanEngine.ordinal(b.usualDay)) · no email yet"),
        status: .error, when: when(since, today: today), destination: .bill(b.id)
      )))
    }

    let month = today.yearMonth
    let plan = PlanEngine.snapshot(s, now: now)
    for row in plan.sections.filter({ $0.bucket != .savings }).flatMap(\.rows) where row.verdict == .overBudget && row.budget.minor > 0 {
      let latest = PlanEngine.lines(row.id, s, month: month).map(\.txn.postedAt.date).max() ?? today
      dated.append((latest, NotificationItem(
        id: "over.\(row.id)", disc: .hue(row.hue, row.glyph), title: "\(Bidi.isolate(row.name)) is over budget",
        line: MoneyPhrase([.text("AED "), .amount(.aed(row.spent.minor.minus(row.budget.minor)), hidden: 3), .text(" over")]),
        status: .error, when: when(latest, today: today), destination: .category(row.id)
      )))
    }

    if let late = salaryLate(s, today: today) {
      dated.append((late, NotificationItem(
        id: "salary", disc: .hue(.mint, .salary), title: "Salary not seen yet",
        line: MoneyPhrase(stringLiteral: "Usually the \(s.plan.paydayLastWorkingDay ? "last work day" : PlanEngine.ordinal(s.plan.payday)) · may be in Review"),
        when: when(late, today: today), destination: .review(nil)
      )))
    }

    for b in tracked {
      guard let usual = b.priceChangeFrom else { continue }
      let charged = b.history.first ?? today
      let c = s.category(b.categoryID)
      dated.append((charged, NotificationItem(
        id: "price.\(b.id)", disc: .hue(c?.hue ?? .sand, c?.glyph ?? .bill),
        title: "\(Bidi.isolate(b.name)) has a new price",
        line: MoneyPhrase([
          .amount(b.amount, hidden: 3), .text(" from "), .amount(usual, hidden: 3), .text(" · accept or check"),
        ]),
        when: when(charged, today: today), destination: .bill(b.id)
      )))
    }

    for c in s.billCandidates {
      let cat = s.category(c.categoryID)
      dated.append((c.last, NotificationItem(
        id: "found.\(c.id)", disc: .hue(cat?.hue ?? .lilac, .subscriptions),
        title: "Found a bill: \(Bidi.isolate(c.name))",
        line: MoneyPhrase(stringLiteral: "Seen \(c.seenCount)× · every ~\(c.everyDays) days"),
        when: when(c.last, today: today), destination: .bills
      )))
    }

    let ordered = dated.enumerated().sorted { a, b in
      a.element.date == b.element.date ? a.offset < b.offset : b.element.date < a.element.date
    }
    return NotificationsSnapshot(needsALook: ordered.map(\.element.item))
  }

  public static let salaryLateDays = 3

  public static func salaryLate(_ s: LedgerState, today: LocalDate) -> LocalDate? {
    let month = today.yearMonth
    guard let received = s.plan.receivedIncome(in: month), received.minor <= 0,
      s.plan.expectedIncome(in: month).minor > 0
    else { return nil }
    let since = PlanEngine.payday(s, month: month).adding(days: salaryLateDays)
    return today >= since ? since : nil
  }

  public static func when(_ date: LocalDate, today: LocalDate) -> String {
    let days = date.days(until: today)
    switch days {
    case ...0: return "Today"
    case 1: return "Yesterday"
    case 2...6: return date.weekdayShort
    default: return date.short(today: today)
    }
  }
}
