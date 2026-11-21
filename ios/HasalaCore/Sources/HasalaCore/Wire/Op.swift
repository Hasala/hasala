import CoreJSON
import Foundation

public enum SchemaVersion {
  public static let current = 4
  public static let author = 4
}

public enum OpType: String, CaseIterable, Sendable, Hashable {
  case txnIngested = "txn_ingested"
  case txnSuperseded = "txn_superseded"
  case txnCategorized = "txn_categorized"
  case txnSplit = "txn_split"
  case txnEdited = "txn_edited"
  case txnDuplicateDisposition = "txn_duplicate_disposition"
  case ruleAdded = "rule_added"
  case rateSet = "rate_set"
  case rateUnset = "rate_unset"
  case homeCurrencySet = "home_currency_set"
  case bankDeclared = "bank_declared"
  case budgetSplitSet = "budget_split_set"
  case categoryDefined = "category_defined"
  case writerCheckpoint = "writer_checkpoint"
  case budgetSet = "budget_set"
  case budgetMoved = "budget_moved"
  case incomeSourceSet = "income_source_set"
  case categoryPlanRoleSet = "category_plan_role_set"
  case billSet = "bill_set"
  case billOccurrenceSet = "bill_occurrence_set"
  case accountSet = "account_set"
  case cardLinked = "card_linked"
  case accountCheckin = "account_checkin"
  case txnAnnotated = "txn_annotated"
  case merchantNamed = "merchant_named"
  case senderTrustSet = "sender_trust_set"
  case projectDefined = "project_defined"
  case goalDefined = "goal_defined"
  case mailboxRetired = "mailbox_retired"
  case txnCopyResolved = "txn_copy_resolved"
  case merchantCategoryRejected = "merchant_category_rejected"

  public static let reserved: [String] = ["profile_set"]

  public var minVersion: Int {
    switch self {
    case .txnDuplicateDisposition: 2
    case .bankDeclared, .budgetSplitSet, .categoryDefined: 3
    case .budgetSet, .budgetMoved, .incomeSourceSet, .categoryPlanRoleSet, .billSet, .billOccurrenceSet,
      .accountSet, .cardLinked, .accountCheckin, .txnAnnotated, .merchantNamed, .senderTrustSet,
      .projectDefined, .goalDefined, .mailboxRetired, .txnCopyResolved, .merchantCategoryRejected:
      4
    default: 1
    }
  }

  public var isParentFree: Bool { entityKind == nil }

  public var entityKind: String? {
    switch self {
    case .txnIngested, .txnSuperseded, .txnCategorized, .txnSplit, .txnEdited, .txnDuplicateDisposition, .txnCopyResolved:
      "txn"
    case .ruleAdded: "rule"
    case .billSet: "bill"
    case .projectDefined: "project"
    case .goalDefined: "goal"
    default: nil
    }
  }

  public var travelsAlone: Bool { self == .merchantCategoryRejected }

  public var carriesIngestID: Bool { self == .txnIngested || self == .txnSuperseded }
}

public struct EntityRef: Sendable, Hashable {
  public let kind: String
  public let id: String

  package init(kind: String, id: String) {
    self.kind = kind
    self.id = id
  }
}

public struct Op: Sendable, Hashable {
  public let v: Int
  public let type: OpType
  public let opID: String
  public let authoredAt: String
  public let entity: EntityRef?
  public let parentVersion: Int64?
  public let ingestID: String?
  public let payload: JSONValue

  package init(
    v: Int, type: OpType, opID: String, authoredAt: String, entity: EntityRef? = nil, parentVersion: Int64? = nil,
    ingestID: String? = nil, payload: JSONValue
  ) {
    self.v = v
    self.type = type
    self.opID = opID
    self.authoredAt = authoredAt
    self.entity = entity
    self.parentVersion = parentVersion
    self.ingestID = ingestID
    self.payload = payload
  }
}
