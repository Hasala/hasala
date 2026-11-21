import CoreDomain
import CoreOutbox
import CorePrimitives
import CoreStore
import CoreSync
import CoreTime
import Foundation
import Synchronization

public final class MailboxAuthoring: Sendable {
  let store: LedgerStore
  let writerID: String
  let random: any RandomSource
  public let stamps: AuthorStamps
  private let seen: Mutex<[String: Int64]>

  public init(
    store: LedgerStore, writerID: String, random: any RandomSource, stamps: AuthorStamps, seen: [String: Int64] = [:]
  ) {
    self.store = store
    self.writerID = writerID
    self.random = random
    self.stamps = stamps
    self.seen = Mutex(seen)
  }

  public convenience init(observer: LedgerPageObserver) {
    let c = observer.context
    self.init(store: c.store, writerID: c.writerID.string, random: c.random, stamps: observer.stamps)
  }

  public func updateSeen(_ seen: [String: Int64]) {
    self.seen.withLock { $0 = seen }
  }

  public func context(nowMs: Int64) throws -> AuthorContext {
    let pending = try store.latestPendingAuthoredAt().flatMap { try? parseInstantMs($0) }
    let seen = self.seen.withLock { $0 }
    let own = [seen[writerID], pending].compactMap { $0 }.max()
    return AuthorContext(writerID: writerID, nowMs: nowMs, ownLastMs: own, maxAuthored: seen, random: random)
  }

  public func author(_ drafts: [MailboxIngestDraft], atMs: Int64) throws -> [MailboxPendingOpRow] {
    guard !drafts.isEmpty else { return [] }
    let ctx = try context(nowMs: atMs)
    let built: AuthoredBlob?
    do {
      built = try build(drafts, ctx)
    } catch {
      built = try build(drafts.map { Self.authorable($0, ctx) }, ctx)
    }
    guard let blob = built else { return [] }
    var rows: [MailboxPendingOpRow] = []
    for op in blob.ops {
      rows.append(
        MailboxPendingOpRow(
          opID: op.opID, opJSON: try Outbox.canonicalJSON(op), opType: op.type.rawValue, entityKind: op.entity?.kind,
          entityID: op.entity?.id, enqueuedAt: atMs))
    }
    return rows
  }

  private func build(_ drafts: [MailboxIngestDraft], _ ctx: AuthorContext) throws(AuthorError) -> AuthoredBlob? {
    try stamps.build(ctx) { a throws(AuthorError) in
      for d in drafts { try a.ingest(payload: d.payload, ingestID: d.ingestID) }
    }
  }

  static func authorable(_ d: MailboxIngestDraft, _ ctx: AuthorContext) -> MailboxIngestDraft {
    if accepts(d, ctx) { return d }
    let shapes = [MessageDisposer.refusedShape(d, keepGates: true)]
      + MessageDisposer.RefusedProvenance.allCases.map { MessageDisposer.refusedShape(d, keepGates: false, provenance: $0) }
    return shapes.first { accepts($0, ctx) } ?? shapes[shapes.count - 1]
  }

  static func accepts(_ d: MailboxIngestDraft, _ ctx: AuthorContext) -> Bool {
    var a = OpAuthor(ctx)
    do {
      _ = try a.ingest(payload: d.payload, ingestID: d.ingestID)
      _ = try a.build()
      return true
    } catch {
      return false
    }
  }

  public var opAuthor: MailboxOpAuthor {
    { [self] drafts, at in try author(drafts, atMs: at) }
  }
}

extension LedgerMailboxPersistence {
  public init(store: LedgerStore, authoring: MailboxAuthoring, nowMs: @escaping @Sendable () -> Int64) {
    self.init(tables: MailboxTableStore(writer: store.db), author: authoring.opAuthor, nowMs: nowMs)
  }
}
