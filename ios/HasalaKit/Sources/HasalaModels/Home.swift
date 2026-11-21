public enum Hue: String, Sendable, Hashable, CaseIterable, Codable {
  case sky, sand, rose, lilac, mint, peach, other
}

public enum Bucket: String, Sendable, Hashable, CaseIterable, Codable {
  case needs, wants, savings, income, project, other

  public var hue: Hue {
    switch self {
    case .needs: .sand
    case .wants: .lilac
    case .savings: .mint
    case .income: .sky
    case .project: .peach
    case .other: .other
    }
  }
}

public enum Verdict: String, Sendable, Hashable, Codable {
  case onTrack, overPace, overBudget, done

  public var label: String {
    switch self {
    case .onTrack: "On track"
    case .overPace: "Over pace"
    case .overBudget: "Over budget"
    case .done: "Done"
    }
  }
}

public enum Glyph: String, Sendable, Hashable, Codable {
  case review, insurance, utilities, travel, savingsJar, dining, budgetPie, trendUp, add
  case rent, groceries, transport, shopping, salary, transfer, flag
  case healthcare, entertainment, subscriptions, investments, debt, freelance, refunds
  case bank, tag, bill, wallet, envelope, rule, chat
}

public enum StatusTone: String, Sendable, Hashable, Codable {
  case accent, error, warning, success
}

public struct StatusPill: Sendable, Hashable, Codable {
  public var text: String
  public var tone: StatusTone
  public var showsDot: Bool

  public init(_ text: String, tone: StatusTone, showsDot: Bool = true) {
    self.text = text
    self.tone = tone
    self.showsDot = showsDot
  }
}

public struct HeaderState: Sendable, Hashable {
  public var avatarInitial: String

  public init(avatarInitial: String) {
    self.avatarInitial = avatarInitial
  }
}

public struct HeroTile: Sendable, Hashable, Identifiable {
  public var id: String { label }
  public var label: String
  public var value: Money
  public var style: MoneyStyle

  public var isApart: Bool { label == "Savings" }

  public init(_ label: String, _ value: Money, style: MoneyStyle = .exact) {
    self.label = label
    self.value = value
    self.style = style
  }
}

public struct HeroMonthBar: Sendable, Hashable, Identifiable {
  public var id: YearMonth { month }
  public var month: YearMonth
  public var spent: Money
  public var plan: Money
  public var verdict: Verdict
  public var showsYear: Bool

  public init(month: YearMonth, spent: Money, plan: Money, verdict: Verdict, showsYear: Bool = false) {
    self.month = month
    self.spent = spent
    self.plan = plan
    self.verdict = verdict
    self.showsYear = showsYear
  }

  public var label: String {
    let yy = month.year % 100
    return showsYear ? "\(month.shortName) '\(yy < 10 ? "0" : "")\(yy)" : month.shortName
  }
}

public struct AboutNowRow: Sendable, Hashable, Identifiable {
  public var id: String
  public var title: String
  public var detail: MoneyPhrase
  public var destination: NotificationDestination

  public init(id: String, title: String, detail: MoneyPhrase, destination: NotificationDestination) {
    self.id = id
    self.title = title
    self.detail = detail
    self.destination = destination
  }
}

public struct SpendHero: Sendable, Hashable {
  public enum State: Sendable, Hashable {
    case live
    case noPlan
    case syncing
    case ended
    case range
  }

  public var state: State
  public var overline: String
  public var spent: Money
  public var plan: Money
  public var tick: Money?
  public var verdict: Verdict?
  public var word: MoneyPhrase
  public var fact: MoneyPhrase?
  public var caption: MoneyPhrase
  public var tiles: [HeroTile]
  public var wash: Hue
  public var bars: [HeroMonthBar]
  public var note: MoneyPhrase?
  public var notCounted: NotCounted?
  public var unrated: TotalMark?
  public var unsorted: Money?
  public var heldOut: Money?
  public var overCategory: CategoryID?

  public var tickShare: Permille? {
    guard let tick, plan.minor > 0 else { return nil }
    return Permille.ratio(tick.minor, of: plan.minor)
  }

  public var tickPhrase: MoneyPhrase? {
    tick.map { MoneyPhrase([.text("today's mark AED "), .amount($0, hidden: 3)]) }
  }

  public var heldOutLine: MoneyPhrase? {
    heldOut.map { MoneyPhrase([.text("Maybe a repeat: AED "), .amount($0, hidden: 3), .text(" not counted until you answer")]) }
  }

  public var unsortedLine: MoneyPhrase? {
    unsorted.map { MoneyPhrase([.text("To sort: AED "), .amount($0, hidden: 3), .text(", counted above")]) }
  }

  public struct NotCounted: Sendable, Hashable {
    public var amount: Money
    public var projects: Int
    public var projectID: ProjectID?
    public var line: MoneyPhrase

    public init(amount: Money, projects: Int, projectID: ProjectID?, line: MoneyPhrase) {
      self.amount = amount
      self.projects = projects
      self.projectID = projectID
      self.line = line
    }
  }

  public init(
    state: State = .live, overline: String, spent: Money, plan: Money, tick: Money?, verdict: Verdict?,
    word: MoneyPhrase, fact: MoneyPhrase?, caption: MoneyPhrase, tiles: [HeroTile], wash: Hue,
    bars: [HeroMonthBar] = [], note: MoneyPhrase? = nil, notCounted: NotCounted? = nil, unsorted: Money? = nil,
    heldOut: Money? = nil
  ) {
    self.unsorted = unsorted
    self.heldOut = heldOut
    self.bars = bars
    self.note = note
    self.notCounted = notCounted
    self.state = state
    self.overline = overline
    self.spent = spent
    self.plan = plan
    self.tick = tick
    self.verdict = verdict
    self.word = word
    self.fact = fact
    self.caption = caption
    self.tiles = tiles
    self.wash = wash
  }

  public var left: Money { Money(minor: plan.minor.minus(spent.minor), currency: plan.currency) }
}

public enum PosterFigure: Sendable, Hashable {
  case count(Int, unit: String)
  case money(Money)
  case word(String)
}

public struct BucketPaceRow: Sendable, Hashable, Codable, Identifiable {
  public var id: Bucket { bucket }
  public var bucket: Bucket
  public var spent: Money
  public var budget: Money
  public var verdict: Verdict

  public init(bucket: Bucket, spent: Money, budget: Money, verdict: Verdict) {
    self.bucket = bucket
    self.spent = spent
    self.budget = budget
    self.verdict = verdict
  }

  public var left: Money { Money(minor: budget.minor.minus(spent.minor), currency: budget.currency) }
  public var progress: Permille { Permille.ratio(spent.minor, of: budget.minor) }
}

public struct BudgetPaceWidget: Sendable, Hashable, Codable {
  public var monthGone: String
  public var rows: [BucketPaceRow]
  public var unsorted: Money?

  public var unsortedCaption: MoneyPhrase? {
    unsorted.map { MoneyPhrase([.text("Not in a bucket yet: AED "), .amount($0, .rounded, hidden: 3)]) }
  }

  public init(monthGone: String, rows: [BucketPaceRow], unsorted: Money? = nil) {
    self.unsorted = unsorted
    self.monthGone = monthGone
    self.rows = rows
  }
}

public struct NextBillWidget: Sendable, Hashable, Codable {
  public var glyph: Glyph
  public var hue: Hue
  public var due: StatusPill
  public var amount: Money
  public var caption: String

  public init(glyph: Glyph, hue: Hue, due: StatusPill, amount: Money, caption: String) {
    self.glyph = glyph
    self.hue = hue
    self.due = due
    self.amount = amount
    self.caption = caption
  }
}

public struct NetWorthWidget: Sendable, Hashable, Codable {
  public var total: Money
  public var change: MoneyPhrase
  public var spark: [Permille]
  public var mark: TotalMark?

  public init(total: Money, change: MoneyPhrase, spark: [Permille], mark: TotalMark? = nil) {
    self.total = total
    self.change = change
    self.spark = spark
    self.mark = mark
  }
}

public struct ProjectWidget: Sendable, Hashable, Codable {
  public enum Unit: String, Sendable, Hashable, Codable {
    case left, over, spent
  }

  public var id: ProjectID?
  public var name: String
  public var glyph: Glyph
  public var left: Money
  public var unit: Unit
  public var caption: MoneyPhrase
  public var progress: Permille?

  public init(
    id: ProjectID? = nil, name: String, glyph: Glyph, left: Money, unit: Unit = .left, caption: MoneyPhrase,
    progress: Permille?
  ) {
    self.id = id
    self.name = name
    self.glyph = glyph
    self.left = left
    self.unit = unit
    self.caption = caption
    self.progress = progress
  }
}

public struct GoalWidget: Sendable, Hashable, Codable {
  public var id: GoalID?
  public var name: String
  public var glyph: Glyph
  public var progress: Permille
  public var caption: MoneyPhrase

  public init(id: GoalID? = nil, name: String, glyph: Glyph, progress: Permille, caption: MoneyPhrase) {
    self.id = id
    self.name = name
    self.glyph = glyph
    self.progress = progress
    self.caption = caption
  }

  public var percentLabel: String { "\(progress.value / 10)%" }
}

public struct MiniTxnRow: Sendable, Hashable, Codable, Identifiable {
  public var id: String
  public var merchant: String
  public var glyph: Glyph
  public var hue: Hue
  public var detail: String
  public var amount: Money
  public var isIncome: Bool
  public var monogram: String?
  public var toReview: Bool
  public var reviewReason: TxnReviewReason?
  public var project: Project?
  public var estimate: Bool = false
  public var notCounted: Bool = false
  public var spokenDetail: String?

  public struct Project: Sendable, Hashable, Codable {
    public var id: ProjectID
    public var name: String

    public init(id: ProjectID, name: String) {
      self.id = id
      self.name = name
    }
  }

  public init(
    id: String, merchant: String, glyph: Glyph, hue: Hue, detail: String, amount: Money,
    isIncome: Bool = false, monogram: String? = nil, toReview: Bool = false, reviewReason: TxnReviewReason? = nil,
    project: Project? = nil
  ) {
    self.id = id
    self.merchant = merchant
    self.glyph = glyph
    self.hue = hue
    self.detail = detail
    self.amount = amount
    self.isIncome = isIncome
    self.monogram = monogram
    self.toReview = toReview
    self.reviewReason = reviewReason
    self.project = project
  }
}

public struct TodayWidget: Sendable, Hashable, Codable {
  public var summary: MoneyPhrase
  public var rows: [MiniTxnRow]

  public init(summary: MoneyPhrase, rows: [MiniTxnRow]) {
    self.summary = summary
    self.rows = rows
  }
}

public enum HomeWidget: Sendable, Hashable, Identifiable, CanvasSized {
  case budgetPace(BudgetPaceWidget)
  case nextBill(NextBillWidget)
  case netWorth(NetWorthWidget)
  case project(ProjectWidget)
  case goal(GoalWidget)
  case today(TodayWidget)
  case spentSoFar(SpentSoFarWidget)
  case categoryWatch(CategoryWatchWidget)
  case comingUp(ComingUpWidget)
  case toReview(ToReviewWidget)

  public enum Size: String, Sendable, Hashable, Codable { case small, medium }

  public var kind: HomeWidgetKind {
    switch self {
    case .budgetPace: .budgetPace
    case .nextBill: .nextBill
    case .netWorth: .netWorth
    case .project: .project
    case .goal: .goal
    case .today: .today
    case .spentSoFar: .spentSoFar
    case .categoryWatch: .categoryWatch
    case .comingUp: .comingUp
    case .toReview: .toReview
    }
  }

  public var size: Size { kind.size }

  public var id: String {
    switch self {
    case .budgetPace: "budgetPace"
    case .nextBill: "nextBill"
    case .netWorth: "netWorth"
    case .project(let p): "project." + p.name
    case .goal(let g): "goal." + g.name
    case .today: "today"
    case .spentSoFar: "spentSoFar"
    case .categoryWatch(let c): "categoryWatch." + c.id
    case .comingUp: "comingUp"
    case .toReview: "toReview"
    }
  }
}

public struct HomeSnapshot: Sendable, Hashable {
  public var header: HeaderState
  public var hero: SpendHero
  public var notifications: NotificationsSnapshot
  public var widgets: [HomeWidget]
  public var period: Period?
  public var canvasTitle: String
  public var aboutNow: [AboutNowRow]
  public var monthClosed: MonthClosed?

  public struct MonthClosed: Sendable, Hashable {
    public var month: YearMonth
    public var word: MoneyPhrase
    public var over: Bool
    public var toSort: Int
    public var toSortLine: String?
  }

  public init(
    header: HeaderState, hero: SpendHero, notifications: NotificationsSnapshot, widgets: [HomeWidget],
    period: Period? = nil, canvasTitle: String = "Your widgets", aboutNow: [AboutNowRow] = []
  ) {
    self.header = header
    self.hero = hero
    self.notifications = notifications
    self.widgets = widgets
    self.period = period
    self.canvasTitle = canvasTitle
    self.aboutNow = aboutNow
  }

  public var isThisMonth: Bool { period == nil }
}

public extension Array where Element: CanvasSized {
  var canvasRows: [[Element]] {
    var rows: [[Element]] = []
    var pending: Element?
    for w in self {
      switch w.size {
      case .medium:
        if let p = pending { rows.append([p]); pending = nil }
        rows.append([w])
      case .small:
        if let p = pending { rows.append([p, w]); pending = nil } else { pending = w }
      }
    }
    if let p = pending { rows.append([p]) }
    return rows
  }
}
