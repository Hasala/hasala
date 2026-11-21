import CoreAuth
import CoreCategorize
import CoreDomain
import CoreOutbox
import CoreProjection
import CoreReplay
import CoreSync
import CoreTestSupport
import Foundation
import Testing

let bundledDictionary = (try? MerchantDictionary.bundled().get()) ?? .empty

final class Runtime: Sendable {
  let context: SyncContext
  let projection: ProjectionStore
  let observer: LedgerPageObserver
  let engine: SyncEngine
  let outbox: Outbox

  init(_ context: SyncContext, projection: ProjectionStore? = nil) throws {
    self.context = context
    self.projection = try projection ?? ProjectionStore.inMemory()
    observer = LedgerPageObserver(context: context, projection: self.projection, dictionary: bundledDictionary)
    engine = SyncEngine(context: context, observer: observer)
    outbox = Outbox(store: context.store, clock: context.clock, debounce: .seconds(3600), onAuthored: {})
  }

  var reader: LedgerReader { projection.reader }

  @discardableResult
  func author(_ body: (inout OpAuthor) throws -> Void) async throws -> AuthoredBlob {
    let ctx = try await observer.authorContext()
    let blob = try observer.stamps.authoring { (floor: Int64?) throws -> (value: AuthoredBlob, lastMs: Int64?) in
      var a = OpAuthor(ctx.raised(to: floor))
      try body(&a)
      let b = try a.build()
      return (b, b.lastAuthoredMs)
    }
    try await outbox.enqueue(blob.ops)
    try await observer.reproject()
    return blob
  }

  func bootstrap() async throws {
    try await author { a in
      a.setHomeCurrency("AED")
      try a.setRate(currency: "USD", rateMicro: 3_672_500)
    }
  }

  func loadSample(account: AccountInfo? = nil) async throws -> Int {
    let info: AccountInfo
    if let account {
      info = account
    } else {
      info = try await context.client.account(bearer: try #require(try context.secrets.session()).token)
    }
    let blobs = try await observer.sampleBatches(account: info)
    try await outbox.enqueue(blobs.flatMap(\.ops))
    try await observer.reproject()
    return blobs.reduce(0) { $0 + $1.ops.count }
  }

  @discardableResult
  func run(_ t: SyncTrigger) async -> RunOutcome { await engine.run(t) }

  func state() async throws -> State { try await observer.currentState() }
}

func twoRuntimes(_ w: World = World()) async throws -> (World, Runtime, Runtime) {
  let a = w.phone("a")
  let (account, words, ctxA) = try await w.passwordAccount(a)
  let b = w.phone("b")
  let r = try await AccountSignIn.withPassword(b.env, email: "maya@example.com", password: password, bound: nil)
  let body = try await Enrolment.unlockWithPhrase(b.env, userID: account.userID, typed: words.joined(separator: " "))
  let enrolled = try await Enrolment.enrolWriter(b.env, userID: account.userID, body: body, emailNorm: r.emailNorm, serverSalt: r.serverSalt)
  let ra = try Runtime(ctxA)
  let rb = try Runtime(Enrolment.context(b.env, account: enrolled))
  try await ra.observer.open()
  try await rb.observer.open()
  return (w, ra, rb)
}
