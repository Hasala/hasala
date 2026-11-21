import CoreMailbox
import CorePrimitives
import CoreStore
import CoreSync
import CoreTemplate
import CoreTime
import Foundation

nonisolated final class MailboxLane: Sendable {
  let provider: MailboxProvider
  let engine: MailboxEngine
  let tokens: RefreshingMailTokenProvider
  let presenter: any MailAuthSessionPresenter
  let events = LaneEvents()
  let work = LaneWork()

  init?(
    provider: MailboxProvider, build: BuildInfo, secrets: Secrets, userID: UserID, persistence: any MailboxPersistence,
    ledger: any MailboxLedger, server: any MailboxServer, stepUp: any MailboxStepUp, categorizer: any IngestCategorizer,
    presenter: any MailAuthSessionPresenter, mailHTTP: (any HTTPExchange)? = nil
  ) {
    let http = mailHTTP ?? URLSessionHTTPExchange.ephemeral(maxResponseBytes: MailboxLimits.maxResponseBytes)
    let clock = SystemClock()
    let mail: any MailProvider
    switch provider {
    case .gmail:
      let config = GmailOAuthConfig(clientID: build.googleClientID, redirectScheme: build.googleRedirectScheme)
      guard config.isConfigured else { return nil }
      mail = GmailProvider(oauth: GoogleOAuthClient(config: config, http: http), http: http)
    case .outlook:
      let config = MicrosoftOAuthConfig(clientID: build.outlookClientID, redirectScheme: build.outlookRedirectScheme)
      guard config.isConfigured else { return nil }
      mail = OutlookProvider(
        oauth: MicrosoftOAuthClient(config: config, http: http), http: http,
        link: SecretsOutlookLinkStore(secrets: secrets, userID: userID), clock: clock)
    }
    self.provider = provider
    tokens = RefreshingMailTokenProvider(
      oauth: mail.oauth, store: SecretsMailRefreshTokenStore(secrets: secrets, userID: userID, provider: provider.providerID),
      clock: clock)
    engine = MailboxEngine(
      config: MailboxEngineConfig(grantID: userID.string, buildTopic: nil), provider: mail, tokens: tokens,
      store: persistence, ledger: ledger, server: server, stepUp: stepUp, categorizer: categorizer,
      templates: Self.mailTemplates, clock: clock, random: SystemRandom(), readerKeys: SecretsMailReaderKeyStore(secrets: secrets))
    self.presenter = presenter
  }

  func relayEvents() async {
    let events = self.events
    await engine.setProgressHandler { events.send(.progress($0)) }
    await engine.setCommitHandler { events.send(.committed) }
  }

  func hasGrant() async -> Bool? { await tokens.hasRefreshToken() }

  func connect(
    backfillDays: Int, pastMail: MailboxPastMail = .read, replacing: Bool = false, retiring: MailboxRetirePlan? = nil,
    confirm: MailboxSwitchConfirm? = nil
  ) async -> ConnectResult {
    if let refused = await MailGrantEnds.shared.connectGate() { return refused }
    let r = await engine.connect(
      presenter: presenter, backfillDays: backfillDays, pastMail: pastMail, replacing: replacing, retiring: retiring,
      confirm: confirm)
    if case .connected = r {
      BackgroundScheduler.shared.scheduleProcessing()
    }
    return r
  }

  struct FirstScanTotals: Sendable, Equatable {
    var ops = 0
    var byRules = 0
    var byDictionary = 0
    var byModel = 0
    var toReview = 0
    var phase: MailboxPhase = .scanning
    var haltedOn: MailboxHaltCode?

    mutating func add(_ r: CycleReport) {
      ops += r.ops
      byRules += r.sortedBy["rule"] ?? 0
      byDictionary += r.sortedBy["dictionary"] ?? 0
      byModel += r.sortedBy["model"] ?? 0
      toReview += r.toReview
      phase = r.phase
      haltedOn = r.haltedOn
    }

    var pause: MailboxProgress? {
      guard phase == .scanning || phase == .authoringBackfill, let code = haltedOn, code != .stagingFull else {
        return nil
      }
      return MailboxProgress(stage: .failed(code), done: 0, total: 0)
    }
  }

  enum FirstScanEvent: Sendable {
    case progress(MailboxProgress)
    case ended(FirstScanTotals)
  }

  func firstScan() -> AsyncStream<FirstScanEvent> {
    let engine = self.engine
    let events = self.events
    let work = self.work
    return AsyncStream { continuation in
      let started = work.start {
        await self.relayEvents()
        let id = events.add { if case .progress(let p) = $0 { continuation.yield(.progress(p)) } }
        var totals = FirstScanTotals()
        for r in await engine.runFirstScan(maxCycles: 50) { totals.add(r) }
        events.remove(id)
        if let pause = totals.pause { events.send(.progress(pause)) }
        continuation.yield(.ended(totals))
        continuation.finish()
      }
      if !started {
        continuation.yield(.ended(FirstScanTotals(phase: .halted)))
        continuation.finish()
      }
    }
  }

  func importWindow(senders: [String]) async -> [(domain: String, sinceMs: Int64)] {
    await engine.importWindow(senders: senders)
  }

  func backfill(senders: [String]) {
    let engine = self.engine
    work.start { _ = await engine.backfill(senders: senders) }
  }

  func importPastMail() async -> CycleReport { await engine.importPastMail() }

  func stop() async {
    work.markCut()
    await engine.stop()
    await work.cancelAll()
  }

  func resume(restartingCut restart: Bool) async {
    await engine.resume()
    guard work.takeCut(), restart else { return }
    let engine = self.engine
    work.start { _ = await engine.runFirstScan(maxCycles: 50) }
  }

  var isStopped: Bool { get async { await engine.stopped } }

  func close() async {
    work.close()
    await engine.stop()
    await work.cancelAll()
  }

  static let mailTemplates: [CompiledTemplate] = BundledTemplates.load(channel: .mail).templates

  static let mailDefinitions: [TemplateDefinition] = mailTemplates.map(\.definition)

  static func senderDomains(bank: String) -> [String] {
    BankDomains.templateDomains(bank: bank, templates: mailDefinitions)
  }

  func status() async -> MailboxStatus { await engine.status() }
  func retirePlan() async -> MailboxRetirePlan? { await engine.retirePlan() }
  func disconnect(removing plan: MailboxRetirePlan?) async -> MailboxDisconnectOutcome {
    await engine.disconnect(removing: plan)
  }
  func retire(_ plan: MailboxRetirePlan) async -> MailboxRetireOutcome { await engine.retire(plan) }
  func retryHeld(_ plan: MailboxRetirePlan) async -> MailboxHeldRetryOutcome { await engine.retryHeld(plan) }
  func dropHeld(_ plan: MailboxRetirePlan) async { await engine.dropHeld(plan) }
  func endGrant() async {
    _ = work.takeCut()
    await engine.endGrant()
  }
  func addSender(_ typed: String) async -> Result<CycleReport, BankDomains.TypedDomainError> {
    await engine.importSender(typed)
  }
  func probeSenders(_ domains: [String]) async -> SenderProbeResult { await engine.probeSenders(domains) }

  func cycle(trigger: MailboxTrigger, deadlineMs: Int64? = nil) async -> CycleReport {
    await engine.runCycle(trigger: trigger, deadlineMs: deadlineMs)
  }
}

nonisolated final class LaneWork: @unchecked Sendable {
  private let lock = NSLock()
  private var tasks: [UUID: Task<Void, Never>] = [:]
  private var closed = false
  private var cut = false

  @discardableResult
  func start(_ body: @escaping @Sendable () async -> Void) -> Bool {
    let id = UUID()
    return lock.withLock {
      guard !closed else { return false }
      tasks[id] = Task {
        await body()
        self.finished(id)
      }
      return true
    }
  }

  private func finished(_ id: UUID) {
    _ = lock.withLock { tasks.removeValue(forKey: id) }
  }

  func close() { lock.withLock { closed = true } }

  var isClosed: Bool { lock.withLock { closed } }

  var running: Int { lock.withLock { tasks.count } }

  func markCut() {
    lock.withLock { if !tasks.isEmpty { cut = true } }
  }

  func cancelAll() async {
    let all = lock.withLock { () -> [Task<Void, Never>] in
      if !tasks.isEmpty { cut = true }
      return Array(tasks.values)
    }
    for t in all { t.cancel() }
    for t in all { await t.value }
  }

  func takeCut() -> Bool {
    lock.withLock {
      defer { cut = false }
      return cut
    }
  }
}

nonisolated final class LaneEvents: @unchecked Sendable {
  enum Event: Sendable {
    case progress(MailboxProgress)
    case committed
  }

  private let lock = NSLock()
  private var listeners: [UUID: @Sendable (Event) -> Void] = [:]

  @discardableResult
  func add(_ listener: @escaping @Sendable (Event) -> Void) -> UUID {
    let id = UUID()
    lock.withLock { listeners[id] = listener }
    return id
  }

  func remove(_ id: UUID) {
    _ = lock.withLock { listeners.removeValue(forKey: id) }
  }

  func send(_ event: Event) {
    for listener in lock.withLock({ Array(listeners.values) }) { listener(event) }
  }
}

extension MailboxProvider {
  nonisolated var providerID: MailProviderID { self == .gmail ? .gmail : .outlook }
}

nonisolated struct HeldMailGrants: Sendable, Equatable {
  struct Grant: Sendable, Equatable {
    var provider: MailboxProvider
    var refreshToken: String
    var subscriptionID: String?
  }
  var grants: [Grant]
}

nonisolated final class MailGrantEnds: @unchecked Sendable {
  static let shared = MailGrantEnds()
  static let departureWait: Duration = .seconds(10)
  static let connectWait: Duration = .seconds(20)
  static let requestLimit: TimeInterval = 3
  static let requestsPerEnding = 5

  nonisolated static func http() -> URLSessionHTTPExchange {
    let c = URLSessionConfiguration.ephemeral
    c.httpCookieStorage = nil
    c.httpShouldSetCookies = false
    c.urlCache = nil
    c.urlCredentialStorage = nil
    c.requestCachePolicy = .reloadIgnoringLocalCacheData
    c.timeoutIntervalForRequest = requestLimit
    c.timeoutIntervalForResource = requestLimit
    c.waitsForConnectivity = false
    return URLSessionHTTPExchange(configuration: c)
  }

  private let lock = NSLock()
  private var last: Task<Void, Never>?

  func enqueue(_ end: @escaping @Sendable () async -> Void) {
    lock.withLock {
      let before = last
      last = Task {
        await before?.value
        await end()
      }
    }
  }

  func end(within limit: Duration = MailGrantEnds.departureWait, _ work: @escaping @Sendable () async -> Void) async {
    enqueue(work)
    _ = await Task { await self.settled(within: limit) }.value
  }

  func connectGate(within limit: Duration = MailGrantEnds.connectWait) async -> ConnectResult? {
    await settled(within: limit) ? nil : .failed(.google)
  }

  @discardableResult
  func settled(within limit: Duration) async -> Bool {
    guard let pending = lock.withLock({ last }) else { return true }
    let done = Task { () -> Bool in
      await pending.value
      return true
    }
    return await WorkCoordinator.wait(
      for: done, until: ContinuousClock.now + limit, timedOut: false, cancelled: false)
  }
}

extension MailboxLane {
  nonisolated static func heldGrant(secrets: Secrets, userID: UserID) -> HeldMailGrants? {
    var grants: [HeldMailGrants.Grant] = []
    for p in MailboxProvider.allCases {
      guard let token = try? SecretsMailRefreshTokenStore(secrets: secrets, userID: userID, provider: p.providerID).read(),
        !token.isEmpty, token != RefreshingMailTokenProvider.writeCheckValue
      else { continue }
      let sub = p == .outlook ? (try? SecretsOutlookLinkStore(secrets: secrets, userID: userID).read())??.subscriptionID : nil
      grants.append(.init(provider: p, refreshToken: token, subscriptionID: sub))
    }
    return grants.isEmpty ? nil : HeldMailGrants(grants: grants)
  }

  nonisolated static func endGrantThenWipe(
    _ env: AccountEnvironment, userID: UserID, writerID: WriterID?, ends: MailGrantEnds = .shared,
    within limit: Duration = MailGrantEnds.departureWait, ending: @escaping @Sendable (HeldMailGrants) async -> Void
  ) async {
    if let held = heldGrant(secrets: env.secrets, userID: userID) {
      await ends.end(within: limit) { await ending(held) }
    }
    AccountWipe.wipe(env, userID: userID, writerID: writerID)
  }

  nonisolated static func endGrant(_ held: HeldMailGrants, build: BuildInfo, stopWatch: Bool) async {
    let http = MailGrantEnds.http()
    for g in held.grants {
      switch g.provider {
      case .gmail:
        let config = GmailOAuthConfig(clientID: build.googleClientID, redirectScheme: build.googleRedirectScheme)
        guard config.isConfigured else { continue }
        let oauth = GoogleOAuthClient(config: config, http: http)
        if stopWatch, let grant = try? await oauth.refresh(refreshToken: g.refreshToken) {
          try? await GmailClient(http: http, accessToken: grant.accessToken).stop()
        }
        try? await oauth.revoke(token: g.refreshToken)
      case .outlook:
        let config = MicrosoftOAuthConfig(clientID: build.outlookClientID, redirectScheme: build.outlookRedirectScheme)
        guard config.isConfigured, stopWatch, let id = g.subscriptionID else { continue }
        let oauth = MicrosoftOAuthClient(config: config, http: http)
        if let grant = try? await oauth.refresh(refreshToken: g.refreshToken) {
          let graph = GraphClient(
            http: http, accessToken: grant.accessToken, link: MemoryOutlookLinkStore(), nowMs: { SystemClock().nowMs() })
          try? await graph.deleteSubscription(id: id)
        }
      }
    }
  }
}
