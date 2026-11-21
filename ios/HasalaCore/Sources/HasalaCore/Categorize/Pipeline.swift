import HasalaText

public enum DecisionSource: Sendable, Equatable {
  case none
  case rule(id: String)
  case dictionary(bundle: String, entry: String)
}

public struct Decision: Sendable, Equatable {
  public let category: String?
  public let source: DecisionSource
  public let display: String?
  public let suggested: String?

  public static let none = Decision(category: nil, source: .none, display: nil, suggested: nil)

  public init(category: String?, source: DecisionSource, display: String?, suggested: String?) {
    self.category = category
    self.source = source
    self.display = display
    self.suggested = suggested
  }
}

public enum Direction: String, Sendable {
  case debit, credit
}

public struct Categorizer: Sendable {
  public let prepared: PreparedRules
  public let bundle: String
  public let categories: any CategoryLookup

  public init(rules: [RuleInput], dictionary: MerchantDictionary, categories: any CategoryLookup) {
    prepared = Matcher.prepare(rules: rules, entries: dictionary.entries, categories: categories)
    bundle = dictionary.bundle
    self.categories = categories
  }

  public func decide(merchantRaw: String, direction: Direction) -> Decision {
    guard let hit = Matcher.firstHit(merchantRaw, prepared, accept: { categories.info($0.category)?.active == true }) else {
      return .none
    }
    if direction == .credit, categories.info(hit.category)?.kind == .spending {
      return Decision(category: nil, source: .none, display: hit.display, suggested: hit.category)
    }
    let source: DecisionSource =
      switch hit.source {
      case .rule: .rule(id: hit.id)
      case .dictionary: .dictionary(bundle: bundle, entry: MerchantDictionary.sourceEntry(hit))
      }
    return Decision(category: hit.category, source: source, display: hit.display, suggested: nil)
  }

  public func dictionaryDisplay(merchantRaw: String) -> String? {
    let subject = Array(Canon.subject(merchantRaw).utf8)
    if subject.isEmpty { return nil }
    return prepared.entries.first { $0.hits(subject) }?.display
  }
}

public struct SweepRow: Sendable, Equatable {
  public enum SourceKind: String, Sendable { case none, user, held, rule, dictionary, model }
  public let id: String
  public let merchantRaw: String
  public let direction: Direction?
  public let category: String?
  public let sourceKind: SourceKind
  public let sourceRef: String?
  public let needsReview: Bool
  public let candidate: Bool
  public let version: Int64?
  public let template: String?
  public let merchantGroup: String?
  public let categorizedMs: Int64?
  public let rejected: Set<String>
  public let picked: String?
  public let text: Bool

  public init(
    id: String, merchantRaw: String, direction: Direction?, category: String?, sourceKind: SourceKind, sourceRef: String?,
    needsReview: Bool, candidate: Bool, version: Int64? = nil, template: String? = nil, merchantGroup: String? = nil, categorizedMs: Int64? = nil,
    rejected: Set<String> = [], picked: String? = nil, text: Bool = false
  ) {
    self.id = id
    self.merchantRaw = merchantRaw
    self.direction = direction
    self.category = category
    self.sourceKind = sourceKind
    self.sourceRef = sourceRef
    self.needsReview = needsReview
    self.candidate = candidate
    self.version = version
    self.template = template
    self.merchantGroup = merchantGroup
    self.categorizedMs = categorizedMs
    self.rejected = rejected
    self.picked = picked
    self.text = text
  }

  public func rejects(_ category: String) -> Bool { rejected.contains(category) }
}

public struct SweepAction: Sendable, Equatable {
  public let txnID: String
  public let category: String
  public let source: DecisionSource
  public let needsReview: Bool
}

public enum Sweep {
  public static let maxOpsPerBlob = 500

  public static func plan(_ rows: [SweepRow], _ categorizer: Categorizer) -> (actions: [SweepAction], modelQueue: [SweepRow]) {
    var actions: [SweepAction] = []
    var queue: [SweepRow] = []
    for r in rows where r.candidate {
      switch r.sourceKind {
      case .user, .held: continue
      default: break
      }
      guard let direction = r.direction else { continue }
      let d = categorizer.decide(merchantRaw: r.merchantRaw, direction: direction)
      guard let category = d.category else {
        if r.category == nil && direction == .debit { queue.append(r) }
        continue
      }
      let (kind, ref): (SweepRow.SourceKind, String?) =
        switch d.source {
        case .rule(let id): (.rule, id)
        case .dictionary(let b, let e): (.dictionary, b + "|" + e)
        case .none: (.none, nil)
        }
      if r.category == category && r.sourceKind == kind && r.sourceRef == ref { continue }
      actions.append(SweepAction(txnID: r.id, category: category, source: d.source, needsReview: r.needsReview))
    }
    return (actions, queue)
  }
}
