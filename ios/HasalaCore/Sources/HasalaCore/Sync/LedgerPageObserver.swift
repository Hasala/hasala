import CoreAuth
import CoreCategorize
import CoreCrypto
import CoreDomain
import CoreInvariants
import CoreProjection
import CoreReplay
import CoreStore
import CoreWire
import Foundation

public actor LedgerPageObserver: PageObserver {
  public nonisolated let context: SyncContext
  public nonisolated let projection: ProjectionStore
  public nonisolated let stamps: AuthorStamps
  public nonisolated let writes = WriteSerial()
  let dictionary: MerchantDictionary

  private var state: State?
  private var candidate: State?
  private var dirty = false
  private var sampleIssued = false
  public private(set) var projectionFailure: String?

  public init(
    context: SyncContext, projection: ProjectionStore, dictionary: MerchantDictionary, stamps: AuthorStamps = AuthorStamps()
  ) {
    self.context = context
    self.projection = projection
    self.dictionary = dictionary
    self.stamps = stamps
  }

  public nonisolated var reader: LedgerReader { projection.reader }

  public func open() async throws(SyncStop) {
    if let url = projection.url {
      do {
        try FileHygiene.prepareDirectory(url.deletingLastPathComponent())
        try FileHygiene.excludeDatabaseFiles(at: url)
      } catch {
        throw .notNow
      }
    }
    let s = try loaded()
    let meta = try? projection.reader.meta()
    let pending = (try? context.store.pendingCount()) ?? 0
    let usable = (try? projection.reader.isUsable()) ?? false
    if !usable || meta?.cursorHot != s.cursors.hot || pending > 0 || (meta?.pendingOps ?? 0) > 0 {
      try project(s)
    }
  }

  public func currentState() async throws(SyncStop) -> State { try loaded() }

  private func loaded() throws(SyncStop) -> State {
    let cursor = try context.storeCall { () throws(StoreError) in try context.store.syncState().cursorHot }
    if let s = state, s.cursors.hot == cursor { return s }
    if let c = candidate, c.cursors.hot == cursor { return c }
    let s = try load(cursor: cursor)
    state = s
    return s
  }

  private func load(cursor: Int64) throws(SyncStop) -> State {
    let now = context.clock.nowMs()
    let store = context.store
    let result = try context.storeCall { () throws(StoreError) in
      try store.loadFoldSnapshot(foldPrint: FoldCanary.foldPrint, at: now) { (record: FoldSnapshotRecord) -> State? in
        guard let snap = try? SnapshotCodec.decode(record.payload), snap.state.cursors.hot == record.cursorHot else {
          return nil
        }
        return snap.state
      }
    }
    if case .success(let loaded)? = result { return loaded.decoded }
    if result == nil, cursor == 0 { return State() }
    let s = try coldFold(cursor: cursor)
    if let payload = try? SnapshotCodec.encode(StateSnapshot(state: s)) {
      _ = try? store.saveFoldSnapshot(foldPrint: FoldCanary.foldPrint, payload: payload, at: now)
    }
    try? store.recordFoldEvent(kind: "cold_fold", detail: "rows_to_\(cursor)", at: now)
    return s
  }

  func coldFold(cursor: Int64, plaintextBudget: Int = PageReader.maxPagePlaintext) throws(SyncStop) -> State {
    let store = context.store
    let sync = try context.storeCall { () throws(StoreError) in try store.syncState() }
    try checkStoredChain(upTo: cursor)
    let opener = Opener(epochHWM: sync.epochHWM, keys: try context.epochKeys(upTo: sync.epochHWM))
    let revoked = Set((PinnedRoster.decode(sync.rosterJSON)?.forReader() ?? [:]).filter { $0.value.revokedAt != nil }.keys)
    var s = State()
    var reread = 0
    try storedPages(upTo: cursor) { (rows: [WireRowRecord]) throws(SyncStop) in
      var page: [FoldRow] = []
      var held = 0
      for r in rows {
        let outcome = try reopen(r, opener, setsAsideNewer: revoked.contains(r.writerID) || r.disposition == .setAside)
        let now = WireRowRecord.Disposition(outcome)
        if now != r.disposition {
          guard r.disposition == .setAside, now == .folded else { throw integrityHalt("cold_fold_disposition") }
          reread += 1
        }
        page.append(FoldRow(seq: r.seq, writerID: r.writerID.string, counter: r.counter, outcome: outcome))
        if case .opened(let plaintext, _) = outcome { held += plaintext.count }
        if held >= plaintextBudget {
          s = try Self.fold(page, onto: s)
          page = []
          held = 0
        }
      }
      if !page.isEmpty { s = try Self.fold(page, onto: s) }
    }
    guard s.cursors.hot == cursor else { throw .halted(.inconsistent("cold_fold_cursor")) }
    if reread > 0 {
      try? store.recordFoldEvent(kind: "set_aside_reread", detail: "rows_\(reread)", at: context.clock.nowMs())
    }
    return s
  }

  private func checkStoredChain(upTo cursor: Int64) throws(SyncStop) {
    let pinned = try context.storeCall { () throws(StoreError) in try context.store.chainHeads() }
    var heads: [WriterID: Chain.Head] = [:]
    try storedPages(upTo: cursor) { (rows: [WireRowRecord]) throws(SyncStop) in
      for r in rows {
        let head = heads[r.writerID] ?? .genesis
        guard r.counter == head.counter + 1, r.prevHash == head.hash, Chain.hash(prev: r.prevHash, frame: r.blob) == r.blobHash
        else { throw integrityHalt("cold_fold_chain") }
        heads[r.writerID] = Chain.Head(counter: r.counter, hash: r.blobHash)
      }
    }
    for (w, h) in heads {
      guard let p = pinned[w], p.counter >= h.counter, p.counter > h.counter || p.hash == h.hash else {
        throw integrityHalt("cold_fold_heads")
      }
    }
  }

  private func storedPages(upTo cursor: Int64, _ each: ([WireRowRecord]) throws(SyncStop) -> Void) throws(SyncStop) {
    var after: Int64 = 0
    while after < cursor {
      let rows = try context.storeCall { () throws(StoreError) in try context.store.wireRows(after: after, limit: 250) }
      guard let last = rows.last else { return }
      let page = rows.filter { $0.seq <= cursor }
      if !page.isEmpty { try each(page) }
      after = last.seq
    }
  }

  private func reopen(_ r: WireRowRecord, _ opener: Opener, setsAsideNewer: Bool = false) throws(SyncStop) -> PageReader.RowOutcome {
    let envelope: Envelope
    do { envelope = try Envelope(userID: context.userID, writerID: r.writerID, counter: r.counter) } catch {
      throw .halted(.inconsistent("cold_fold_envelope"))
    }
    switch PageReader.decide(opener.open(r.blob, envelope: envelope, prevHash: r.prevHash), setsAsideNewer: setsAsideNewer) {
    case .row(let outcome): return outcome
    case .stop(.needsUnlock(let e)): throw .needsUnlock(epoch: e)
    case .stop(.hardStop(.updateRequired)): throw .halted(.updateRequired)
    case .stop: throw .halted(.inconsistent("cold_fold_open"))
    }
  }

  private func integrityHalt(_ what: String) -> SyncStop {
    try? context.store.recordFoldEvent(kind: "integrity_alarm", detail: what, at: context.clock.nowMs())
    return .halted(.inconsistent(what))
  }

  public func fold(_ rows: [PulledRow]) async throws(SyncStop) -> FoldSnapshotChange {
    let base = try loaded()
    let page = rows.map { FoldRow(seq: $0.seq, writerID: $0.writerID.string, counter: $0.counter, outcome: $0.outcome) }
    let folded = try Self.fold(page, onto: base)
    candidate = folded
    guard let payload = try? SnapshotCodec.encode(StateSnapshot(state: folded)) else { return .delete }
    return .save(foldPrint: FoldCanary.foldPrint, payload: payload)
  }

  public func pageCommitted() async {
    guard let c = candidate else { return }
    state = c
    candidate = nil
    dirty = true
  }

  public func pageAbandoned() async { candidate = nil }

  public func pullEnded() async {
    guard dirty, let s = state else { return }
    try? project(s)
  }

  public func ops(_ ids: Set<String>) -> OpLookup {
    var out = OpLookup()
    guard !ids.isEmpty else { return out }
    var incomplete = false
    do {
      let stored = try context.store.pendingOps() + context.store.acknowledgedOps(writerID: context.writerID, foldedThrough: 0)
      for r in stored where ids.contains(r.opID) && out.found[r.opID] == nil {
        do { out.found[r.opID] = try Pusher.decodeStored(r) } catch { incomplete = true }
      }
    } catch {
      incomplete = true
    }
    if out.found.count < ids.count {
      incomplete = !scanStored(for: ids, into: &out.found) || incomplete
    }
    let unfound = ids.subtracting(out.found.keys)
    if incomplete { out.failed = unfound } else { out.missing = unfound }
    return out
  }

  private func scanStored(for ids: Set<String>, into found: inout [String: Op]) -> Bool {
    let store = context.store
    let sync: SyncStateRow
    do { sync = try store.syncState() } catch { return false }
    var opener: Opener?
    var before = sync.cursorHot + 1
    var complete = true
    while before > 1 && found.count < ids.count {
      let rows: [WireRowRecord]
      do { rows = try store.wireRows(before: before, limit: 50) } catch { return false }
      guard let oldest = rows.last else { break }
      for r in rows where r.disposition != .alarm {
        if opener == nil {
          guard let keys = try? context.epochKeys(upTo: sync.epochHWM) else { return false }
          opener = Opener(epochHWM: sync.epochHWM, keys: keys)
        }
        let setAside = r.disposition == .setAside
        guard let opener, let outcome = try? reopen(r, opener, setsAsideNewer: setAside) else {
          complete = false
          continue
        }
        guard case .opened(_, let ops) = outcome else {
          complete = complete && setAside
          continue
        }
        for op in ops where ids.contains(op.opID) { found[op.opID] = op }
        if found.count == ids.count { return true }
      }
      before = oldest.seq
    }
    return complete || found.count == ids.count
  }

  public func reproject() async throws(SyncStop) {
    try project(try loaded())
  }

  private func pendingOverlay(over s: State) throws(SyncStop) -> [[Op]] {
    let store = context.store
    let writer = context.writerID
    let hot = s.cursors.hot
    try? store.forgetAcknowledged(writerID: writer, foldedThrough: hot)
    let rows = try context.storeCall { () throws(StoreError) in
      try store.outboxOverlay(writerID: writer, foldedThrough: hot)
    }
    let items = rows.compactMap { r in (try? Pusher.decodeStored(r)).map { (r.localSeq, $0) } }
    return items.sorted { $0.0 < $1.0 }.map { [$0.1] }
  }

  private func project(_ s: State) throws(SyncStop) {
    let pending = try pendingOverlay(over: s)
    do {
      try projection.project(
        s, pending: pending, writerID: context.writerID.string, dictionary: dictionary, projectedAtMs: context.clock.nowMs())
      projectionFailure = nil
      dirty = false
    } catch {
      projectionFailure = String(describing: type(of: error))
      try? context.store.recordFoldEvent(kind: "projection_failed", detail: projectionFailure ?? "", at: context.clock.nowMs())
      throw .halted(.inconsistent("projection"))
    }
  }

  public func authorContext() async throws(SyncStop) -> AuthorContext {
    try baseContext().raised(to: stamps.lastMs)
  }

  private func baseContext() throws(SyncStop) -> AuthorContext {
    let s = try loaded()
    let pending = try context.storeCall { () throws(StoreError) in try context.store.latestPendingAuthoredAt() }
    var seen: [String: Int64] = [:]
    for (w, ms) in s.maxAuthored { seen[w] = ms }
    return Self.authorContext(
      writerID: context.writerID.string, nowMs: context.clock.nowMs(), maxAuthored: seen,
      pendingLatest: pending.flatMap { try? parseInstantMs($0) }, noted: nil, random: context.random)
  }

  public static func authorContext(
    writerID: String, nowMs: Int64, maxAuthored: [String: Int64], pendingLatest: Int64?, noted: Int64?,
    random: any RandomSource
  ) -> AuthorContext {
    let own = [maxAuthored[writerID], pendingLatest, noted].compactMap { $0 }.max()
    return AuthorContext(writerID: writerID, nowMs: nowMs, ownLastMs: own, maxAuthored: maxAuthored, random: random)
  }

  public func seenStamps() async throws(SyncStop) -> [String: Int64] {
    var seen: [String: Int64] = [:]
    for (w, ms) in try loaded().maxAuthored { seen[w] = ms }
    return seen
  }

  public func noteAuthored(_ blob: AuthoredBlob) {
    stamps.authoring { _ in ((), blob.lastAuthoredMs) }
  }

  public func sampleBatches(account: AccountInfo) async throws(SampleLoadError) -> [AuthoredBlob] {
    try sampleBatches(account: account) { () throws(SampleSeedError) in try SampleSeed.bundled() }
  }

  func sampleBatches(account: AccountInfo, seed: () throws(SampleSeedError) -> Data) throws(SampleLoadError)
    -> [AuthoredBlob]
  {
    let review = account.user_id == context.userID.string ? account.review_account : false
    let ledger: State
    let base: AuthorContext
    do {
      let folded = try loaded()
      ledger = Projector.overlay(folded, pending: try pendingOverlay(over: folded), writerID: context.writerID.string).0
      base = try baseContext()
    } catch {
      throw .sync(error)
    }
    let sampleLoaded = sampleIssued || ledger.txns.values.contains { SampleSeed.isSampleMessageID($0.mailboxMessageID) }
    do {
      let permit = try SampleSeed.permit(
        reviewAccount: review, holdsTransactions: !ledger.txns.isEmpty, sampleLoaded: sampleLoaded)
      let data = try seed()
      let blobs = try stamps.authoring {
        (floor: Int64?) throws(SampleSeedError) -> (value: [AuthoredBlob], lastMs: Int64?) in
        let ctx = base.raised(to: floor)
        let b = try SampleSeed.batches(data, nowMs: ctx.nowMs, context: ctx, permit: permit)
        return (b, b.last?.lastAuthoredMs)
      }
      sampleIssued = true
      return blobs
    } catch {
      throw .seed(error)
    }
  }

  public func sampleNotSaved() {
    sampleIssued = false
  }

  public func loadSample(account: AccountInfo, enqueue: @Sendable ([Op]) async throws -> Void) async throws(SampleLoadError) {
    try await loadSample(account: account, seed: { () throws(SampleSeedError) in try SampleSeed.bundled() }, enqueue: enqueue)
  }

  func loadSample(
    account: AccountInfo, seed: @Sendable () throws(SampleSeedError) -> Data, enqueue: @Sendable ([Op]) async throws -> Void
  ) async throws(SampleLoadError) {
    let blobs = try sampleBatches(account: account, seed: seed)
    do {
      try await enqueue(blobs.flatMap(\.ops))
    } catch {
      sampleNotSaved()
      throw .notSaved
    }
    try? await reproject()
  }

  public func openingOps(after run: RunOutcome) throws -> AuthoredBlob? {
    guard run.stop == nil else { return nil }
    let folded = try loaded()
    guard folded.homeCurrency == nil else { return nil }
    let ledger = Projector.overlay(folded, pending: try pendingOverlay(over: folded), writerID: context.writerID.string).0
    guard ledger.homeCurrency == nil else { return nil }
    return try stamps.build(try baseContext().raised(to: stamps.lastMs)) { a throws(AuthorError) in
      a.setHomeCurrency("AED")
      try a.setRate(currency: "USD", rateMicro: 3_672_500)
    }
  }

  static func fold(_ page: [FoldRow], onto s: State) throws(SyncStop) -> State {
    do { return try LedgerFold.page(page, onto: s) } catch { throw stop(error) }
  }

  static func stop(_ h: FoldHalt) -> SyncStop {
    switch h {
    case .updateRequired: return .halted(.updateRequired)
    case .order: return .halted(.inconsistent("order"))
    case .inconsistent(let v):
      var ids: [String] = []
      for x in v where !ids.contains(x.id) { ids.append(x.id) }
      return .halted(.inconsistent(ids.joined(separator: ",")))
    }
  }
}

public struct OpLookup: Sendable, Equatable {
  public var found: [String: Op] = [:]
  public var missing: Set<String> = []
  public var failed: Set<String> = []

  public init(found: [String: Op] = [:], missing: Set<String> = [], failed: Set<String> = []) {
    self.found = found
    self.missing = missing
    self.failed = failed
  }
}

public enum SampleLoadError: Error, Sendable, Equatable {
  case sync(SyncStop)
  case seed(SampleSeedError)
  case notSaved
}

extension WireRowRecord.Disposition {
  init(_ outcome: PageReader.RowOutcome) {
    switch outcome {
    case .opened: self = .folded
    case .setAside(_, let alarm): self = alarm ? .alarm : .setAside
    }
  }
}
