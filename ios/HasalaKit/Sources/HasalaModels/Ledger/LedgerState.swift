public typealias TxnID = String
public typealias CategoryID = String
public typealias AccountID = String
public typealias BillID = String
public typealias ProjectID = String
public typealias GoalID = String
public typealias RuleID = String

public enum CategoryKind: String, Sendable, Hashable, Codable {
  case spending, income, excluded
}

public enum CategoryRole: String, Sendable, Hashable, Codable {
  case everyday
  case bill
  case saving
  case none
}

public struct Category: Sendable, Hashable, Identifiable, Codable {
  public var id: CategoryID
  public var name: String
  public var kind: CategoryKind
  public var bucket: Bucket
  public var glyph: Glyph
  public var role: CategoryRole
  public var archived: Bool
  public var parent: CategoryID?
  public var builtin: Bool

  public init(
    id: CategoryID, name: String, kind: CategoryKind = .spending, bucket: Bucket, glyph: Glyph,
    role: CategoryRole = .everyday, archived: Bool = false, parent: CategoryID? = nil, builtin: Bool = false
  ) {
    self.id = id
    self.name = name
    self.kind = kind
    self.bucket = bucket
    self.glyph = glyph
    self.role = role
    self.archived = archived
    self.parent = parent
    self.builtin = builtin
  }

  public var hue: Hue { bucket.hue }
}

public enum AccountKind: String, Sendable, Hashable, Codable {
  case current, credit, cash, investment
}

public struct Account: Sendable, Hashable, Identifiable, Codable {
  public var id: AccountID
  public var name: String
  public var shortName: String
  public var last4: String?
  public var kind: AccountKind
  public var balance: Money
  public var inPlan: Bool
  public var detail: String

  public init(
    id: AccountID, name: String, shortName: String, last4: String? = nil, kind: AccountKind, balance: Money,
    inPlan: Bool = true, detail: String = ""
  ) {
    self.id = id
    self.name = name
    self.shortName = shortName
    self.last4 = last4
    self.kind = kind
    self.balance = balance
    self.inPlan = inPlan
    self.detail = detail
  }

  public var label: String { last4.map { "\(shortName) ···\($0)" } ?? shortName }
}

public enum Direction: String, Sendable, Hashable, Codable {
  case out
  case `in`
}

public enum CategorySource: Sendable, Hashable, Codable {
  case rule(pattern: String)
  case dictionary
  case model(tag: String?)
  case user
  case manual

  public static let cloudflareModelPrefix = "cf-clef/"
  public static let appleModelPrefix = "apple-fm/"
  public static let lastPickLabel = "Your last pick"

  public static func suggestionLabel(modelTag tag: String?, needsReview: Bool = true) -> String {
    guard let tag else { return "Suggested on this iPhone" }
    if tag.hasPrefix(cloudflareModelPrefix) { return needsReview ? "Suggested by Cloudflare AI" : "Sorted by Cloudflare AI" }
    if tag.hasPrefix(appleModelPrefix) { return "Suggested on this iPhone" }
    return "Suggested"
  }

  public func suggestionLabel(needsReview: Bool = true) -> String? {
    if case .model(let tag) = self { return Self.suggestionLabel(modelTag: tag, needsReview: needsReview) }
    return nil
  }
}

public struct Provenance: Sendable, Hashable, Codable {
  public var title: String
  public var readAt: String
  public var rawMerchant: String
  public var isText: Bool

  public init(title: String, readAt: String, rawMerchant: String, isText: Bool = false) {
    self.title = title
    self.readAt = readAt
    self.rawMerchant = rawMerchant
    self.isText = isText
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    title = try c.decode(String.self, forKey: .title)
    readAt = try c.decode(String.self, forKey: .readAt)
    rawMerchant = try c.decode(String.self, forKey: .rawMerchant)
    isText = try c.decodeIfPresent(Bool.self, forKey: .isText) ?? false
  }
}

public struct SplitLine: Sendable, Hashable, Codable, Identifiable {
  public var id: Int
  public var categoryID: CategoryID
  public var amount: Money {
    didSet { homeMinor = Money.homeMinor(of: amount) }
  }
  public var homeMinor: Int64?
  public var note: String

  public init(id: Int, categoryID: CategoryID, amount: Money, homeMinor: Int64?? = nil, note: String = "") {
    self.id = id
    self.categoryID = categoryID
    self.amount = amount
    self.homeMinor = homeMinor ?? Money.homeMinor(of: amount)
    self.note = note
  }
}

public enum TxnReviewReason: String, Sendable, Hashable, Codable {
  case probableCopy = "probable_copy"
  case samePurchase = "same_purchase"
  case mayRepeat = "may_repeat"

  public var label: String {
    switch self {
    case .probableCopy: "Looks like a copy"
    case .samePurchase: "Same purchase?"
    case .mayRepeat: "Same as a text?"
    }
  }

  public var title: String {
    switch self {
    case .probableCopy: "Looks like a copy"
    case .samePurchase: "Same purchase?"
    case .mayRepeat: "Maybe the same as a text"
    }
  }

  public var detail: String {
    switch self {
    case .probableCopy: "It matches one you have. Merge it, or keep both."
    case .samePurchase: "Could be the AED charge of an earlier purchase. Count it once, or keep both."
    case .mayRepeat: "Could be the same payment as a bank text. Keep both, or archive this one."
    }
  }
}

public struct MayRepeat: Sendable, Hashable, Codable {
  public var of: TxnID
  public var line: String

  public init(of: TxnID, line: String) {
    self.of = of
    self.line = line
  }
}

public struct HeldCopy: Sendable, Hashable, Codable {
  public var of: TxnID
  public var fromOtherInbox: Bool

  public init(of: TxnID, fromOtherInbox: Bool) {
    self.of = of
    self.fromOtherInbox = fromOtherInbox
  }
}

public enum HomeSource: String, Sendable, Hashable, Codable {
  case identity, rate, stated
}

public struct SamePurchaseMatch: Sendable, Hashable, Codable {
  public var of: TxnID
  public var merchantMissing: Bool

  public init(of: TxnID, merchantMissing: Bool = false) {
    self.of = of
    self.merchantMissing = merchantMissing
  }
}

public struct PriorFiling: Sendable, Hashable, Codable {
  public var categoryID: CategoryID?
  public var categorySource: CategorySource?
  public var ruleID: RuleID?
  public var needsReview: Bool
  public var categorizedAt: LocalDateTime?

  public init(
    categoryID: CategoryID?, categorySource: CategorySource?, ruleID: RuleID?, needsReview: Bool, categorizedAt: LocalDateTime? = nil
  ) {
    self.categoryID = categoryID
    self.categorySource = categorySource
    self.ruleID = ruleID
    self.needsReview = needsReview
    self.categorizedAt = categorizedAt
  }
}

public struct Txn: Sendable, Hashable, Identifiable, Codable {
  public var id: TxnID
  public var merchant: String
  public var place: String?
  public var amount: Money {
    didSet {
      homeMinor = Money.homeMinor(of: amount)
      homeSource = Money.homeSource(of: amount)
      homeRateMicro = nil
    }
  }
  public var homeMinor: Int64?
  public var homeSource: HomeSource?
  public var homeRateMicro: Int64?
  public var direction: Direction
  public var postedAt: LocalDateTime
  public var postedTimeKnown: Bool
  public var accountID: AccountID?
  public var categoryID: CategoryID?
  public var categorySource: CategorySource?
  public var needsReview: Bool
  public var isNewMerchant: Bool
  public var suggestion: CategoryID?
  public var note: String
  public var splits: [SplitLine]
  public var isRefund: Bool
  public var isTransfer: Bool
  public var isMatchedTransfer: Bool
  public var archived: Bool
  public var projectID: ProjectID?
  public var billID: BillID?
  public var provenance: Provenance?
  public var detailOverride: String?
  public var mailboxMessageID: String?
  public var heldCopy: HeldCopy?
  public var samePurchase: SamePurchaseMatch?
  public var reviewReason: TxnReviewReason?
  public var senderUnverified: Bool
  public var merchantKey: String?
  public var merchantGroup: String?
  public var reachable: Bool
  public var ruled: Bool
  public var priorFiling: PriorFiling?
  public var rejectedCategories: Set<CategoryID>
  public var categorizedAt: LocalDateTime?
  public var ruleID: RuleID?
  public var lastPick: CategoryID?
  public var combinedCopy: TxnID?
  public var mergedInto: TxnID?
  public var mayRepeat: MayRepeat?
  public var refundOf: TxnID?
  public var refundLinkBroken: Bool
  public var isReversal: Bool

  public var postedTime: String? { postedTimeKnown ? postedAt.time : nil }

  public func joined(_ lead: String, _ tail: String?, separator: String = " · ") -> String {
    tail.map { "\(lead)\(separator)\($0)" } ?? lead
  }

  public init(
    id: TxnID, merchant: String, place: String? = nil, amount: Money, homeMinor: Int64?? = nil,
    homeSource: HomeSource?? = nil, homeRateMicro: Int64? = nil, direction: Direction = .out,
    postedAt: LocalDateTime, postedTimeKnown: Bool = true, accountID: AccountID? = nil, categoryID: CategoryID? = nil,
    categorySource: CategorySource? = nil, needsReview: Bool = false, isNewMerchant: Bool = false,
    suggestion: CategoryID? = nil, note: String = "", splits: [SplitLine] = [], isRefund: Bool = false,
    isTransfer: Bool = false, isMatchedTransfer: Bool = false, archived: Bool = false, projectID: ProjectID? = nil, billID: BillID? = nil,
    provenance: Provenance? = nil, detailOverride: String? = nil, mailboxMessageID: String? = nil,
    heldCopy: HeldCopy? = nil,
    samePurchase: SamePurchaseMatch? = nil,
    reviewReason: TxnReviewReason? = nil,
    senderUnverified: Bool = false,
    merchantKey: String? = nil,
    merchantGroup: String? = nil,
    reachable: Bool = false,
    ruled: Bool = false,
    priorFiling: PriorFiling? = nil,
    rejectedCategories: Set<CategoryID> = [],
    categorizedAt: LocalDateTime? = nil,
    ruleID: RuleID? = nil,
    lastPick: CategoryID? = nil,
    combinedCopy: TxnID? = nil,
    mayRepeat: MayRepeat? = nil,
    refundOf: TxnID? = nil,
    refundLinkBroken: Bool = false,
    isReversal: Bool = false
  ) {
    self.id = id
    self.merchant = merchant
    self.place = place
    self.amount = amount
    self.homeMinor = homeMinor ?? Money.homeMinor(of: amount)
    self.homeSource = self.homeMinor == nil ? nil : (homeSource ?? Money.homeSource(of: amount))
    self.homeRateMicro = self.homeSource == .rate ? homeRateMicro : nil
    self.direction = direction
    self.postedAt = postedAt
    self.postedTimeKnown = postedTimeKnown
    self.accountID = accountID
    self.categoryID = categoryID
    self.categorySource = categorySource
    self.needsReview = needsReview
    self.isNewMerchant = isNewMerchant
    self.suggestion = suggestion
    self.note = note
    self.splits = splits
    self.isRefund = isRefund
    self.isTransfer = isTransfer
    self.isMatchedTransfer = isMatchedTransfer
    self.archived = archived
    self.projectID = projectID
    self.billID = billID
    self.provenance = provenance
    self.detailOverride = detailOverride
    self.mailboxMessageID = mailboxMessageID
    self.heldCopy = heldCopy
    self.samePurchase = samePurchase
    self.reviewReason = reviewReason
    self.senderUnverified = senderUnverified
    self.merchantKey = merchantKey
    self.merchantGroup = merchantGroup
    self.reachable = reachable
    self.ruled = ruled
    self.priorFiling = priorFiling
    self.rejectedCategories = rejectedCategories
    self.categorizedAt = categorizedAt
    self.ruleID = ruleID
    self.lastPick = lastPick
    self.combinedCopy = combinedCopy
    self.mayRepeat = mayRepeat
    self.refundOf = refundOf
    self.refundLinkBroken = refundLinkBroken
    self.isReversal = isReversal
  }

  public var isHeldCopy: Bool { heldCopy != nil }

  public var isSample: Bool { mailboxMessageID?.hasPrefix("sample-") == true }

  public var activeReviewReason: TxnReviewReason? {
    if isHeldCopy { return .probableCopy }
    if samePurchase != nil { return .samePurchase }
    guard needsReview else { return nil }
    return reviewReason ?? (mayRepeat == nil ? nil : .mayRepeat)
  }

  public var fromText: Bool { provenance?.isText == true }

  public var isManual: Bool { provenance == nil && mailboxMessageID == nil }

  public var title: String { place.map { "\(merchant) \($0)" } ?? merchant }

  public var lines: [(category: CategoryID, minor: Int64)] {
    if !splits.isEmpty { return splits.map { ($0.categoryID, signed($0.homeMinor ?? 0)) } }
    guard let c = categoryID else { return [] }
    return [(c, homeSigned ?? 0)]
  }

  public var homeSigned: Int64? { homeMinor.map(signed) }

  func signed(_ minor: Int64) -> Int64 { direction == .out ? minor : minor.negated }

  public func apportioned(_ lines: [SplitLine]) -> [SplitLine] {
    let shares = Money.apportion(home: homeMinor, parts: lines.map(\.amount.minor))
    return lines.enumerated().map { i, l in
      var line = l
      line.amount = Money(minor: l.amount.minor, currency: amount.currency)
      line.homeMinor = shares?[i]
      return line
    }
  }

  public var isEstimate: Bool { homeMinor != nil && homeSource == .rate }

  public mutating func setStatedHome(_ minor: Int64) {
    homeMinor = minor
    homeSource = .stated
    homeRateMicro = nil
  }

  public var isNotCounted: Bool { homeMinor == nil }

  public var isHeldOut: Bool { !isHeldCopy && (samePurchase != nil || (mayRepeat != nil && needsReview)) }

  public var countsInPlan: Bool { !archived && !isTransfer && !isHeldCopy && !isHeldOut }
}

public enum BillCadence: String, Sendable, Hashable, Codable {
  case weekly, monthly, yearly
}

public struct Bill: Sendable, Hashable, Identifiable, Codable {
  public enum State: String, Sendable, Hashable, Codable { case tracked, paused, ended, dismissed }
  public enum Source: String, Sendable, Hashable, Codable { case manual, detected }

  public var id: BillID
  public var name: String
  public var kind: String
  public var categoryID: CategoryID
  public var amount: Money
  public var approximate: Bool
  public var isIncome: Bool
  public var usualDay: Int
  public var usualLastWorkingDay: Bool
  public var nextDue: LocalDate
  public var accountID: AccountID?
  public var state: State
  public var priceChangeFrom: Money?
  public var history: [LocalDate]
  public var source: Source
  public var cadence: BillCadence
  public var every: Int
  public var pausedSince: LocalDate?
  public var pausedUntil: LocalDate?
  public var endedOn: LocalDate?
  public var trackingSince: LocalDate?
  public var nextAmount: Money?
  public var nextAmountFrom: LocalDate?
  public var payments: [BillPayment]
  public var notices: [BillNotice]
  public var keys: [String]

  public init(
    id: BillID, name: String, kind: String, categoryID: CategoryID, amount: Money, approximate: Bool = false,
    isIncome: Bool = false, usualDay: Int, nextDue: LocalDate, accountID: AccountID? = nil,
    state: State = .tracked, priceChangeFrom: Money? = nil, history: [LocalDate] = [],
    source: Source = .detected, cadence: BillCadence = .monthly, every: Int = 1, pausedSince: LocalDate? = nil,
    pausedUntil: LocalDate? = nil, endedOn: LocalDate? = nil, trackingSince: LocalDate? = nil,
    nextAmount: Money? = nil, nextAmountFrom: LocalDate? = nil, payments: [BillPayment] = [],
    notices: [BillNotice] = [], keys: [String] = [], usualLastWorkingDay: Bool = false
  ) {
    self.usualLastWorkingDay = usualLastWorkingDay
    self.id = id
    self.name = name
    self.kind = kind
    self.categoryID = categoryID
    self.amount = amount
    self.approximate = approximate
    self.isIncome = isIncome
    self.usualDay = usualDay
    self.nextDue = nextDue
    self.accountID = accountID
    self.state = state
    self.priceChangeFrom = priceChangeFrom
    self.history = history
    self.source = source
    self.cadence = cadence
    self.every = every
    self.pausedSince = pausedSince
    self.pausedUntil = pausedUntil
    self.endedOn = endedOn
    self.trackingSince = trackingSince
    self.nextAmount = nextAmount
    self.nextAmountFrom = nextAmountFrom
    self.payments = payments
    self.notices = notices
    self.keys = keys
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try c.decode(BillID.self, forKey: .id), name: try c.decode(String.self, forKey: .name),
      kind: try c.decode(String.self, forKey: .kind), categoryID: try c.decode(CategoryID.self, forKey: .categoryID),
      amount: try c.decode(Money.self, forKey: .amount), approximate: try c.decode(Bool.self, forKey: .approximate),
      isIncome: try c.decode(Bool.self, forKey: .isIncome), usualDay: try c.decode(Int.self, forKey: .usualDay),
      nextDue: try c.decode(LocalDate.self, forKey: .nextDue),
      accountID: try c.decodeIfPresent(AccountID.self, forKey: .accountID),
      state: try c.decode(State.self, forKey: .state),
      priceChangeFrom: try c.decodeIfPresent(Money.self, forKey: .priceChangeFrom),
      history: try c.decode([LocalDate].self, forKey: .history),
      source: try c.decodeIfPresent(Source.self, forKey: .source) ?? .detected,
      cadence: try c.decodeIfPresent(BillCadence.self, forKey: .cadence) ?? .monthly,
      every: try c.decodeIfPresent(Int.self, forKey: .every) ?? 1,
      pausedSince: try c.decodeIfPresent(LocalDate.self, forKey: .pausedSince),
      pausedUntil: try c.decodeIfPresent(LocalDate.self, forKey: .pausedUntil),
      endedOn: try c.decodeIfPresent(LocalDate.self, forKey: .endedOn),
      trackingSince: try c.decodeIfPresent(LocalDate.self, forKey: .trackingSince),
      nextAmount: try c.decodeIfPresent(Money.self, forKey: .nextAmount),
      nextAmountFrom: try c.decodeIfPresent(LocalDate.self, forKey: .nextAmountFrom),
      payments: try c.decodeIfPresent([BillPayment].self, forKey: .payments) ?? [],
      notices: try c.decodeIfPresent([BillNotice].self, forKey: .notices) ?? [],
      keys: try c.decodeIfPresent([String].self, forKey: .keys) ?? [],
      usualLastWorkingDay: try c.decodeIfPresent(Bool.self, forKey: .usualLastWorkingDay) ?? false)
  }

  public var usualDayPhrase: String { usualLastWorkingDay ? "last work day" : PlanEngine.ordinal(usualDay) }

  public func usualDate(in month: YearMonth) -> LocalDate {
    usualLastWorkingDay ? month.lastWorkingDay : LocalDate(month.year, month.month, min(max(1, usualDay), month.days))
  }
}

public struct BillCandidate: Sendable, Hashable, Identifiable, Codable {
  public var id: String
  public var name: String
  public var categoryID: CategoryID
  public var amount: Money
  public var seenCount: Int
  public var everyDays: Int
  public var last: LocalDate
  public var key: String?

  public init(id: String, name: String, categoryID: CategoryID, amount: Money, seenCount: Int, everyDays: Int,
              last: LocalDate, key: String? = nil) {
    self.key = key
    self.id = id
    self.name = name
    self.categoryID = categoryID
    self.amount = amount
    self.seenCount = seenCount
    self.everyDays = everyDays
    self.last = last
  }
}

public struct Project: Sendable, Hashable, Identifiable, Codable {
  public var id: ProjectID
  public var name: String
  public var glyph: Glyph
  public var budget: Money?
  public var starts: LocalDate?
  public var ends: LocalDate?
  public var countInPlan: Bool
  public var complete: Bool
  public var completedOn: LocalDate?
  public var startVerb: String

  public init(id: ProjectID, name: String, glyph: Glyph, budget: Money?, starts: LocalDate?, ends: LocalDate?,
              countInPlan: Bool = false, complete: Bool = false, completedOn: LocalDate? = nil,
              startVerb: String = "starts") {
    self.startVerb = startVerb
    self.id = id
    self.name = name
    self.glyph = glyph
    self.budget = budget
    self.starts = starts
    self.ends = ends
    self.countInPlan = countInPlan
    self.complete = complete
    self.completedOn = completedOn
  }

  public var isOpen: Bool { !complete }

  public var draft: ProjectDraft {
    ProjectDraft(name: name, glyph: glyph, budget: budget, starts: starts, ends: ends, countInPlan: countInPlan)
  }
}

public struct ProjectDraft: Sendable, Hashable, Codable {
  public var name: String
  public var glyph: Glyph
  public var budget: Money?
  public var starts: LocalDate?
  public var ends: LocalDate?
  public var countInPlan: Bool

  public init(name: String, glyph: Glyph = .flag, budget: Money? = nil, starts: LocalDate? = nil,
              ends: LocalDate? = nil, countInPlan: Bool = false) {
    self.name = name
    self.glyph = glyph
    self.budget = budget
    self.starts = starts
    self.ends = ends
    self.countInPlan = countInPlan
  }

  public static let glyphs: [Glyph] = [.flag, .travel, .rent, .shopping, .savingsJar, .entertainment, .healthcare,
                                       .transport]

  public static let maxName = 64

  public static func capped(_ name: String) -> String {
    var out = name
    while out.unicodeScalars.count > maxName { out.removeLast() }
    return out
  }

  public var refusal: String? {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return "Give the project a name" }
    if trimmed.unicodeScalars.count > Self.maxName { return "Use \(Self.maxName) characters or fewer for the name" }
    if let b = budget, b.minor <= 0 { return "The budget must be more than 0" }
    if let s = starts, let e = ends, e < s { return "The end date is before the start date" }
    return nil
  }
}

public struct Goal: Sendable, Hashable, Identifiable, Codable {
  public var id: GoalID
  public var name: String
  public var glyph: Glyph
  public var categoryID: CategoryID
  public var target: Money
  public var saved: Money
  public var by: YearMonth

  public init(id: GoalID, name: String, glyph: Glyph, categoryID: CategoryID, target: Money, saved: Money,
              by: YearMonth) {
    self.id = id
    self.name = name
    self.glyph = glyph
    self.categoryID = categoryID
    self.target = target
    self.saved = saved
    self.by = by
  }
}

public enum RuleMatch: String, Sendable, Hashable, Codable {
  case contains, startsWith, exact

  public var label: String {
    switch self {
    case .contains: "Contains"
    case .startsWith: "Starts with"
    case .exact: "Exact match"
    }
  }
}

public struct Rule: Sendable, Hashable, Identifiable, Codable {
  public var id: RuleID
  public var patterns: [String]
  public var match: RuleMatch
  public var categoryID: CategoryID
  public var enabled: Bool
  public var learnedToday: Bool

  public init(id: RuleID, patterns: [String], match: RuleMatch = .contains, categoryID: CategoryID,
              enabled: Bool = true, learnedToday: Bool = false) {
    self.id = id
    self.patterns = patterns
    self.match = match
    self.categoryID = categoryID
    self.enabled = enabled
    self.learnedToday = learnedToday
  }
}

public struct PlanState: Sendable, Hashable, Codable {
  public var income: Money
  public var payday: Int
  public var paydayLastWorkingDay: Bool
  public var startingSplit: [Int]
  public var budgets: [String: Money]
  public var incomeByMonth: [YearMonth: Money]
  public var incomeExpectedByMonth: [YearMonth: Money]
  public var incomeReceivedByMonth: [YearMonth: Money]
  public var zeroSet: Set<String>
  public var expiredMoves: [CategoryID: Money]

  public init(income: Money, payday: Int, startingSplit: [Int], budgets: [String: Money],
              incomeByMonth: [YearMonth: Money] = [:], incomeExpectedByMonth: [YearMonth: Money] = [:],
              incomeReceivedByMonth: [YearMonth: Money] = [:], zeroSet: Set<String> = [],
              expiredMoves: [CategoryID: Money] = [:], paydayLastWorkingDay: Bool = false) {
    self.paydayLastWorkingDay = paydayLastWorkingDay
    self.zeroSet = zeroSet
    self.expiredMoves = expiredMoves
    self.incomeExpectedByMonth = incomeExpectedByMonth
    self.incomeReceivedByMonth = incomeReceivedByMonth
    self.income = income
    self.payday = payday
    self.startingSplit = startingSplit
    self.budgets = budgets
    self.incomeByMonth = incomeByMonth
  }

  public static func key(_ category: CategoryID, _ month: YearMonth) -> String { "\(category)@\(month)" }

  public func income(in month: YearMonth) -> Money { incomeByMonth[month] ?? income }

  public func expectedIncome(in month: YearMonth) -> Money { incomeExpectedByMonth[month] ?? income }

  public func receivedIncome(in month: YearMonth) -> Money? { incomeReceivedByMonth[month] }

  public func incomeKnown(in month: YearMonth) -> Bool {
    expectedIncome(in: month).minor > 0 || (receivedIncome(in: month)?.minor ?? 0) != 0 || income(in: month).minor > 0
  }

  public func setToZero(_ category: CategoryID, _ month: YearMonth) -> Bool { zeroSet.contains(Self.key(category, month)) }

  public mutating func setBudget(_ category: CategoryID, _ month: YearMonth, to amount: Money) {
    let key = Self.key(category, month)
    budgets[key] = amount
    if amount.minor == 0 { zeroSet.insert(key) } else { zeroSet.remove(key) }
  }

  public mutating func setBudget(_ category: CategoryID, _ month: YearMonth, to amount: Money, thisMonth: YearMonth) {
    setBudget(category, month, to: amount)
    if month == thisMonth { expiredMoves[category] = nil }
  }

  public func budget(_ category: CategoryID, _ month: YearMonth) -> Money {
    budgets[Self.key(category, month)] ?? .aed(0)
  }
}

public struct MailboxHealth: Sendable, Hashable, Codable {
  public enum Status: String, Sendable, Hashable, Codable {
    case working, notConnected, reconnect
    case importing
  }

  public var status: Status
  public var lastEmail: String
  public var banks: String
  public var unreadable: Int

  public init(status: Status, lastEmail: String, banks: String, unreadable: Int = 0) {
    self.status = status
    self.lastEmail = lastEmail
    self.banks = banks
    self.unreadable = unreadable
  }
}

public struct UnreadMail: Sendable, Hashable, Codable, Identifiable {
  public var id: TxnID
  public var provider: MailProviderKind?
  public var receivedOn: LocalDate
  public var bank: String?
  public var accountID: AccountID?

  public init(id: TxnID, provider: MailProviderKind?, receivedOn: LocalDate, bank: String? = nil, accountID: AccountID? = nil) {
    self.id = id
    self.provider = provider
    self.receivedOn = receivedOn
    self.bank = bank
    self.accountID = accountID
  }
}

public struct UnreadText: Sendable, Hashable, Codable, Identifiable {
  public var id: TxnID
  public var bank: String?
  public var receivedAt: LocalDateTime
  public var accountID: AccountID?

  public init(id: TxnID, bank: String?, receivedAt: LocalDateTime, accountID: AccountID? = nil) {
    self.id = id
    self.bank = bank
    self.receivedAt = receivedAt
    self.accountID = accountID
  }
}

public enum SignInMethod: String, Sendable, Hashable, Codable { case passkey, password }

public struct ProfileInfo: Sendable, Hashable, Codable {
  public var displayName: String
  public var email: String
  public var emailVerified: Bool
  public var signIn: SignInMethod

  public init(displayName: String, email: String, emailVerified: Bool = true, signIn: SignInMethod = .passkey) {
    self.displayName = displayName
    self.email = email
    self.emailVerified = emailVerified
    self.signIn = signIn
  }

  public var initial: String {
    (displayName.first(where: \.isLetter) ?? displayName.first).map { String($0).uppercased() } ?? "?"
  }
}

public struct DevicePrefs: Sendable, Hashable, Codable {
  public enum NotificationLevel: String, Sendable, Hashable, Codable, CaseIterable {
    case important, everything, off

    public var label: String {
      switch self {
      case .important: "Important only"
      case .everything: "Everything"
      case .off: "Off"
      }
    }
  }

  public var notifications: NotificationLevel
  public var notificationDetail: Bool
  public var faceIDLock: Bool
  public var swipeNeedOnRight: Bool

  public init(notifications: NotificationLevel = .important, notificationDetail: Bool = false,
              faceIDLock: Bool = true, swipeNeedOnRight: Bool = true) {
    self.notifications = notifications
    self.notificationDetail = notificationDetail
    self.faceIDLock = faceIDLock
    self.swipeNeedOnRight = swipeNeedOnRight
  }
}

public struct NetWorthHistory: Sendable, Hashable, Codable {
  public var monthChange: Money?
  public var spark: [Int]

  public init(monthChange: Money? = nil, spark: [Int] = []) {
    self.monthChange = monthChange
    self.spark = spark
  }
}

public struct LedgerState: Sendable, Hashable, Codable {
  public var categories: [Category]
  public var accounts: [Account]
  public var txns: [Txn]
  public var plan: PlanState
  public var bills: [Bill]
  public var billCandidates: [BillCandidate]
  public var projects: [Project]
  public var goals: [Goal]
  public var rules: [Rule]
  public var profile: ProfileInfo
  public var mailbox: MailboxHealth
  public var prefs: DevicePrefs
  public var netWorth: NetWorthHistory
  public var skippedReview: Set<TxnID>
  public var rates: [CurrencyRate]
  public var unreadMail: [UnreadMail]
  public var unreadTexts: [UnreadText]
  public var reading: ReadingState?

  public init(
    categories: [Category], accounts: [Account], txns: [Txn], plan: PlanState, bills: [Bill] = [],
    billCandidates: [BillCandidate] = [], projects: [Project] = [], goals: [Goal] = [], rules: [Rule] = [],
    profile: ProfileInfo, mailbox: MailboxHealth, prefs: DevicePrefs = DevicePrefs(),
    netWorth: NetWorthHistory = NetWorthHistory(), skippedReview: Set<TxnID> = [],
    rates: [CurrencyRate] = [CurrencyRate(currency: "USD", rateMicro: 3_672_500)],
    unreadMail: [UnreadMail] = [], unreadTexts: [UnreadText] = [], reading: ReadingState? = nil
  ) {
    self.reading = reading
    self.unreadMail = unreadMail
    self.unreadTexts = unreadTexts
    self.rates = rates
    self.netWorth = netWorth
    self.categories = categories
    self.accounts = accounts
    self.txns = txns
    self.plan = plan
    self.bills = bills
    self.billCandidates = billCandidates
    self.projects = projects
    self.goals = goals
    self.rules = rules
    self.profile = profile
    self.mailbox = mailbox
    self.prefs = prefs
    self.skippedReview = skippedReview
  }

  public func category(_ id: CategoryID?) -> Category? {
    guard let id else { return nil }
    return categories.first { $0.id == id }
  }

  public func account(_ id: AccountID?) -> Account? {
    guard let id else { return nil }
    return accounts.first { $0.id == id }
  }

  public func txn(_ id: TxnID) -> Txn? { txns.first { $0.id == id } }

  public func bill(_ id: BillID) -> Bill? { bills.first { $0.id == id } }

  public func project(_ id: ProjectID?) -> Project? {
    guard let id else { return nil }
    return projects.first { $0.id == id }
  }

  public func categories(in bucket: Bucket) -> [Category] {
    categories.filter { $0.bucket == bucket && !$0.archived && $0.kind == .spending }
  }

  public func spent(_ category: CategoryID, in month: YearMonth) -> Money {
    .aed(Spending.spent(self, category: category, in: month))
  }
}
