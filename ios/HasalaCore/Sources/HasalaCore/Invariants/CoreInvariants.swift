import CoreReplay
import CoreWire

public struct Violation: Sendable, Equatable {
  public enum Severity: String, Sendable { case hardStop = "hard_stop", notice }
  public let id: String
  public let severity: Severity
  public let detail: String
}

public enum Invariants {
  public static let anomalyKinds: [String] = [
    "duplicate_delivery", "invalid_op", "invalid_payload", "home_currency_reset", "rate_set_before_home_currency",
    "rate_set_for_home_currency", "rate_unset_for_home_currency", "entity_kind_mismatch", "invalid_parent", "duplicate_create",
    "nonexistent_parent", "unknown_entity", "future_parent", "duplicate_ingest", "supersede_without_origin", "split_sum",
    "edit_of_superseded", "duplicate_disposition_mismatch", "unsupported_edit_field", "possible_duplicate", "unhandled_op",
    "money_overflow", "plan_undo_mismatch", "edit_of_retired",
  ]

  public static let maxFindingsPerInvariant = 64

  public static func check(_ s: State) -> [Violation] {
    var out: [Violation] = []
    var counts: [String: Int] = [:]
    func add(_ id: String, _ severity: Violation.Severity, _ detail: String) {
      let n = counts[id, default: 0]
      counts[id] = n + 1
      if n < maxFindingsPerInvariant {
        out.append(Violation(id: id, severity: severity, detail: detail))
      } else if n == maxFindingsPerInvariant {
        out.append(Violation(id: id, severity: severity, detail: "more findings not listed"))
      }
    }

    var live: [String: [String]] = [:]
    for (id, t) in s.txns where t.isLive { live[t.ingestID, default: []].append(id) }
    for (ingest, ids) in live.sorted(by: { $0.key < $1.key }) {
      if ids.count > 1 { add("I7_one_live_per_ingest", .hardStop, "ingest \(ingest.prefix(12)) has \(ids.count) live rows") }
      if s.liveByIngestID[ingest] != ids.first { add("I7_one_live_per_ingest", .hardStop, "index disagrees for ingest \(ingest.prefix(12))") }
    }
    for (ingest, id) in s.liveByIngestID where s.txns[id]?.isLive != true || s.txns[id]?.ingestID != ingest {
      add("I7_one_live_per_ingest", .hardStop, "index names \(id), which is not live under that ingest id")
    }

    for (id, t) in s.txns {
      if !t.splits.isEmpty {
        let sum = t.splits.reduce(Int128(0)) { $0 + Int128($1.amountMinor) }
        if sum != Int128(t.amountMinor) { add("I8_split_sum", .hardStop, "\(id): parts do not sum to the amount") }
        if t.splits.count > 16 { add("I20_split_shape_v4", .hardStop, "\(id): \(t.splits.count) parts") }
        if t.splits.contains(where: { $0.amountMinor <= 0 }) { add("I8_split_sum", .hardStop, "\(id): a part is not positive") }
      }
      if t.unparsed {
        if t.amountMinor != 0 || !t.currency.isEmpty || !t.direction.isEmpty || t.amountHomeMinor != nil || t.tier != "none" || !t.needsReview {
          add("I12_money_shape", .hardStop, "\(id): unparsed row carries money or left review")
        }
      } else {
        let ccy = Array(t.currency.utf8)
        if t.amountMinor <= 0 || ccy.count != 3 || !ccy.allSatisfy({ $0 >= 0x41 && $0 <= 0x5a }) || !(t.direction == "debit" || t.direction == "credit") {
          add("I12_money_shape", .hardStop, "\(id): parsed row without a positive amount, a currency and a direction")
        }
        if let h = t.amountHomeMinor, h < 0 { add("I12_money_shape", .hardStop, "\(id): negative home amount") }
      }
      if t.isLive, let src = t.categorySource {
        if t.category == nil && !(src.kind == .none || src.kind == .user) {
          add("I18_category_source_shape", .hardStop, "\(id): \(src.kind.rawValue) source with no category")
        }
        if t.category != nil && src.kind == .none { add("I18_category_source_shape", .hardStop, "\(id): a category with source none") }
      }
      if t.unparsed {
        for f in ["account_id", "counter_account_id", "project_id", "refund_of", "transfer_peer"] where t.annotation(f) != nil {
          add("I19_unparsed_links_empty", .hardStop, "\(id): \(f) on an unparsed row")
        }
      }
      if t.successorID != nil {
        var cur = id
        var steps = 0
        var ok = false
        while steps <= s.txns.count {
          guard let row = s.txns[cur] else { break }
          guard let next = row.successorID else {
            ok = row.supersededBy == nil
            break
          }
          cur = next
          steps += 1
        }
        if !ok { add("I21_successor_chain_acyclic", .hardStop, "\(id): the successor chain does not end at a live row") }
      }
      let shouldPend = t.isLive && !t.unparsed && t.amountHomeMinor == nil
      let pends = s.pendingByCurrency[t.currency]?.contains(id) == true
      if shouldPend != pends { add("I10_fx_pending_index", .hardStop, "\(id): pending index disagrees with the row") }
    }

    var indexed: [String: Int] = [:]
    for (_, ids) in s.byFingerprint { for id in ids { indexed[id, default: 0] += 1 } }
    for (id, t) in s.txns {
      let n = indexed[id] ?? 0
      if t.isLive && n != 1 { add("I9_fingerprint_index", .hardStop, "\(id): indexed \(n) times") }
      if !t.isLive && n != 0 { add("I9_fingerprint_index", .hardStop, "\(id): retired but indexed") }
    }

    for (id, r) in s.rules where r.shape >= 4 {
      if !(1...8).contains(r.patterns.count) || !["exact", "starts_with", "contains"].contains(r.match) {
        add("I23_rule_v4_shape", .hardStop, "\(id): bad v4 rule shape")
      }
    }

    for a in s.anomalies {
      if !anomalyKinds.contains(a.kind) { add("I14_forks_surfaced", .hardStop, "unknown anomaly kind \(a.kind) at seq \(a.atSeq)") }
      if a.kind == "supersede_without_origin" { add("I13_supersede_has_origin", .notice, "seq \(a.atSeq)") }
    }
    if !s.forks.isEmpty { add("I14_forks_surfaced", .notice, "\(s.forks.count) forks resolved") }
    for u in s.unreadable { add("I15_unreadable_set_aside", .notice, "seq \(u.seq) from \(u.writerID)") }
    return out
  }

  public static func halts(_ violations: [Violation]) -> Bool { violations.contains { $0.severity == .hardStop } }

  public static func audit(kept: State, refolded: State) -> Violation? {
    guard kept.serialized() != refolded.serialized() else { return nil }
    return Violation(id: "I22_audit_refold", severity: .hardStop, detail: "the re-fold differs from the kept state")
  }
}
