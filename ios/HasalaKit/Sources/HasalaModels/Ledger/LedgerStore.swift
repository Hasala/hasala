import Foundation
import Observation

public enum LedgerEdit: Sendable, Hashable {
  case addTransaction(ManualEntryDraft)
  case categorize(TxnID, CategoryID, learnRule: Bool, project: ProjectID?)
  case markTransfer(TxnID)
  case markRefund(TxnID)
  case fileRefund(TxnID, into: CategoryID, of: TxnID?)
  case setNote(TxnID, String)
  case renameMerchant(TxnID, String)
  case split(TxnID, [SplitLine])
  case archive(TxnID, Bool)
  case resolveCopy(TxnID, merge: Bool)
  case keepCombinedApart(TxnID)
  case resolveSamePurchase(TxnID, same: Bool)
  case skipReview(TxnID)
  case returnToReview([TxnID])
  case stopRule(RuleID)

  case saveProject(ProjectID, ProjectDraft)
  case setProjectCountInPlan(ProjectID, Bool)
  case completeProject(ProjectID, Bool)
  case removeProject(ProjectID)
  case assignProject([TxnID], ProjectID?)

  case setBudget(CategoryID, YearMonth, Money)
  case moveMoney(from: CategoryID?, to: CategoryID, YearMonth, Money)

  case trackCandidate(String)
  case dismissCandidate(String)
  case markBillPaid(BillID)
  case acceptBillAmount(BillID)
  case stopTrackingBill(BillID)
  case addBill(BillDraft)
  case editBillAmount(BillID, Money, approximate: Bool, from: LocalDate)
  case pauseBill(BillID, until: LocalDate?)
  case resumeBill(BillID)
  case endBill(BillID, lastPayment: LocalDate)
  case reactivateBill(BillID)
  case deleteBill(BillID)
  case linkBillPayments(BillID, [TxnID])
  case reapplyBill(BillID)
  case dismissBillNotice(BillID, noticeID: String)
  case editIncome(id: String, amount: Money, payday: Int, lastWorkingDay: Bool = false, active: Bool)

  case setRuleEnabled(RuleID, Bool)

  case addCategory(CategoryDraft)
  case addCategoryAndSort(CategoryDraft, TxnID, alwaysUse: Bool, project: ProjectID?)
  case editCategory(CategoryID, CategoryDraft)
  case archiveCategory(CategoryID, moveTo: CategoryID?)
  case restoreCategory(CategoryID)

  case setRate(currency: String, rateMicro: Int64)
  case unsetRate(currency: String)

  case setNotifications(DevicePrefs.NotificationLevel)
  case setFaceIDLock(Bool)

  case setDisplayName(String)
}

public struct ManualEntryDraft: Sendable, Hashable {
  public var amount: Money
  public var direction: Direction
  public var merchant: String
  public var categoryID: CategoryID?
  public var postedAt: LocalDateTime
  public var accountID: AccountID?

  public init(
    amount: Money, direction: Direction = .out, merchant: String, categoryID: CategoryID?, postedAt: LocalDateTime,
    accountID: AccountID? = nil
  ) {
    self.amount = amount
    self.direction = direction
    self.merchant = merchant
    self.categoryID = categoryID
    self.postedAt = postedAt
    self.accountID = accountID
  }

  public static let maxMerchantLength = 80
  public static let maxMinor: Int64 = 999_999_999_99

  public var trimmedMerchant: String { merchant.trimmedSpaces }

  public var refusal: ActionError? {
    if amount.minor <= 0 || amount.minor > Self.maxMinor { return .invalidAmount }
    if trimmedMerchant.isEmpty || trimmedMerchant.count > Self.maxMerchantLength { return .invalidMerchant }
    return nil
  }

  public func txn(id: TxnID, in s: LedgerState) -> Txn {
    var t = Txn(
      id: id, merchant: trimmedMerchant, amount: amount, direction: direction, postedAt: postedAt, accountID: accountID,
      categoryID: categoryID, categorySource: categoryID == nil ? nil : .user, isTransfer: categoryID == "transfer")
    t.isRefund = RefundEdit.filedAsRefund(t, in: s)
    return t
  }
}

public struct BillDraft: Sendable, Hashable {
  public var name: String
  public var keys: [String]
  public var amount: Money
  public var approximate: Bool
  public var cadence: BillCadence
  public var every: Int
  public var firstDue: LocalDate
  public var categoryID: CategoryID
  public var accountID: AccountID?
  public var linkTxns: [TxnID]

  public init(
    name: String, keys: [String] = [], amount: Money, approximate: Bool = false, cadence: BillCadence = .monthly,
    every: Int = 1, firstDue: LocalDate, categoryID: CategoryID, accountID: AccountID? = nil, linkTxns: [TxnID] = []
  ) {
    self.name = name
    self.keys = keys
    self.amount = amount
    self.approximate = approximate
    self.cadence = cadence
    self.every = every
    self.firstDue = firstDue
    self.categoryID = categoryID
    self.accountID = accountID
    self.linkTxns = linkTxns
  }

  public static let maxNameLength = 80

  public static func fittedName(_ name: String) -> String {
    String(name.trimmedSpaces.prefix(maxNameLength)).trimmedSpaces
  }

  public var trimmedName: String { name.trimmedSpaces }

  public var refusal: ActionError? {
    if amount.minor <= 0 || amount.minor > ManualEntryDraft.maxMinor { return .invalidAmount }
    if trimmedName.isEmpty || trimmedName.count > Self.maxNameLength { return .invalidMerchant }
    if every < 1 || every > cadence.maxEvery { return .invalidBill }
    return nil
  }
}

public struct UndoToken: Sendable, Hashable, Identifiable, Codable {
  public var id: Int
  public var title: String
  public var batch: Bool

  public init(id: Int, title: String, batch: Bool = false) {
    self.id = id
    self.title = title
    self.batch = batch
  }
}

public extension LedgerEdit {
  static func assign(_ c: CategoryID, _ month: YearMonth, _ amount: Money, in s: LedgerState) -> LedgerEdit {
    .setBudget(c, month, .aed(s.plan.budget(c, month).minor.plus(amount.minor)))
  }
}

public enum ActionError: Error, Sendable, Hashable {
  case notFound
  case splitDoesNotAddUp
  case insufficientFunds
  case invalidAmount
  case invalidProject
  case invalidMerchant
  case invalidBill
  case refused(String)
}

public struct CategoryDraft: Sendable, Hashable {
  public var id: CategoryID?
  public var name: String
  public var glyph: Glyph
  public var parent: CategoryID?

  public init(id: CategoryID? = nil, name: String, glyph: Glyph = .tag, parent: CategoryID? = nil) {
    self.id = id
    self.name = name
    self.glyph = glyph
    self.parent = parent
  }

  public var trimmedName: String { name.trimmedSpaces }

  public static func fallbackID() -> CategoryID { "c_" + UUID().uuidString.lowercased().filter { $0 != "-" }.prefix(30) }
}

@MainActor
public protocol LedgerStore: AnyObject, Observable {
  var state: LedgerState { get }
  var now: LocalDateTime { get }
  var revision: Int { get }
  @discardableResult
  func apply(_ edit: LedgerEdit) throws(ActionError) -> UndoToken?
  func categoryRefusal(_ edit: LedgerEdit) throws(ActionError) -> String?
  func undo(_ token: UndoToken)
  func newProjectID() -> ProjectID
  func newCategoryID() -> CategoryID
}

public extension LedgerStore {
  var month: YearMonth { now.date.yearMonth }
  func categoryRefusal(_ edit: LedgerEdit) throws(ActionError) -> String? { CategoriesEngine.refusal(edit, in: state) }
  func newProjectID() -> ProjectID { "p-" + UUID().uuidString.lowercased() }
  func newCategoryID() -> CategoryID { CategoryDraft.fallbackID() }
}
