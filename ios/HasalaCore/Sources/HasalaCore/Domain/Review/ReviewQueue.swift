import CoreCategorize
import CoreReplay

public enum ReviewLane: String, Sendable, CaseIterable {
  case unreadable, duplicate
  case needsReview = "needs_review"
  case uncategorized
  case copy

  public var inDeck: Bool { self == .needsReview || self == .uncategorized || self == .copy }
}

public enum ReviewQueue {
  public static func lane(_ t: Txn) -> ReviewLane? {
    if t.supersededBy != nil { return nil }
    if t.annotation("archived") != nil { return nil }
    if t.unparsed { return .unreadable }
    if t.isHeldCopy { return .copy }
    if t.possibleDuplicateOf != nil && t.duplicateDisposition == nil && t.copyOf == nil { return .duplicate }
    if t.needsReview { return .needsReview }
    if t.category == nil && t.splits.isEmpty { return .uncategorized }
    if let s = t.categorySource, s.kind == .model, !ModelTier.mayAutoFile(modelTag: s.model ?? "") { return .uncategorized }
    return nil
  }
}
