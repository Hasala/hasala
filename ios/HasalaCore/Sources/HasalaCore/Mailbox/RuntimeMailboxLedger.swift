import CoreDomain
import CoreOutbox
import CoreProjection
import CoreStore
import CoreSync
import Foundation

public actor RuntimeMailboxLedger: MailboxLedger {
  let engine: SyncEngine
  let observer: LedgerPageObserver
  let outbox: Outbox
  public let authoring: MailboxAuthoring
  public nonisolated let textWrites = WriteSerial()

  public static let bankNames: [String: String] = [
    "enbd": "Emirates NBD", "dib": "DIB", "adib": "ADIB", "adcb": "ADCB", "fab": "FAB", "mashreq": "Mashreq",
    "rakbank": "RAKBANK", "cbd": "CBD", "ei": "Emirates Islamic", "hsbc": "HSBC", "citi": "Citibank", "nbf": "NBF",
    "sib": "SIB", "ajman_bank": "Ajman Bank", "uab": "UAB", "liv": "Liv", "wio": "Wio", "alhilal": "Al Hilal Bank",
  ]

  public static func bankName(_ bank: String) -> String { bankNames[bank] ?? bank.uppercased() }

  public init(engine: SyncEngine, observer: LedgerPageObserver, outbox: Outbox, authoring: MailboxAuthoring) {
    self.engine = engine
    self.observer = observer
    self.outbox = outbox
    self.authoring = authoring
  }

  var reader: LedgerReader { observer.reader }

  public func syncToHead() async throws(MailboxLedgerError) {
    let out = await engine.run(.refresh)
    if let stop = out.stop, !Self.tolerable(stop) {
      throw MailboxLedgerError("sync_\(Self.code(stop))")
    }
    if let seen = try? await observer.seenStamps() { authoring.updateSeen(seen) }
  }

  public func senderTrust() async -> [String: Bool] { (try? reader.senderTrust()) ?? [:] }

  public func projectedMessageIDs(among ids: [String]) async -> Set<String> {
    (try? reader.knownMailboxMessageIDs(ids)) ?? []
  }

  public func isIngested(_ ingestID: String) async -> Bool {
    if (try? reader.hasIngest(ingestID)) == true { return true }
    return (try? observer.context.store.hasPendingIngest(ingestID)) == true
  }

  public func authorSenderTrust(domain: String, trusted: Bool) async throws(MailboxLedgerError) {
    let current = BankDomains.effectiveTrusted(await senderTrust())
    try await author { a throws(AuthorError) in
      try a.setSenderTrust(typed: domain, trusted: trusted, currentTrusted: current)
    }
  }

  public func retirePlan(grantID: String, provider: String) async -> MailboxRetirePlan {
    let legacy = ((try? reader.otherMailboxCount(grantID: grantID, provider: provider)) ?? 1) == 0
    guard let counts = try? reader.mailboxImports(grantID: grantID, provider: provider, legacy: legacy) else {
      return MailboxRetirePlan(grantID: grantID, provider: provider, legacy: legacy, total: 0, edited: 0, countKnown: false)
    }
    return MailboxRetirePlan(grantID: grantID, provider: provider, legacy: legacy, total: counts.total, edited: counts.edited)
  }

  public func authorRetire(_ plan: MailboxRetirePlan) async throws(MailboxLedgerError) {
    try await author { a throws(AuthorError) in
      a.retireMailbox(grantID: plan.grantID, provider: plan.provider, legacy: plan.legacy)
    }
  }

  public func flush() async -> FlushOutcome {
    let out = await engine.run(.authored)
    if await engine.status.latch == .accountFull { return .accountFull }
    if case .latched(.accountFull, _)? = out.stop { return .accountFull }
    guard out.stop == nil else { return .failed }
    return (try? observer.context.store.pendingCount()) == 0 ? .flushed : .failed
  }

  func author(_ body: (inout OpAuthor) throws(AuthorError) -> Void) async throws(MailboxLedgerError) {
    let ctx: AuthorContext
    do { ctx = try await observer.authorContext() } catch { throw MailboxLedgerError("context_\(Self.code(error))") }
    let built: AuthoredBlob?
    do { built = try observer.stamps.build(ctx, body) } catch { throw MailboxLedgerError(Self.code(error)) }
    guard let blob = built else { return }
    do { try await outbox.enqueue(blob.ops) } catch { throw MailboxLedgerError("enqueue") }
    try? await observer.reproject()
  }

  static func tolerable(_ stop: SyncStop) -> Bool {
    switch stop {
    case .rateLimited, .latched, .suspended: return true
    default: return false
    }
  }

  static func code(_ stop: SyncStop) -> String {
    switch stop {
    case .offline, .protocolError: "offline"
    case .rateLimited: "rate_limited"
    case .halted: "halted"
    case .latched: "latched"
    case .frozen: "frozen"
    case .needsSignIn: "needs_sign_in"
    case .needsRebind: "needs_rebind"
    case .needsUnlock: "needs_unlock"
    case .keysRequired: "keys_required"
    case .wipe: "wipe"
    case .suspended: "suspended"
    case .notNow: "not_now"
    case .store: "store"
    case .cancelled: "cancelled"
    }
  }

  static func code(_ e: AuthorError) -> String {
    switch e {
    case .invalidOp: "invalid_op"
    case .opTooLarge: "op_too_large"
    case .refused(let r): "refused_\(r)"
    case .random: "random"
    }
  }
}
