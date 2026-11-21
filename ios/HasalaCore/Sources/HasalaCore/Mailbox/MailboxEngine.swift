import CoreJSON
import CoreMail
import CoreNorm
import CorePrimitives
import CoreTemplate
import CoreTime
import Foundation

public enum MailboxDisconnectOutcome: Sendable, Equatable {
  case failed
  case disconnected
  case removed(Int)
  case disconnectedRemoveFailed
  case otherDevice
}

public struct MailboxEngineConfig: Sendable {
  public var grantID: String
  public var buildTopic: String?
  public var maxMessageBytes = MailboxLimits.maxMessageBytes
  public var stagingCap = 5_000
  public var holderCheckIntervalMs: Int64 = 10 * 60_000
  public var accountFullRetryMs: Int64 = 15 * 60_000
  public var authoringMarginMs: Int64 = 5_000
  public var backfillBatch = 200
  public var firstScanCommitEvery = 25
  public var readerSaveEvery = 25
  public var downloadWidth = 4
  public var retryBackoffMs: [Int64] = [400, 1_200]
  public var rateLimitBackoffMs: [Int64] = [1_000, 2_000, 4_000, 8_000]
  public var firstScanStallWaitsMs: [Int64] = [2_000, 5_000, 15_000, 30_000]
  public var watchRenewWindowMs: Int64 = 3 * 86_400_000
  public var maxListPages = 100
  public var messageStrikeLimit = 3
  public var gmailBase = GmailClient.defaultBase

  public init(grantID: String, buildTopic: String? = nil) {
    self.grantID = grantID
    self.buildTopic = buildTopic
  }

  public func grantID(provider: MailProviderID, address: String?) -> String {
    guard let address, !address.isEmpty else { return grantID }
    var key = Data(grantID.utf8)
    key.append(0)
    key.append(contentsOf: provider.rawValue.utf8)
    key.append(0)
    key.append(contentsOf: Self.normalized(address).utf8)
    return "\(grantID)/mbx-\(Hex.encode(sha256(key).prefix(16)))"
  }

  static func normalized(_ address: String) -> String {
    let bytes = Array(address.utf8)
    let blank: Set<UInt8> = [0x20, 0x09, 0x0d, 0x0a]
    guard let first = bytes.firstIndex(where: { !blank.contains($0) }),
      let last = bytes.lastIndex(where: { !blank.contains($0) })
    else { return "" }
    let folded = bytes[first...last].map(asciiLower)
    return String(decoding: folded, as: UTF8.self)
  }
}

public struct CycleReport: Sendable, Equatable {
  public var listed = 0
  public var fetched = 0
  public var ops = 0
  public var review = 0
  public var unreadable = 0
  public var setAside = 0
  public var staged = 0
  public var dup = 0
  public var sortedBy: [String: Int] = [:]
  public var toReview = 0
  public var haltedOn: MailboxHaltCode?
  public var completed = false
  public var phase: MailboxPhase = .unlinked
  public var stateUnread = false
  public var pastImportStarted = false
  public init() {}

  var readMail: Bool { fetched + ops + staged + setAside + unreadable + dup > 0 }

  mutating func count(_ d: MailboxIngestDraft) {
    ops += 1
    if d.needsReview { review += 1 }
    if d.needsReview || d.payload["category"] == nil { toReview += 1 }
    let kind =
      d.payload["unparsed"] == .bool(true) ? "unparsed" : (d.payload["category_source"]?["kind"]?.stringValue ?? "none")
    sortedBy[kind, default: 0] += 1
  }
}

public struct MailboxProgress: Sendable, Equatable {
  public enum Stage: Sendable, Equatable {
    case listing, downloading, authoring, done
    case failed(MailboxHaltCode)
  }
  public var stage: Stage
  public var done: Int
  public var total: Int
  public var thisMonthRead: Bool
  public init(stage: Stage, done: Int, total: Int, thisMonthRead: Bool = false) {
    self.stage = stage
    self.done = done
    self.total = total
    self.thisMonthRead = thisMonthRead
  }

  public static func following(_ event: MailboxProgress, after last: MailboxProgress?, phase: MailboxPhase?) -> MailboxProgress? {
    switch phase {
    case .active?, .unlinked?, .otherDevice?: return nil
    case .scanning?, .awaitingCards?, .authoringBackfill?, .halted?, .reconnectRequired?, nil: break
    }
    var next = event
    if case .failed = event.stage, let last {
      next.done = last.done
      next.total = last.total
    }
    return next
  }
}

public enum ConnectResult: Sendable, Equatable {
  case connected(address: String?, anotherAddress: Bool = false, retired: MailboxRetireOutcome? = nil)
  case cancelled
  case declined
  case failed(ConnectFailure)
}

public enum MailboxRetireOutcome: Sendable, Equatable {
  case removed(Int?)
  case failed
}

public enum MailboxHeldRetryOutcome: Sendable, Equatable {
  case removed(Int?)
  case failed
  case readElsewhere
  case ended
}

public struct MailboxSwitchQuestion: Sendable, Equatable {
  public var oldAddress: String
  public var newAddress: String
  public var transactions: Int?
  public var edited: Int
  public var oldHasNoMailbox: Bool

  public init(oldAddress: String, newAddress: String, transactions: Int?, edited: Int, oldHasNoMailbox: Bool) {
    self.oldAddress = oldAddress
    self.newAddress = newAddress
    self.transactions = transactions
    self.edited = edited
    self.oldHasNoMailbox = oldHasNoMailbox
  }
}

public enum MailboxPastMail: Sendable, Equatable {
  case read
  case skip(catchUpFromMs: Int64? = nil)
}

public enum MailboxSwitchChoice: Sendable, Equatable {
  case keep, remove, cancel
}

public typealias MailboxSwitchConfirm = @Sendable (MailboxSwitchQuestion) async -> MailboxSwitchChoice

public enum ConnectFailure: String, Sendable, Equatable {
  case notConfigured = "not_configured"
  case offline
  case permissionMissing = "permission_missing"
  case noMailbox = "no_mailbox"
  case stateMismatch = "state_mismatch"
  case nonceMismatch = "nonce_mismatch"
  case stepUpFailed = "step_up_failed"
  case serverRefused = "server_refused"
  case mailboxInUse = "mailbox_in_use"
  case keychain
  case google
}

public enum EmailView: Sendable, Equatable {
  case ready(subject: String, text: String)
  case nonHolder
  case reconnectRequired
  case gone
  case offline
}

public struct MailboxStatus: Sendable, Equatable {
  public enum Hero: String, Sendable, Equatable {
    case working, catchingUp = "catching_up", needsYou = "needs_you", otherDevice = "other_device"
    case notConnected = "not_connected"
  }
  public struct SetAsideGroup: Sendable, Equatable {
    public let domain: String
    public let count: Int
    public let newestMs: Int64
  }
  public var hero: Hero
  public var phase: MailboxPhase
  public var address: String?
  public var lastSuccessAtMs: Int64?
  public var haltedOn: MailboxHaltCode?
  public var setAside: [SetAsideGroup]
  public var unreadable: Int
  public var health: [BankHealthRow]
  public var watchActive: Bool
  public var unlisted: [String] = []
  public var unparsedSenders: [String: String] = [:]
  public var readFromMs: Int64?
  public var backfillDays: Int?
  public var connectedAtMs: Int64? = nil
  public var stateUnread = false
  public var heldRetires: [MailboxRetirePlan] = []
}

struct ProviderPause: Sendable {
  private var startedMs: Int64 = 0
  private var untilMs: Int64 = 0

  mutating func begin(retryAfterSec sec: Int64, now: Int64) {
    startedMs = now
    untilMs = now + min(max(sec, 1), 600) * 1000
  }

  func remainingMs(now: Int64) -> Int64 { now < startedMs ? 0 : max(0, untilMs - now) }
}

public actor MailboxEngine {
  public let config: MailboxEngineConfig
  public let provider: any MailProvider
  let tokens: RefreshingMailTokenProvider
  let store: any MailboxPersistence
  let ledger: any MailboxLedger
  let server: any MailboxServer
  let stepUp: any MailboxStepUp
  let categorizer: any IngestCategorizer
  let templates: [CompiledTemplate]
  let clock: any Clock
  let random: any RandomSource
  let readerKeys: any MailReaderKeyStore
  let sleep: @Sendable (Int64) async -> Void

  private var busy = false
  private var onProgress: (@Sendable (MailboxProgress) -> Void)?
  private var onCommit: (@Sendable () -> Void)?
  private var scanTotal = 0
  private var thisMonthRead = false
  private var quotaStrikes = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var textsRead: TextOverlap??
  private var push: MailboxPushConfig?
  private var pushReadAtMs: Int64 = 0
  public private(set) var topicMismatch = false
  private var pause = ProviderPause()
  private var firstScanRunning: Bool { firstScanFollowers != nil }
  private var firstScanFollowers: [CheckedContinuation<[CycleReport], Never>]?
  public private(set) var stopped = false
  public private(set) var disconnectsWaiting = 0
  private var retiresRunning: Set<String> = []
  private var retiresNotRecorded: Set<String> = []
  private var readElsewhere: Set<String> = []
  private var heldAskedAtMs: Int64?
  private var lastStatus: MailboxStatus?
  private var strayTokenAskedAtMs: Int64?

  public init(
    config: MailboxEngineConfig, provider: any MailProvider, tokens: RefreshingMailTokenProvider,
    store: any MailboxPersistence, ledger: any MailboxLedger,
    server: any MailboxServer, stepUp: any MailboxStepUp, categorizer: any IngestCategorizer,
    templates: [CompiledTemplate], clock: any Clock, random: any RandomSource,
    readerKeys: any MailReaderKeyStore = MemoryMailReaderKeyStore(),
    sleep: @escaping @Sendable (Int64) async -> Void = { ms in try? await Task.sleep(for: .milliseconds(ms)) }
  ) {
    self.config = config
    self.provider = provider
    self.tokens = tokens
    self.store = store
    self.ledger = ledger
    self.server = server
    self.stepUp = stepUp
    self.categorizer = categorizer
    self.templates = templates.filter { !$0.definition.isSMS }
    self.clock = clock
    self.random = random
    self.readerKeys = readerKeys
    self.sleep = sleep
  }

  public init(
    config: MailboxEngineConfig, oauth: GoogleOAuthClient, tokens: RefreshingMailTokenProvider,
    gmailHTTP: any HTTPExchange, store: any MailboxPersistence, ledger: any MailboxLedger,
    server: any MailboxServer, stepUp: any MailboxStepUp, categorizer: any IngestCategorizer,
    templates: [CompiledTemplate], clock: any Clock, random: any RandomSource,
    readerKeys: any MailReaderKeyStore = MemoryMailReaderKeyStore(),
    sleep: @escaping @Sendable (Int64) async -> Void = { ms in try? await Task.sleep(for: .milliseconds(ms)) }
  ) {
    self.init(
      config: config, provider: GmailProvider(oauth: oauth, http: gmailHTTP, base: config.gmailBase), tokens: tokens,
      store: store, ledger: ledger, server: server, stepUp: stepUp, categorizer: categorizer, templates: templates,
      clock: clock, random: random, readerKeys: readerKeys, sleep: sleep)
  }

  public func setProgressHandler(_ h: (@Sendable (MailboxProgress) -> Void)?) { onProgress = h }

  public func setCommitHandler(_ h: (@Sendable () -> Void)?) { onCommit = h }

  func emit(_ stage: MailboxProgress.Stage, _ done: Int, _ total: Int) {
    onProgress?(MailboxProgress(stage: stage, done: done, total: total, thisMonthRead: thisMonthRead))
  }

  private func acquire() async {
    if !busy {
      busy = true
      return
    }
    await withCheckedContinuation { waiters.append($0) }
  }

  private func release() {
    if waiters.isEmpty {
      busy = false
    } else {
      waiters.removeFirst().resume()
    }
  }

  private func exclusive<T: Sendable>(_ body: () async -> T) async -> T {
    await acquire()
    textsRead = nil
    defer {
      textsRead = nil
      release()
    }
    return await body()
  }

  func textOverlap() async throws(MailboxLedgerError) -> TextOverlap? {
    if let read = textsRead { return read }
    let read = try await ledger.textOverlap()
    textsRead = .some(read)
    return read
  }

  public func stop() async {
    stopped = true
    await acquire()
    release()
  }

  public func resume() {
    stopped = false
  }

  public static func backfillDays(newestImportMs: Int64?, nowMs: Int64) -> Int {
    guard let newest = newestImportMs else { return 90 }
    let gapDays = (nowMs - newest) / 86_400_000 + 2
    return gapDays <= 90 ? 90 : 365
  }

  public func connect(
    presenter: any MailAuthSessionPresenter, backfillDays: Int, pastMail: MailboxPastMail = .read,
    replacing: Bool = false, retiring: MailboxRetirePlan? = nil, confirm: MailboxSwitchConfirm? = nil
  ) async -> ConnectResult {
    let (result, plan) = await exclusive { () -> (ConnectResult, MailboxRetirePlan?) in
      stopped = false
      var plan = retiring
      let r = await connectLocked(
        presenter: presenter, backfillDays: backfillDays, pastMail: pastMail, replacing: replacing, confirm: confirm,
        retiring: &plan)
      if let plan {
        if case .connected = r {} else { await endRetire(plan) }
      }
      return (r, plan)
    }
    guard let plan, case .connected(let address, true, _) = result else { return result }
    return .connected(address: address, anotherAddress: true, retired: await retire(plan))
  }

  private func connectLocked(
    presenter: any MailAuthSessionPresenter, backfillDays: Int, pastMail: MailboxPastMail, replacing: Bool,
    confirm: MailboxSwitchConfirm?, retiring: inout MailboxRetirePlan?
  ) async -> ConnectResult {
    let oauth = provider.oauth
    guard oauth.isConfigured else { return .failed(.notConfigured) }
    let nonce: String
    do { nonce = try await server.linkChallenge() } catch .offline { return .failed(.offline) } catch {
      return .failed(.serverRefused)
    }
    let auth: MailAuthorization
    let grant: MailTokenGrant
    do throws(MailOAuthError) {
      auth = try oauth.begin(nonce: nonce, random: random)
      let callback = try await presenter.authorize(url: auth.url, callbackScheme: oauth.redirectScheme)
      let code = try oauth.code(fromCallback: callback, for: auth)
      grant = try await oauth.exchange(code: code, auth: auth)
    } catch .cancelled {
      return .cancelled
    } catch .stateMismatch {
      return .failed(.stateMismatch)
    } catch .missingGrant {
      return .failed(.permissionMissing)
    } catch .offline {
      return .failed(.offline)
    } catch .notConfigured {
      return .failed(.notConfigured)
    } catch {
      return .failed(.google)
    }
    guard let idToken = grant.idToken, let claims = oauth.identity(idToken: idToken) else {
      return .failed(.google)
    }
    guard let n = claims.nonce, constantTimeEquals(Data(n.utf8), Data(nonce.utf8)) else {
      return .failed(.nonceMismatch)
    }
    let probe = AccessToken(value: grant.accessToken, expiresAtMs: clock.nowMs() + grant.expiresIn * 1000)
    do throws(MailAPIError) { try await source(probe).checkMailbox() } catch .noMailbox {
      return .failed(.noMailbox)
    } catch .offline {
      return .failed(.offline)
    } catch where error.status == 401 || error.status == 403 {
      return .failed(.permissionMissing)
    } catch {}
    let stored: MailboxState?
    if replacing {
      stored = nil
    } else {
      do throws(MailboxPersistenceError) { stored = try await store.loadState() } catch { return .failed(.keychain) }
    }
    if let stored, Self.identityUnknown(linked: stored.address, signedIn: claims.email) {
      return .failed(.permissionMissing)
    }
    let otherMailbox = stored.map { Self.isAnotherMailbox(linked: $0.address, signedIn: claims.email) } ?? false
    let fresh = replacing || otherMailbox
    if otherMailbox, let old = stored {
      var plan = await ledger.retirePlan(grantID: self.grant(old), provider: provider.id.rawValue)
      plan.address = old.address
      let noMailbox = old.phase == .halted && old.haltedOn == .noMailbox
      let imported = plan.countKnown ? plan.total : nil
      if !noMailbox || imported != 0 {
        let question = MailboxSwitchQuestion(
          oldAddress: old.address ?? "", newAddress: claims.email ?? "", transactions: imported, edited: plan.edited,
          oldHasNoMailbox: noMailbox)
        switch await confirm?(question) ?? .cancel {
        case .cancel: return .declined
        case .keep: break
        case .remove: retiring = imported == 0 ? nil : plan
        }
      }
    }
    let proof: JSONValue
    do { proof = try await stepUp.proof(kind: "mailbox.link", payloadHash: sha256(Data(idToken.utf8))) } catch {
      return .failed(.stepUpFailed)
    }
    var replacedToken: String?
    do throws(MailAuthError) {
      if otherMailbox { try await tokens.checkWritable(for: grant) } else { replacedToken = try await tokens.replace(with: grant) }
    } catch {
      return .failed(.keychain)
    }
    let link: MailboxLinkResult
    do throws(MailboxServerError) {
      link = try await server.putLink(provider: provider.id, idToken: idToken, stepUp: proof)
    } catch {
      if !otherMailbox { await tokens.restore(replacedToken) }
      switch error {
      case .offline: return .failed(.offline)
      case .refused(409, "mailbox_in_use"): return .failed(.mailboxInUse)
      default: return .failed(.serverRefused)
      }
    }
    if let retiring { await beginRetire(retiring) }
    if otherMailbox {
      var cleared = commitState(MailboxState())
      cleared.clearAll = true
      do { try await commitForgetting(cleared) } catch { return .failed(.keychain) }
      await stopPush()
      _ = await tokens.revokeAndForget(keepOnFailure: false)
      provider.forgetLink()
      pause = ProviderPause()
      quotaStrikes = 0
    }
    do {
      if otherMailbox { try await tokens.install(grant: grant) }
      try provider.installLink(link)
    } catch {
      if otherMailbox { await abandonSwitch() }
      return .failed(.keychain)
    }

    var s = fresh ? MailboxState() : (stored ?? MailboxState())
    switch s.phase {
    case .scanning, .awaitingCards, .authoringBackfill, .active:
      break
    case .unlinked:
      s.phase = .scanning
      s.scanStartedMs = nil
    case .reconnectRequired, .otherDevice, .halted:
      s.phase = resumePhase(s)
    }
    s.address = claims.email
    s.provider = provider.id
    s.haltedOn = nil
    s.haltedDetail = nil
    s.lastHolderCheckAtMs = nil
    s.watchExpiresAtMs = nil
    if s.phase == .scanning && s.scanStartedMs == nil {
      scanTotal = 0
      thisMonthRead = false
      s.backfillDays = [30, 90, 365].contains(backfillDays) ? backfillDays : 90
      let inherited = otherMailbox && stored?.readFromMs != nil
      if let from = await readFrom(pastMail, inherited: inherited, address: claims.email) {
        s.phase = .active
        s.watermarkMs = from
        s.readFromMs = from
      } else {
        s.scanStartedMs = clock.nowMs()
        if let token = try? await tokens.accessToken(forceRefresh: false) {
          s.profileHistoryID = try? await source(token).changeToken()
        }
      }
    }
    var c = commitState(s)
    c.clearAll = fresh
    c.endRetire = ((try? await store.heldRetires()) ?? []).first { links(s, $0) }
    do { try await commitForgetting(c) } catch {
      if otherMailbox { await abandonSwitch() }
      return .failed(.keychain)
    }
    readElsewhere = []
    return .connected(address: claims.email, anotherAddress: otherMailbox)
  }

  private func readFrom(_ pastMail: MailboxPastMail, inherited: Bool, address: String?) async -> Int64? {
    let now = clock.nowMs()
    switch pastMail {
    case .read:
      return inherited ? now : nil
    case .skip(let catchUp):
      guard let catchUp, catchUp < now else { return now }
      let plan = await ledger.retirePlan(
        grantID: config.grantID(provider: provider.id, address: address), provider: provider.id.rawValue)
      return plan.total > 0 ? max(0, catchUp - BankDomains.overlapMs) : now
    }
  }

  private func abandonSwitch() async {
    await tokens.forget()
    provider.forgetLink()
  }

  static func isAnotherMailbox(linked: String?, signedIn: String?) -> Bool {
    let old = MailboxEngineConfig.normalized(linked ?? "")
    let new = MailboxEngineConfig.normalized(signedIn ?? "")
    return !old.isEmpty && !new.isEmpty && old != new
  }

  static func identityUnknown(linked: String?, signedIn: String?) -> Bool {
    !MailboxEngineConfig.normalized(linked ?? "").isEmpty && MailboxEngineConfig.normalized(signedIn ?? "").isEmpty
  }

  public func endGrant() async {
    await exclusive {
      await stopPush()
      await tokens.revokeAndForget(keepOnFailure: false)
      provider.forgetLink()
    }
  }

  public func retirePlan() async -> MailboxRetirePlan? {
    guard let state = try? await store.loadState(), state.phase != .unlinked, state.phase != .otherDevice else { return nil }
    var plan = await ledger.retirePlan(grantID: grant(state), provider: provider.id.rawValue)
    plan.address = state.address
    return plan
  }

  public func disconnect(removing plan: MailboxRetirePlan?) async -> MailboxDisconnectOutcome {
    let outcome = await unlink(removing: plan)
    guard outcome == .disconnected, let plan else { return outcome }
    _ = await ledger.flush()
    return .removed(plan.countKnown ? plan.total : 0)
  }

  public func retire(_ plan: MailboxRetirePlan) async -> MailboxRetireOutcome {
    let removed = MailboxRetireOutcome.removed(plan.countKnown ? plan.total : nil)
    switch await runRetire(plan) {
    case .notHeld:
      return (try? await store.heldRetires())?.contains { Self.same($0, plan) } == true ? .failed : removed
    case .failed:
      await holdRetire(plan)
      return .failed
    case .authored:
      _ = await ledger.flush()
      return removed
    }
  }

  private enum RetireRun { case authored, failed, notHeld }

  private func runRetire(_ plan: MailboxRetirePlan) async -> RetireRun {
    guard retiresRunning.insert(plan.grantID).inserted else { return .notHeld }
    defer { retiresRunning.remove(plan.grantID) }
    if !retiresNotRecorded.contains(plan.grantID), let held = try? await store.pendingRetires(), !held.contains(plan) {
      return .notHeld
    }
    do throws(MailboxLedgerError) { try await ledger.authorRetire(plan) } catch { return .failed }
    await endRetire(plan)
    return .authored
  }

  private func beginRetire(_ plan: MailboxRetirePlan) async {
    var c = MailboxCommit()
    c.beginRetire = plan
    do {
      try await store.commit(c)
      retiresNotRecorded.remove(plan.grantID)
    } catch {
      retiresNotRecorded.insert(plan.grantID)
    }
  }

  private func endRetire(_ plan: MailboxRetirePlan) async {
    retiresNotRecorded.remove(plan.grantID)
    var c = MailboxCommit()
    c.endRetire = plan
    try? await store.commit(c)
  }

  private func holdRetire(_ plan: MailboxRetirePlan) async {
    retiresNotRecorded.remove(plan.grantID)
    var c = MailboxCommit()
    c.holdRetire = await counted(plan)
    try? await store.commit(c)
  }

  private func counted(_ plan: MailboxRetirePlan) async -> MailboxRetirePlan {
    let now = await ledger.retirePlan(grantID: plan.grantID, provider: plan.provider)
    guard now.countKnown else { return plan }
    var kept = plan
    kept.total = now.total
    kept.edited = now.edited
    kept.countKnown = true
    return kept
  }

  private static func same(_ a: MailboxRetirePlan, _ b: MailboxRetirePlan) -> Bool {
    a.grantID == b.grantID && a.provider == b.provider
  }

  public func heldRetires() async -> [MailboxRetirePlan] {
    let state = (try? await store.loadState()) ?? MailboxState()
    return offered((try? await store.heldRetires()) ?? [], state)
  }

  private func offered(_ held: [MailboxRetirePlan], _ state: MailboxState) -> [MailboxRetirePlan] {
    held.filter { !links(state, $0) && !readElsewhere.contains($0.provider) }
  }

  private enum HeldLink { case free, thisIPhone, elsewhere, unknown }

  private func heldLink(_ provider: String) async -> HeldLink {
    guard let id = MailProviderID(rawValue: provider) else { return .unknown }
    let link: HeldLink
    do throws(MailboxServerError) {
      switch try await server.linkStatus(provider: id) {
      case .noLink: link = .free
      case .holder(isThisDevice: true, _): link = .thisIPhone
      case .holder(isThisDevice: false, _): link = .elsewhere
      }
    } catch .otherProvider {
      link = .free
    } catch {
      return .unknown
    }
    if link == .elsewhere { readElsewhere.insert(provider) } else { readElsewhere.remove(provider) }
    return link
  }

  private func readAgain(_ plan: MailboxRetirePlan) async -> Bool {
    guard plan.countKnown else { return false }
    let now = await ledger.retirePlan(grantID: plan.grantID, provider: plan.provider)
    return now.countKnown && now.total > plan.total
  }

  private func checkHeld(_ trigger: MailboxTrigger) async {
    let now = clock.nowMs()
    let due = heldAskedAtMs.map { now < $0 || now - $0 >= config.holderCheckIntervalMs } ?? true
    guard due || trigger == .launch || trigger == .retry || trigger == .refresh else { return }
    guard let held = try? await store.heldRetires(), !held.isEmpty else { return }
    heldAskedAtMs = now
    for provider in Set(held.map(\.provider)) { _ = await heldLink(provider) }
    for plan in held {
      if await readAgain(plan) { await endRetire(plan) }
    }
  }

  private func links(_ state: MailboxState, _ plan: MailboxRetirePlan) -> Bool {
    guard let linked = state.heldProvider, linked.rawValue == plan.provider else { return false }
    return config.grantID(provider: linked, address: state.address) == plan.grantID
  }

  public func retryHeld(_ plan: MailboxRetirePlan) async -> MailboxHeldRetryOutcome {
    let outcome: MailboxHeldRetryOutcome = await exclusive {
      guard let held = try? await store.heldRetires(), let state = try? await store.loadState() else { return .failed }
      guard let kept = held.first(where: { Self.same($0, plan) }) else { return .ended }
      guard !links(state, kept) else { return .failed }
      switch await heldLink(kept.provider) {
      case .elsewhere: return .readElsewhere
      case .unknown: return .failed
      case .thisIPhone where state.heldProvider?.rawValue != kept.provider: return .failed
      case .free, .thisIPhone: break
      }
      if await readAgain(kept) {
        await endRetire(kept)
        return .ended
      }
      do throws(MailboxLedgerError) { try await ledger.authorRetire(kept) } catch { return .failed }
      await endRetire(kept)
      return .removed(kept.countKnown ? kept.total : nil)
    }
    if case .removed = outcome { _ = await ledger.flush() }
    return outcome
  }

  public func dropHeld(_ plan: MailboxRetirePlan) async {
    await exclusive { await endRetire(plan) }
  }

  private func finishRetires() async {
    guard let plans = try? await store.pendingRetires(), !plans.isEmpty else { return }
    var authored = false
    for plan in plans {
      if await runRetire(plan) == .authored { authored = true }
    }
    if authored { _ = await ledger.flush() }
  }

  public func disconnect() async -> Bool { await unlink(removing: nil) == .disconnected }

  private func unlink(removing plan: MailboxRetirePlan?) async -> MailboxDisconnectOutcome {
    disconnectsWaiting += 1
    return await exclusive {
      disconnectsWaiting -= 1
      guard var state = try? await store.loadState() else { return .failed }
      do throws(MailboxServerError) {
        switch try await server.linkStatus(provider: provider.id) {
        case .holder(isThisDevice: false, _):
          return await leaveLink(&state)
        case .noLink, .holder(isThisDevice: true, _):
          break
        }
      } catch .otherProvider {
        guard await otherProviderHolder() == .elsewhere else { return .failed }
        return await leaveLink(&state)
      } catch {
        return .failed
      }
      let proof: JSONValue
      do { proof = try await stepUp.proof(kind: "mailbox.unlink", payloadHash: nil) } catch { return .failed }
      state.watchExpiresAtMs = Self.stoppedWatchExpiryMs
      try? await store.commit(commitState(state))
      await stopPush()
      guard await tokens.revoke() else { return .failed }
      do throws(MailboxServerError) {
        try await server.deleteLink(stepUp: proof)
      } catch .noLink {
      } catch {
        return .failed
      }
      if let plan { await beginRetire(plan) }
      await tokens.forget()
      provider.forgetLink()
      var removeFailed = false
      if let plan {
        do throws(MailboxLedgerError) { try await ledger.authorRetire(plan) } catch { removeFailed = true }
        retiresNotRecorded.remove(plan.grantID)
      }
      var c = MailboxCommit()
      c.clearAll = true
      c.state = MailboxState()
      if removeFailed, let plan { c.holdRetire = await counted(plan) } else { c.endRetire = plan }
      do { try await commitForgetting(c) } catch { return .failed }
      return removeFailed ? .disconnectedRemoveFailed : .disconnected
    }
  }

  private func forgetReader() async {
    var c = MailboxCommit()
    c.clearReader = true
    try? await commitForgetting(c)
  }

  private func commitForgetting(_ c: MailboxCommit) async throws(MailboxPersistenceError) {
    try await store.commit(c)
    if c.clearAll || c.clearReader { try? readerKeys.delete() }
  }

  private func readerKey() -> MailReaderKey? {
    do {
      if let held = try readerKeys.read(), let key = MailReaderKey(secret: held) { return key }
      guard let made = try? random.bytes(MailReaderKey.secretBytes), let key = MailReaderKey(secret: made) else { return nil }
      try readerKeys.write(made)
      return key
    } catch {
      return nil
    }
  }

  private func openReader(address: String?) async -> MailReaderState {
    guard let key = readerKey() else {
      var locked = MailReaderState(address: address)
      locked.training = false
      return locked
    }
    let loaded = (try? await store.loadReader()) ?? nil
    var state = loaded.flatMap { $0.belongs(to: address) ? $0 : nil } ?? MailReaderState(address: address)
    state.attach(key)
    return state
  }

  private func leaveLink(_ state: inout MailboxState) async -> MailboxDisconnectOutcome {
    await endLocalPush()
    await tokens.forget()
    state.lastHolderCheckAtMs = clock.nowMs()
    _ = await setPhase(&state, .otherDevice, halt: .notHolder, CycleReport(), clearReader: true)
    return .otherDevice
  }

  private func forgetTokenOfAStoppedTakeover(_ trigger: MailboxTrigger) async {
    let now = clock.nowMs()
    let due = strayTokenAskedAtMs.map { now < $0 || now - $0 >= config.holderCheckIntervalMs } ?? true
    guard trigger == .launch || trigger == .retry || due, await tokens.hasRefreshToken() == true else { return }
    do throws(MailboxServerError) {
      let link = try await server.linkStatus(provider: provider.id)
      strayTokenAskedAtMs = now
      if case .holder(isThisDevice: false, _) = link { await tokens.forget() }
    } catch .otherProvider {
      strayTokenAskedAtMs = now
    } catch {}
  }

  public func runCycle(trigger: MailboxTrigger, deadlineMs: Int64? = nil) async -> CycleReport {
    await exclusive {
      let report = await cycleLocked(trigger: trigger, deadlineMs: deadlineMs)
      if report.haltedOn == nil && (report.completed || report.readMail) { quotaStrikes = 0 }
      return report
    }
  }

  private func cycleLocked(trigger: MailboxTrigger, deadlineMs: Int64?) async -> CycleReport {
    var report = CycleReport()
    if stopped { return report }
    await finishRetires()
    guard var state = try? await store.loadState() else {
      report.haltedOn = .offline
      report.stateUnread = true
      return report
    }
    report.phase = state.phase
    if state.heldProvider == nil || state.phase == .reconnectRequired { await checkHeld(trigger) }
    if paused {
      report.haltedOn = .gmail
      return report
    }
    if state.phase == .halted {
      guard trigger == .retry || resumesWithoutTryAgain(state, trigger) else {
        report.haltedOn = state.haltedOn
        return report
      }
      state.phase = resumePhase(state)
      state.haltedOn = nil
      state.haltedDetail = nil
    }
    var holderConfirmed = false
    switch state.phase {
    case .unlinked:
      await forgetTokenOfAStoppedTakeover(trigger)
      return report
    case .otherDevice:
      await forgetReader()
      guard holderCheckDue(state, trigger) else { return report }
      let now = clock.nowMs()
      do {
        switch try await server.linkStatus(provider: provider.id) {
        case .noLink:
          var c = MailboxCommit()
          c.clearAll = true
          c.state = MailboxState()
          try? await commitForgetting(c)
          report.phase = .unlinked
          return report
        case .holder(isThisDevice: false, _):
          await tokens.forget()
          state.lastHolderCheckAtMs = now
          return await finish(&state, report)
        case .holder(isThisDevice: true, let watch):
          readElsewhere = []
          state.phase = resumePhase(state)
          state.haltedOn = nil
          state.haltedDetail = nil
          state.lastHolderCheckAtMs = now
          if let watch, state.watchExpiresAtMs == nil { state.watchExpiresAtMs = watch }
          holderConfirmed = true
        }
      } catch .otherProvider {
        state.lastHolderCheckAtMs = now
        return await finish(&state, report)
      } catch {
        report.haltedOn = .offline
        return report
      }
    case .awaitingCards:
      state.phase = .authoringBackfill
    case .reconnectRequired:
      await forgetReader()
      guard trigger == .retry else {
        guard holderCheckDue(state, trigger) else { return report }
        return await recheckHolder(&state, report)
      }
      state.phase = resumePhase(state)
      state.haltedOn = nil
      state.haltedDetail = nil
    default: break
    }
    if templates.isEmpty { return await halt(&state, .templatesUnavailable, report) }

    let now = clock.nowMs()
    if !holderConfirmed && holderCheckDue(state, trigger) {
      do {
        switch try await server.linkStatus(provider: provider.id) {
        case .noLink:
          await endLocalPush()
          return await setPhase(&state, .reconnectRequired, halt: .reconnectRequired, report, clearReader: true)
        case .holder(isThisDevice: false, _):
          await endLocalPush()
          await tokens.forget()
          return await setPhase(&state, .otherDevice, halt: .notHolder, report, clearReader: true)
        case .holder(isThisDevice: true, let watch):
          readElsewhere = []
          state.lastHolderCheckAtMs = now
          if state.watchExpiresAtMs != Self.stoppedWatchExpiryMs { state.watchExpiresAtMs = watch }
        }
      } catch .otherProvider {
        return await linkOnOtherProvider(report, now: now)
      } catch {
        report.haltedOn = .offline
        return report
      }
    }

    do { try await ledger.syncToHead() } catch {
      report.haltedOn = .offline
      return report
    }

    let token: AccessToken
    do { token = try await tokens.accessToken(forceRefresh: false) } catch .reconnectRequired {
      return await setPhase(&state, .reconnectRequired, halt: .reconnectRequired, report)
    } catch {
      report.haltedOn = Self.tokenHalt(error)
      return report
    }
    let source = await listingSource(token)
    let paged = deadlineMs != nil || trigger == .processing

    let trusted = BankDomains.effectiveTrusted(await ledger.senderTrust())
    state.lastCycleAtMs = now

    await renewWatch(source, &state, now: now)

    switch state.phase {
    case .scanning:
      return await scan(source, &state, trusted: trusted, deadlineMs: deadlineMs, paged: paged, report)
    case .authoringBackfill:
      return await authorBackfill(source, &state, trusted: trusted, deadlineMs: deadlineMs, paged: paged, report)
    default: break
    }
    rewindCheckpointAheadOfClock(&state, now: now)

    let h0: String?
    do { h0 = try await source.changeToken() } catch let e {
      return await mailFailure(e, &state, report)
    }
    if trusted.isEmpty {
      state.profileHistoryID = h0
      state.lastSuccessAtMs = now
      if state.watermarkMs == nil { state.watermarkMs = now }
      report.completed = true
      return await finish(&state, report)
    }
    if let h0, h0 == state.profileHistoryID, state.watermarkMs != nil,
      ![.refresh, .launch, .retry].contains(trigger)
    {
      state.lastSuccessAtMs = now
      report.completed = true
      let unchanged = await finish(&state, report)
      return await runImports(source, &state, deadlineMs: deadlineMs, paged: paged, unchanged).report
    }
    let t0 = now

    let since = max(
      BankDomains.sinceSec(watermarkMs: state.watermarkMs ?? (now - 30 * 86_400_000)), (state.readFromMs ?? 0) / 1000)
    var run = Run(trusted: trusted, grant: grant(state), address: state.address)
    let cut: Bool
    do {
      cut = try await listAndProcess(
        source, domains: trusted, sinceSec: since, maxPages: config.maxListPages, mode: .author, paged: paged,
        run: &run, report: &report, deadlineMs: deadlineMs)
    } catch let e as MailAPIError {
      return await mailFailure(e, &state, report)
    } catch {
      report.haltedOn = .offline
      return await finish(&state, report)
    }

    if let stopped = await flushOrStop(&state, report) { return stopped }

    var c = MailboxCommit()
    if !cut {
      state.watermarkMs = max(state.watermarkMs ?? 0, t0)
      state.profileHistoryID = h0
      state.lastSuccessAtMs = clock.nowMs()
      c.pruneAccountedBelowMs = (state.watermarkMs ?? 0) - BankDomains.overlapMs - 86_400_000
      report.completed = true
    }
    c.state = state
    try? await store.commit(c)
    report.phase = state.phase
    if cut || state.phase != .active { return report }
    return await runImports(source, &state, deadlineMs: deadlineMs, paged: paged, report).report
  }

  func rewindCheckpointAheadOfClock(_ state: inout MailboxState, now: Int64) {
    guard let watermark = state.watermarkMs, watermark > now else { return }
    let window = Int64(state.backfillDays ?? 90) * 86_400_000
    let rewound = max(now - window, windowSinceSec(state) * 1000 + BankDomains.overlapMs)
    guard rewound < watermark else { return }
    state.watermarkMs = rewound
    state.profileHistoryID = nil
  }

  private func recheckHolder(_ state: inout MailboxState, _ report: CycleReport) async -> CycleReport {
    var report = report
    let now = clock.nowMs()
    do throws(MailboxServerError) {
      if case .holder(isThisDevice: false, _) = try await server.linkStatus(provider: provider.id) {
        _ = await leaveLink(&state)
        report.haltedOn = .notHolder
        report.phase = state.phase
        return report
      }
      state.lastHolderCheckAtMs = now
      return await finish(&state, report)
    } catch .otherProvider {
      return await linkOnOtherProvider(report, now: now)
    } catch {
      report.haltedOn = .offline
      return report
    }
  }

  private enum OtherProviderHolder { case thisIPhone, elsewhere, unknown }

  private func otherProviderHolder() async -> OtherProviderHolder {
    do throws(MailboxServerError) {
      if case .holder(isThisDevice: true, _) = try await server.linkStatus() { return .thisIPhone }
      return .elsewhere
    } catch {
      return .unknown
    }
  }

  private func linkOnOtherProvider(_ report: CycleReport, now: Int64) async -> CycleReport {
    var report = report
    switch await otherProviderHolder() {
    case .thisIPhone:
      stopped = true
    case .unknown:
      report.haltedOn = .offline
    case .elsewhere:
      await endLocalPush()
      await tokens.forget()
      var elsewhere = MailboxState()
      elsewhere.phase = .otherDevice
      elsewhere.haltedOn = .notHolder
      elsewhere.lastHolderCheckAtMs = now
      var c = commitState(elsewhere)
      c.clearAll = true
      try? await commitForgetting(c)
      report.haltedOn = .notHolder
      report.phase = .otherDevice
      emit(.failed(.notHolder), 0, 0)
    }
    return report
  }

  func holderCheckDue(_ state: MailboxState, _ trigger: MailboxTrigger) -> Bool {
    let now = clock.nowMs()
    let last = state.lastHolderCheckAtMs ?? 0
    return trigger == .launch || trigger == .retry || state.lastHolderCheckAtMs == nil
      || now < last || now - last >= config.holderCheckIntervalMs
  }

  private func scan(
    _ source: any MailSource, _ state: inout MailboxState, trusted: [String], deadlineMs: Int64?, paged: Bool,
    _ report: CycleReport
  ) async -> CycleReport {
    var report = report
    if trusted.isEmpty { return await finish(&state, report) }
    if state.scanStartedMs == nil {
      state.scanStartedMs = clock.nowMs()
      scanTotal = 0
      thisMonthRead = false
    }
    if state.profileHistoryID == nil {
      do { state.profileHistoryID = try await source.changeToken() } catch let e {
        return await mailFailure(e, &state, report)
      }
    }
    let since = windowSinceSec(state)
    var run = Run(trusted: trusted, grant: grant(state), address: state.address)
    run.commitEvery = max(1, config.firstScanCommitEvery)
    var cut: Bool
    do {
      cut = try await listAndProcess(
        source, domains: trusted, sinceSec: since, firstSinceSec: Self.monthStartSec(clock.nowMs()),
        maxPages: config.maxListPages, mode: .stage, paged: paged, run: &run, report: &report, deadlineMs: deadlineMs)
    } catch let e as MailAPIError {
      _ = await commitStaged(&run, &report)
      if run.stop == .accountFull { return await halt(&state, .accountFull, report) }
      return await mailFailure(e, &state, report)
    } catch {
      _ = await commitStaged(&run, &report)
      report.haltedOn = .offline
      return await finish(&state, report)
    }
    switch run.stop {
    case .accountFull?: return await halt(&state, .accountFull, report)
    case let code?:
      report.haltedOn = code
      return await finish(&state, report)
    case nil: break
    }
    if run.stagingFull {
      report.haltedOn = .stagingFull
      cut = false
    }
    guard !cut else { return await finish(&state, report) }
    state.phase = .authoringBackfill
    try? await store.commit(commitState(state))
    return await authorBackfill(
      source, &state, trusted: trusted, deadlineMs: deadlineMs, paged: paged, windowRead: !run.stagingFull && !Task.isCancelled,
      report)
  }

  private func authorBackfill(
    _ source: any MailSource, _ state: inout MailboxState, trusted: [String], deadlineMs: Int64?, paged: Bool,
    windowRead: Bool = false, _ report: CycleReport
  ) async -> CycleReport {
    var report = report
    let total = (try? await store.stagedCount()) ?? 0
    var authored = 0
    thisMonthRead = true
    if total > 0 {
      emit(.authoring, 0, total)
    } else if scanTotal > 0 {
      emit(.authoring, scanTotal, scanTotal)
    }
    while !Task.isCancelled {
      if let d = deadlineMs, clock.nowMs() >= d - config.authoringMarginMs { break }
      guard let n = await authorStagedBatch(grant: grant(state), report: &report) else {
        report.haltedOn = .offline
        return await finish(&state, report)
      }
      if n == 0 { break }
      authored += n
      emit(.authoring, authored, total)
    }
    if let stopped = await flushOrStop(&state, report) { return stopped }
    var remainderDone = windowRead
    if !windowRead, ((try? await store.stagedCount()) ?? 1) == 0 {
      let since = windowSinceSec(state)
      var run = Run(trusted: trusted, grant: grant(state), address: state.address)
      do {
        let cut = try await listAndProcess(
          source, domains: trusted, sinceSec: since, maxPages: config.maxListPages, mode: .author, paged: paged,
          run: &run, report: &report, deadlineMs: deadlineMs)
        remainderDone = !cut
      } catch let e as MailAPIError {
        return await mailFailure(e, &state, report)
      } catch {
        report.haltedOn = .offline
        return await finish(&state, report)
      }
      if let stopped = await flushOrStop(&state, report) { return stopped }
    }
    let stagingEmpty = ((try? await store.stagedCount()) ?? 1) == 0
    if remainderDone && stagingEmpty {
      state.watermarkMs = state.scanStartedMs ?? clock.nowMs()
      state.phase = .active
      state.lastSuccessAtMs = clock.nowMs()
      report.completed = true
      let all = max(total, scanTotal)
      emit(.done, all, all)
    }
    return await finish(&state, report)
  }

  func windowSinceSec(_ state: MailboxState) -> Int64 {
    let days = Int64(state.backfillDays ?? 90)
    return max(0, ((state.scanStartedMs ?? clock.nowMs()) - days * 86_400_000) / 1000)
  }

  func grant(_ state: MailboxState) -> String { config.grantID(provider: provider.id, address: state.address) }

  func authorStagedBatch(grant: String, report: inout CycleReport) async -> Int? {
    guard let batch = try? await store.staged(limit: config.backfillBatch) else { return nil }
    if batch.isEmpty { return 0 }
    let texts: TextOverlap?
    do { texts = try await textOverlap() } catch { return nil }
    var c = MailboxCommit()
    var counted = report
    let at = clock.nowMs()
    for m in batch {
      c.unstage.append(m.messageID)
      if await ledger.isIngested(m.ingestID) {
        c.accounted.append(AccountedRecord(messageID: m.messageID, outcome: .dup, internalDateMs: m.internalDateMs, atMs: at))
        counted.dup += 1
        continue
      }
      let draft = MessageDisposer.finalize(
        m, provider: provider.id, grantID: grant, categorizer: categorizer, texts: texts)
      c.drafts.append(draft)
      c.accounted.append(AccountedRecord(messageID: m.messageID, outcome: .op, internalDateMs: m.internalDateMs, atMs: at))
      if let u = Self.unparsedSender(m, at: at) { c.unparsedSenders.append(u) }
      counted.count(draft)
    }
    do { try await store.commit(c) } catch { return nil }
    report = counted
    return batch.count
  }

  func commitStaged(_ run: inout Run, _ report: inout CycleReport) async -> Bool {
    run.sinceCommit = 0
    var authored = 0
    while true {
      guard let n = await authorStagedBatch(grant: run.grant, report: &report) else {
        run.stop = .offline
        return false
      }
      if n == 0 { break }
      authored += n
    }
    guard authored > 0 else { return true }
    switch await ledger.flush() {
    case .accountFull:
      run.stop = .accountFull
      return false
    case .failed, .flushed: break
    }
    onCommit?()
    return true
  }

  static func monthStartSec(_ nowMs: Int64) -> Int64? {
    guard let d = LocalClock.localDate(nowMs), let first = CivilDate(year: d.year, month: d.month, day: 1) else {
      return nil
    }
    return max(0, LocalClock.startOfDay(first) / 1000)
  }

  public func runFirstScan(maxCycles: Int = 50) async -> [CycleReport] {
    if firstScanFollowers != nil {
      if Task.isCancelled { return [] }
      return await withCheckedContinuation { firstScanFollowers?.append($0) }
    }
    firstScanFollowers = []
    let reports = await driveFirstScan(maxCycles: maxCycles)
    let followers = firstScanFollowers ?? []
    firstScanFollowers = nil
    for follower in followers { follower.resume(returning: reports) }
    return reports
  }

  private func driveFirstScan(maxCycles: Int) async -> [CycleReport] {
    var reports: [CycleReport] = []
    var stalls = 0
    for _ in 0..<maxCycles {
      if Task.isCancelled || stopped { break }
      let r = await runCycle(trigger: .refresh)
      reports.append(r)
      guard r.stateUnread || r.phase == .scanning || r.phase == .authoringBackfill else { break }
      let read = r.readMail
      switch r.haltedOn {
      case nil, .stagingFull?:
        if r.listed == 0 && r.ops == 0 && !r.completed { return reports }
        stalls = 0
      case let code? where Self.passing(code):
        if read {
          stalls = 0
          continue
        }
        guard stalls < config.firstScanStallWaitsMs.count else { return reports }
        let wait = max(config.firstScanStallWaitsMs[stalls], pause.remainingMs(now: clock.nowMs()))
        stalls += 1
        guard wait <= config.firstScanStallWaitsMs.last ?? 0 else { return reports }
        await sleep(wait)
        if Task.isCancelled || stopped { return reports }
      default:
        return reports
      }
    }
    return reports
  }

  static func tokenHalt(_ error: MailAuthError) -> MailboxHaltCode? {
    switch error {
    case .reconnectRequired: .reconnectRequired
    case .notNow: nil
    case .offline: .offline
    }
  }

  static func passing(_ code: MailboxHaltCode) -> Bool {
    code == .gmail || code == .offline || code == .quota
  }

  public func importSender(_ typed: String) async -> Result<CycleReport, BankDomains.TypedDomainError> {
    let domain: String
    var address: String?
    do {
      if provider.listsByAddress {
        let a = try BankDomains.normalizeTypedAddress(typed)
        address = a
        domain = BankDomains.domainOf(a)
      } else {
        domain = try BankDomains.normalizeTyped(typed)
      }
    } catch { return .failure(error) }
    return .success(
      await exclusive {
        var report = CycleReport()
        guard !stopped, var state = try? await store.loadState() else { return report }
        report.phase = state.phase
        do { try await ledger.authorSenderTrust(domain: domain, trusted: true) } catch {
          report.haltedOn = .offline
          return report
        }
        return await importLocked([domain], address: address, &state, report)
      })
  }

  public func importWindow(senders: [String]) async -> [(domain: String, sinceMs: Int64)] {
    let domains = senders.map { $0.lowercased() }.filter(BankDomains.isQuerySafe)
    guard !domains.isEmpty, let state = try? await store.loadState() else { return [] }
    return importWindow(domains, state).map { ($0.domain, $0.sinceMs) }
  }

  private func importWindow(_ domains: [String], _ state: MailboxState) -> [PendingImport] {
    guard state.watermarkMs != nil else { return [] }
    let days = Int64(state.backfillDays ?? 90)
    let sinceMs = max(0, clock.nowMs() - days * 86_400_000, state.readFromMs ?? 0)
    return domains.map { PendingImport(domain: $0, sinceMs: sinceMs) }
  }

  public func backfill(senders: [String]) async -> CycleReport {
    let domains = senders.map { $0.lowercased() }.filter(BankDomains.isQuerySafe)
    return await exclusive {
      var report = CycleReport()
      guard !stopped, !domains.isEmpty, var state = try? await store.loadState() else { return report }
      report.phase = state.phase
      return await importLocked(domains, &state, report)
    }
  }

  private func importLocked(
    _ domains: [String], address: String? = nil, _ state: inout MailboxState, _ report: CycleReport
  ) async -> CycleReport {
    var report = report
    var c = MailboxCommit()
    if let address { c.senderAddresses = [address] }
    c.addImports = importWindow(domains, state)
    guard !c.isEmpty else { return report }
    do { try await store.commit(c) } catch {
      report.haltedOn = .offline
      return report
    }
    guard state.watermarkMs != nil else { return report }
    return await runPendingImports(&state, report)
  }

  public func importPastMail() async -> CycleReport {
    await exclusive {
      var report = CycleReport()
      guard !stopped, var state = try? await store.loadState() else { return report }
      report.phase = state.phase
      guard state.phase == .active, let from = state.readFromMs else { return report }
      let domains = BankDomains.effectiveTrusted(await ledger.senderTrust()).filter(BankDomains.isQuerySafe)
      guard !domains.isEmpty else { return report }
      let days = Int64(state.backfillDays ?? 90)
      let sinceMs = max(0, from - days * 86_400_000)
      state.readFromMs = nil
      state.scanStartedMs = state.scanStartedMs ?? from
      var c = commitState(state)
      c.addImports = domains.map { PendingImport(domain: $0, sinceMs: sinceMs) }
      do { try await store.commit(c) } catch {
        report.haltedOn = .offline
        return report
      }
      report.pastImportStarted = true
      return await runPendingImports(&state, report)
    }
  }

  private func runPendingImports(_ state: inout MailboxState, _ report: CycleReport) async -> CycleReport {
    var report = report
    guard state.phase == .active, !stopped else { return report }
    if paused {
      report.haltedOn = .gmail
      return report
    }
    do { try await ledger.syncToHead() } catch {
      report.haltedOn = .offline
      return report
    }
    let token: AccessToken
    do { token = try await tokens.accessToken(forceRefresh: false) } catch {
      report.haltedOn = Self.tokenHalt(error)
      return report
    }
    let (out, done) = await runImports(await listingSource(token), &state, deadlineMs: nil, paged: false, report)
    report = out
    report.completed = done && report.haltedOn == nil
    return report
  }

  func runImports(
    _ source: any MailSource, _ state: inout MailboxState, deadlineMs: Int64?, paged: Bool, _ report: CycleReport
  ) async -> (report: CycleReport, done: Bool) {
    var report = report
    guard let pending = try? await store.pendingImports() else {
      report.haltedOn = .offline
      return (report, false)
    }
    if pending.isEmpty { return (report, true) }
    let trust = await ledger.senderTrust()
    var trusted = BankDomains.effectiveTrusted(trust)
    let wanted = pending.filter { trust[$0.domain] != false && BankDomains.isQuerySafe($0.domain) }
    for p in wanted where !trusted.contains(p.domain) { trusted.append(p.domain) }
    var done = pending.filter { p in !wanted.contains(p) }.map(\.domain)
    var run = Run(trusted: trusted, grant: grant(state), address: state.address)
    var failure: MailAPIError?
    var offline = false
    for (sinceMs, group) in Dictionary(grouping: wanted, by: \.sinceMs).sorted(by: { $0.key < $1.key }) {
      if shouldStop(deadlineMs) { break }
      let domains = group.map(\.domain)
      do {
        let cut = try await listAndProcess(
          source, domains: domains, sinceSec: sinceMs / 1000, maxPages: config.maxListPages, mode: .author,
          paged: paged, run: &run, report: &report, deadlineMs: deadlineMs)
        if cut { break }
        done += domains
      } catch let e as MailAPIError {
        failure = e
        break
      } catch {
        offline = true
        break
      }
    }
    switch await ledger.flush() {
    case .accountFull:
      await endImports(done)
      return (await halt(&state, .accountFull, report), false)
    case .failed, .flushed: break
    }
    await endImports(done)
    if let failure { return (await mailFailure(failure, &state, report), false) }
    if offline { report.haltedOn = .offline }
    return (report, !offline && done.count == pending.count)
  }

  func endImports(_ domains: [String]) async {
    guard !domains.isEmpty else { return }
    var c = MailboxCommit()
    c.doneImports = domains
    try? await store.commit(c)
  }

  public func probeSenders(_ domains: [String], days: Int = 180) async -> SenderProbeResult {
    let wanted = domains.map { $0.lowercased() }.filter(BankDomains.isQuerySafe)
    return await exclusive {
      guard !stopped, let state = try? await store.loadState() else { return .offline }
      switch state.phase {
      case .otherDevice, .unlinked: return .notReading
      case .reconnectRequired: return .reconnectRequired
      default: break
      }
      if paused { return .offline }
      let token: AccessToken
      do throws(MailAuthError) { token = try await tokens.accessToken(forceRefresh: false) } catch .reconnectRequired {
        return .reconnectRequired
      } catch {
        return .offline
      }
      let source = await listingSource(token)
      let since = max(0, (clock.nowMs() - Int64(days) * 86_400_000) / 1000)
      var found: [String] = []
      for domain in wanted where !found.contains(domain) {
        do throws(MailAPIError) {
          if !(try await source.list(senders: [domain], since: since, pageToken: nil)).ids.isEmpty { found.append(domain) }
        } catch let e {
          notePause(e)
          if let s = e.status, s == 401 || s == 403 { return .reconnectRequired }
          return .offline
        }
      }
      return .found(found)
    }
  }

  public func viewEmail(messageID: String) async -> EmailView {
    await exclusive {
      guard !stopped, let state = try? await store.loadState() else { return .offline }
      switch state.phase {
      case .otherDevice, .unlinked: return .nonHolder
      case .reconnectRequired: return .reconnectRequired
      default: break
      }
      if paused { return .offline }
      let token: AccessToken
      do throws(MailAuthError) { token = try await tokens.accessToken(forceRefresh: false) } catch .reconnectRequired {
        return .reconnectRequired
      } catch {
        return .offline
      }
      let raw: MailRawMessage
      do throws(MailAPIError) { raw = try await source(token).raw(id: messageID) } catch let e {
        notePause(e)
        if let s = e.status, s == 404 || s == 410 { return .gone }
        if let s = e.status, s == 401 || s == 403 { return .reconnectRequired }
        return .offline
      }
      guard let bytes = try? Base64.decodeURL(raw.rawBase64URL) else { return .gone }
      let ms = Int64(raw.internalDate) ?? 0
      guard let n = try? Normalizer.normalize(version: Normalizer.currentVersion, raw: [UInt8](bytes), receivedAtMs: ms)
      else { return .ready(subject: "", text: "") }
      return .ready(subject: n.subject, text: n.text)
    }
  }

  public func status() async -> MailboxStatus {
    guard let state = try? await store.loadState() else { return lastStatus ?? Self.stateUnread }
    let setAside = (try? await store.setAsideRecords()) ?? []
    var groups: [String: (Int, Int64)] = [:]
    for r in setAside {
      let g = groups[r.domain] ?? (0, 0)
      groups[r.domain] = (g.0 + 1, max(g.1, r.internalDateMs))
    }
    let hero: MailboxStatus.Hero
    switch state.phase {
    case .unlinked: hero = .notConnected
    case .otherDevice: hero = .otherDevice
    case .reconnectRequired, .halted: hero = .needsYou
    case .scanning, .awaitingCards, .authoringBackfill: hero = .catchingUp
    case .active:
      let recent = state.lastSuccessAtMs.map { clock.nowMs() - $0 < 6 * 3_600_000 } ?? false
      hero = recent ? .working : .catchingUp
    }
    let status = MailboxStatus(
      hero: hero, phase: state.phase, address: state.address, lastSuccessAtMs: state.lastSuccessAtMs,
      haltedOn: state.haltedOn,
      setAside: groups.map { .init(domain: $0.key, count: $0.value.0, newestMs: $0.value.1) }.sorted {
        $0.newestMs > $1.newestMs
      }, unreadable: ((try? await store.unreadableRecords()) ?? []).count,
      health: (try? await store.bankHealth()) ?? [],
      watchActive: state.watchExpiresAtMs.map { $0 > clock.nowMs() } ?? false,
      unlisted: await unlisted(state), unparsedSenders: (try? await store.unparsedSenders()) ?? [:],
      readFromMs: state.readFromMs, backfillDays: state.backfillDays,
      connectedAtMs: state.scanStartedMs ?? state.readFromMs, heldRetires: offered((try? await store.heldRetires()) ?? [], state))
    lastStatus = status
    return status
  }

  public static let stateUnread = MailboxStatus(
    hero: .needsYou, phase: .halted, address: nil, lastSuccessAtMs: nil, haltedOn: .offline, setAside: [], unreadable: 0,
    health: [], watchActive: false, stateUnread: true)

  public func readerCounts() async -> [String: ReaderCounts] {
    guard let r = (try? await store.loadReader()) ?? nil else { return [:] }
    let address = (try? await store.loadState())?.address
    return r.belongs(to: address) ? r.counts : [:]
  }

  static func unparsedSender(_ m: ParsedMail, from: String = "", at: Int64) -> UnparsedSenderRecord? {
    guard m.fields == nil else { return nil }
    let domain = m.senderDomain ?? BankDomains.domainOf(from)
    return domain.isEmpty ? nil : UnparsedSenderRecord(messageID: m.messageID, domain: domain, atMs: at)
  }

  func unlisted(_ state: MailboxState) async -> [String] {
    guard provider.listsByAddress, state.phase != .unlinked, state.phase != .otherDevice else { return [] }
    let trusted = BankDomains.effectiveTrusted(await ledger.senderTrust())
    return provider.unlisted(trusted, senderAddresses: (try? await store.senderAddresses()) ?? [])
  }

  public func senderAddresses() async -> [String] { (try? await store.senderAddresses()) ?? [] }

  func source(_ token: AccessToken) -> any MailSource { provider.source(accessToken: token) }

  func listingSource(_ token: AccessToken) async -> any MailSource {
    guard provider.listsByAddress else { return source(token) }
    return provider.source(accessToken: token, senderAddresses: (try? await store.senderAddresses()) ?? [])
  }

  func endLocalPush() async {
    if provider.stopIsDeviceScoped { await stopPush() }
    provider.forgetLink()
  }

  func stopPush() async {
    if let token = try? await tokens.accessToken(forceRefresh: false) {
      try? await source(token).stop()
    }
  }

  struct Run {
    var trusted: [String]
    var grant: String
    var address: String?
    var width = 6
    var stagingFull = false
    var saw429 = false
    var commitEvery: Int?
    var firstPass: Set<String> = []
    var sinceCommit = 0
    var stop: MailboxHaltCode?
    var pagedBase: Int?
    var senderAddresses: [String]?
    var reader: MailReaderState?
    var readerLoaded = false
    var readerUnsaved = 0
  }

  enum Mode { case author, stage }

  enum Fetched: Sendable {
    case setAside(id: String, domain: String, internalDateMs: Int64)
    case raw(id: String, from: String, raw: MailRawMessage)
    case gone(id: String)
    case overCap(id: String, from: String?, internalDateMs: Int64?)
    case failed(id: String, error: MailAPIError)
  }

  func shouldStop(_ deadlineMs: Int64?) -> Bool {
    if Task.isCancelled || stopped || disconnectsWaiting > 0 { return true }
    if let d = deadlineMs, clock.nowMs() >= d - config.authoringMarginMs { return true }
    return false
  }

  func listAndProcess(
    _ source: any MailSource, domains: [String], sinceSec: Int64, firstSinceSec: Int64? = nil, maxPages: Int,
    mode: Mode, paged: Bool, run: inout Run, report: inout CycleReport, deadlineMs: Int64?
  ) async throws -> Bool {
    let passes = firstSinceSec.map { $0 > sinceSec ? [$0, sinceSec] : [sinceSec] } ?? [sinceSec]
    if !paged {
      var ids: [String] = []
      var seen = Set<String>()
      var exhausted = true
      for (pass, since) in passes.enumerated() {
        let (listed, done) = try await list(source, domains: domains, sinceSec: since, maxPages: maxPages)
        for id in listed where seen.insert(id).inserted { ids.append(id) }
        if pass == 0 && passes.count > 1 { run.firstPass = seen }
        exhausted = done
      }
      report.listed += ids.count
      let cut = try await process(source, ids: ids, mode: mode, run: &run, report: &report, deadlineMs: deadlineMs)
      return cut || !exhausted
    }
    var seen = Set<String>()
    var cut = false
    run.pagedBase = 0
    for (pass, since) in passes.enumerated() {
      for group in BankDomains.groups(domains, size: source.maxSendersPerList) {
        var token: String?
        var pages = 0
        repeat {
          if shouldStop(deadlineMs) { return true }
          let page = try await source.list(senders: group, since: since, pageToken: token)
          let ids = page.ids.filter { seen.insert($0).inserted }
          report.listed += ids.count
          token = page.nextPageToken
          pages += 1
          if !ids.isEmpty,
            try await process(source, ids: ids, mode: mode, run: &run, report: &report, deadlineMs: deadlineMs)
          {
            return true
          }
        } while token != nil && pages < maxPages
        if token != nil && pass == passes.count - 1 { cut = true }
      }
    }
    return cut
  }

  func list(_ source: any MailSource, domains: [String], sinceSec: Int64, maxPages: Int) async throws(MailAPIError)
    -> ([String], Bool)
  {
    var ids: [String] = []
    var seen = Set<String>()
    var exhausted = true
    for group in BankDomains.groups(domains, size: source.maxSendersPerList) {
      var token: String?
      var pages = 0
      repeat {
        if Task.isCancelled || stopped || disconnectsWaiting > 0 { return (ids, false) }
        let page = try await source.list(senders: group, since: sinceSec, pageToken: token)
        for id in page.ids where seen.insert(id).inserted { ids.append(id) }
        token = page.nextPageToken
        pages += 1
      } while token != nil && pages < maxPages
      if token != nil { exhausted = false }
    }
    return (ids, exhausted)
  }

  func process(
    _ source: any MailSource, ids all: [String], mode: Mode, run: inout Run, report: inout CycleReport,
    deadlineMs: Int64?
  ) async throws -> Bool {
    do {
      let cut = try await processIDs(source, ids: all, mode: mode, run: &run, report: &report, deadlineMs: deadlineMs)
      await saveReader(&run)
      return cut
    } catch {
      await saveReader(&run)
      throw error
    }
  }

  func saveReader(_ run: inout Run) async {
    guard run.readerUnsaved > 0, let reader = run.reader, reader.training else { return }
    var c = MailboxCommit()
    c.reader = reader
    if (try? await store.commit(c)) != nil { run.readerUnsaved = 0 }
  }

  func processIDs(
    _ source: any MailSource, ids all: [String], mode: Mode, run: inout Run, report: inout CycleReport,
    deadlineMs: Int64?
  ) async throws -> Bool {
    let accounted = (try? await store.accounted(among: all)) ?? []
    let projected = await ledger.projectedMessageIDs(among: all)
    let todo = all.filter { !accounted.contains($0) && !projected.contains($0) }
    var i = 0
    let split = run.firstPass.isEmpty ? todo.count : (todo.firstIndex { !run.firstPass.contains($0) } ?? todo.count)
    if !run.saw429 { run.width = max(1, min(config.downloadWidth, provider.maxDownloadWidth)) }
    let skipped = all.count - todo.count
    let base = run.pagedBase ?? 0
    defer { if run.pagedBase != nil { run.pagedBase = base + all.count } }
    if todo.isEmpty && mode == .author { return false }
    if mode == .author { _ = try await textOverlap() }
    var shown = base + all.count
    if mode == .stage {
      if run.pagedBase != nil { shown = max(shown, scanTotal) }
      scanTotal = shown
    }
    emit(.downloading, base + skipped, shown)
    while i < todo.count {
      if shouldStop(deadlineMs) {
        if mode == .stage, run.commitEvery != nil, run.sinceCommit > 0 { _ = await commitStaged(&run, &report) }
        return true
      }
      var width = run.width
      if mode == .stage {
        let room = config.stagingCap - ((try? await store.stagedCount()) ?? 0)
        if room <= 0 {
          run.stagingFull = true
          return true
        }
        width = min(width, room)
      }
      let chunk = Array(todo[i..<min(i + width, i < split ? split : todo.count)])
      i += chunk.count
      let results = await fetchChunk(source, chunk, bank: run.trusted)
      if results.contains(where: \.rateLimited) {
        run.width = 1
        run.saw429 = true
      }
      for r in results {
        try await account(r.fetched, mode: mode, run: &run, report: &report)
      }
      if mode == .stage, let every = run.commitEvery {
        run.sinceCommit += chunk.count
        if run.sinceCommit >= every || i >= todo.count || i == split {
          if !(await commitStaged(&run, &report)) { return true }
          if !run.firstPass.isEmpty && i >= split { thisMonthRead = true }
        }
      }
      emit(.downloading, base + skipped + i, shown)
    }
    return false
  }

  struct FetchResult: Sendable {
    let fetched: Fetched
    let rateLimited: Bool
  }

  func fetchChunk(_ source: any MailSource, _ ids: [String], bank: [String]) async -> [FetchResult] {
    let backoff = config.retryBackoffMs
    let rateBackoff = config.rateLimitBackoffMs
    let maxBytes = config.maxMessageBytes
    let sleep = self.sleep
    let provider = self.provider
    return await withTaskGroup(of: (Int, FetchResult).self) { group in
      for (n, id) in ids.enumerated() {
        group.addTask {
          (
            n,
            await Self.fetchOne(
              source, provider, id, bank: bank, maxBytes: maxBytes, backoff: backoff, rateBackoff: rateBackoff,
              sleep: sleep)
          )
        }
      }
      var out: [(Int, FetchResult)] = []
      for await r in group { out.append(r) }
      return out.sorted { $0.0 < $1.0 }.map(\.1)
    }
  }

  static func fetchOne(
    _ source: any MailSource, _ provider: any MailProvider, _ id: String, bank: [String], maxBytes: Int,
    backoff: [Int64], rateBackoff: [Int64], sleep: @Sendable (Int64) async -> Void
  ) async -> FetchResult {
    var rateLimited = false
    func attempt<T: Sendable>(_ op: () async throws(MailAPIError) -> T) async -> Result<T, MailAPIError> {
      var n = 0
      while true {
        do { return .success(try await op()) } catch let e {
          let s = e.status
          if s == 429 { rateLimited = true }
          if case .throttled = e { return .failure(e) }
          let transient = e == .offline || s == 429 || (s ?? 0) >= 500 || (s ?? 400) < 400
          let waits = s == 429 ? rateBackoff : backoff
          if !transient || n >= waits.count { return .failure(e) }
          await sleep(waits[n])
          n += 1
        }
      }
    }
    func gone(_ e: MailAPIError) -> Bool {
      guard let s = e.status else { return false }
      return s == 404 || s == 410
    }

    func done(_ f: Fetched) -> FetchResult { FetchResult(fetched: f, rateLimited: rateLimited) }
    let meta: MailMessageMetadata
    switch await attempt({ () async throws(MailAPIError) in try await source.metadata(id: id) }) {
    case .success(let m): meta = m
    case .failure(.tooLarge): return done(.overCap(id: id, from: nil, internalDateMs: nil))
    case .failure(let e): return done(gone(e) ? .gone(id: id) : .failed(id: id, error: e))
    }
    let claimed = BankDomains.domainOf(meta.from)
    let analysis = provider.analyzeAuthResults(meta.headerBlock)
    let verified = analysis.verdict.trusted ? (analysis.domain ?? "") : ""
    if !BankDomains.isMember(claimed, of: bank) && !BankDomains.isMember(verified, of: bank) {
      return done(
        .setAside(id: id, domain: verified.isEmpty ? claimed : verified, internalDateMs: Int64(meta.internalDate) ?? 0))
    }
    let dateMs = Int64(meta.internalDate)
    if let size = meta.sizeEstimate, size >= Int64(maxBytes) {
      return done(.overCap(id: id, from: meta.from, internalDateMs: dateMs))
    }
    switch await attempt({ () async throws(MailAPIError) in try await source.raw(id: id) }) {
    case .success(let raw): return done(.raw(id: id, from: meta.from, raw: raw))
    case .failure(.tooLarge): return done(.overCap(id: id, from: meta.from, internalDateMs: dateMs))
    case .failure(let e): return done(gone(e) ? .gone(id: id) : .failed(id: id, error: e))
    }
  }

  func account(_ f: Fetched, mode: Mode, run: inout Run, report: inout CycleReport) async throws {
    let at = clock.nowMs()
    var c = MailboxCommit()
    var interrupted: String?
    switch f {
    case .failed(let id, let error):
      guard let reason = Self.unreadableAfterStrikes(error) else { throw error }
      let n = ((try? await store.strikes(messageID: id)) ?? 0) + 1
      if n < config.messageStrikeLimit {
        c.strikes.append(MessageStrike(messageID: id, count: n, atMs: at))
        try? await store.commit(c)
        throw error
      }
      report.unreadable += 1
      c.unreadable.append(UnreadableRecord(messageID: id, reason: reason, domain: nil, internalDateMs: nil, atMs: at))
      c.accounted.append(AccountedRecord(messageID: id, outcome: .unreadable, internalDateMs: at, atMs: at))
    case .gone(let id):
      report.unreadable += 1
      c.unreadable.append(UnreadableRecord(messageID: id, reason: .gone, domain: nil, internalDateMs: nil, atMs: at))
      c.accounted.append(AccountedRecord(messageID: id, outcome: .gone, internalDateMs: at, atMs: at))
    case .overCap(let id, let from, let dateMs):
      report.unreadable += 1
      c.unreadable.append(
        UnreadableRecord(
          messageID: id, reason: .overCap, domain: from.map(BankDomains.domainOf), internalDateMs: dateMs, atMs: at))
      c.accounted.append(AccountedRecord(messageID: id, outcome: .unreadable, internalDateMs: dateMs ?? at, atMs: at))
    case .setAside(let id, let domain, let date):
      report.setAside += 1
      c.setAside.append(SetAsideRecord(messageID: id, domain: domain, internalDateMs: date, atMs: at))
      c.accounted.append(AccountedRecord(messageID: id, outcome: .setAside, internalDateMs: date, atMs: at))
    case .raw(let id, let from, let raw):
      report.fetched += 1
      let dateMs = Int64(raw.internalDate)
      func unreadable(_ r: UnreadableReason) {
        report.unreadable += 1
        c.unreadable.append(
          UnreadableRecord(messageID: id, reason: r, domain: BankDomains.domainOf(from), internalDateMs: dateMs, atMs: at))
        c.accounted.append(AccountedRecord(messageID: id, outcome: .unreadable, internalDateMs: dateMs ?? at, atMs: at))
      }
      guard let bytes = try? Base64.decodeURL(raw.rawBase64URL) else {
        unreadable(.undecodable)
        break
      }
      if bytes.count >= config.maxMessageBytes {
        unreadable(.overCap)
        break
      }
      guard let date = dateMs, date > 0, Instant.iso(date) != nil else {
        unreadable(.badDate)
        break
      }
      let parsed: MessageDisposer.Parse
      if try await store.isParsing(id) {
        Self.log.notice("mailbox.parse_interrupted", .state("provider", logProvider))
        parsed = .mail(MessageDisposer.unparsed(raw: [UInt8](bytes), messageID: id, internalDateMs: date, spam: raw.spam))
        interrupted = id
      } else {
        try await store.markParsing(id)
        if run.senderAddresses == nil { run.senderAddresses = (try? await store.senderAddresses()) ?? [] }
        let senders = run.senderAddresses ?? []
        if !run.readerLoaded {
          run.reader = await openReader(address: run.address)
          run.readerLoaded = true
        }
        var reader = run.reader
        run.reader = nil
        parsed = MessageDisposer.parse(
          raw: [UInt8](bytes), messageID: id, internalDateMs: date, topLevelFrom: from, templates: templates,
          bankDomains: run.trusted, trusted: run.trusted, provider: provider.id, linkedAddress: run.address, spam: raw.spam,
          reader: &reader, analyze: { provider.analyzeAuthResults($0, inInbox: raw.inInbox, senderAddresses: senders) })
        run.reader = reader
        if parsed != .interrupted {
          run.readerUnsaved += 1
          if run.readerUnsaved >= max(1, config.readerSaveEvery) {
            if reader?.training == true { c.reader = reader }
            run.readerUnsaved = 0
          }
        }
        try await store.clearParsing(id)
      }
      switch parsed {
      case .interrupted:
        return
      case .setAside(let domain):
        report.setAside += 1
        c.setAside.append(SetAsideRecord(messageID: id, domain: domain, internalDateMs: date, atMs: at))
        c.accounted.append(AccountedRecord(messageID: id, outcome: .setAside, internalDateMs: date, atMs: at))
      case .mail(let m):
        if await ledger.isIngested(m.ingestID) {
          report.dup += 1
          c.accounted.append(AccountedRecord(messageID: id, outcome: .dup, internalDateMs: date, atMs: at))
          break
        }
        c.healthBumps.append((BankDomains.domainOf(from), date))
        switch mode {
        case .stage:
          report.staged += 1
          var staged = m
          if staged.senderDomain == nil { staged.senderDomain = Self.unparsedSender(m, from: from, at: at)?.domain }
          c.stage.append(staged)
        case .author:
          let texts = try await textOverlap()
          let draft = MessageDisposer.finalize(
            m, provider: provider.id, grantID: run.grant, categorizer: categorizer, texts: texts)
          report.count(draft)
          c.drafts.append(draft)
          c.accounted.append(AccountedRecord(messageID: id, outcome: .op, internalDateMs: date, atMs: at))
          if let u = Self.unparsedSender(m, from: from, at: at) { c.unparsedSenders.append(u) }
        }
      }
    }
    try await store.commit(c)
    if let interrupted { try? await store.clearParsing(interrupted) }
  }

  static func unreadableAfterStrikes(_ e: MailAPIError) -> UnreadableReason? {
    guard case .status(let s, _) = e else { return nil }
    if s < 400 { return .undecodable }
    if s == 401 || s == 404 || s == 410 || s == 429 || s >= 500 { return nil }
    return .refused
  }

  func renewWatch(_ source: any MailSource, _ state: inout MailboxState, now: Int64) async {
    let readPush = push.map {
      $0 == .none && (now < pushReadAtMs || now - pushReadAtMs >= config.holderCheckIntervalMs)
    } ?? true
    if readPush {
      do {
        let p = try await server.pushConfig(provider: provider.id)
        push = p
        pushReadAtMs = now
        if case .gmail(let t) = p {
          topicMismatch = config.buildTopic != nil && config.buildTopic != "unset" && t != config.buildTopic
        } else {
          topicMismatch = false
        }
      } catch {
        return
      }
    }
    guard let p = push, p != .none else { return }
    if let exp = state.watchExpiresAtMs, exp > now + config.watchRenewWindowMs { return }
    let live = state.watchExpiresAtMs != nil
    guard let w = try? await (live ? source.renew(p) : source.subscribe(p)) else { return }
    do throws(MailboxServerError) {
      try await server.putWatch(expiresAtMs: w.expiresAtMs)
      state.watchExpiresAtMs = w.expiresAtMs
    } catch .noWatchTopic {
      try? await source.stop()
      state.watchExpiresAtMs = nil
      push = nil
    } catch {
    }
  }

  static let stoppedWatchExpiryMs: Int64 = 0

  static let log = CoreLog(category: "CoreMailbox")

  var logProvider: StaticString { provider.id == .outlook ? "outlook" : "gmail" }

  static func kind(_ e: MailAPIError) -> StaticString {
    switch e {
    case .status: "status"
    case .offline: "offline"
    case .unfilteredListing: "unfiltered_listing"
    case .throttled: "throttled"
    case .noMailbox: "no_mailbox"
    case .filterNotApplied: "filter_not_applied"
    case .tooLarge: "too_large"
    }
  }

  func mailFailure(_ e: MailAPIError, _ state: inout MailboxState, _ report: CycleReport) async -> CycleReport {
    var report = report
    Self.log.notice(
      "mailbox.api_failure", .state("provider", logProvider),
      .state("kind", Self.kind(e)), .count("status", e.status ?? 0))
    notePause(e)
    switch e {
    case .noMailbox:
      return await halt(&state, .noMailbox, report)
    case .filterNotApplied:
      return await halt(&state, .gmail, report)
    default: break
    }
    switch e.status {
    case 401?:
      await tokens.invalidate()
      do { _ = try await tokens.accessToken(forceRefresh: true) } catch .reconnectRequired {
        return await setPhase(&state, .reconnectRequired, halt: .reconnectRequired, report)
      } catch {}
      report.haltedOn = .gmail
    case 403?:
      return await setPhase(&state, .reconnectRequired, halt: .reconnectRequired, report)
    case 429?:
      quotaStrikes += 1
      report.haltedOn = quotaStrikes >= 3 ? .quota : .gmail
    case let s? where (400..<500).contains(s):
      return await halt(&state, .gmail, report)
    case nil:
      report.haltedOn = .offline
    default:
      report.haltedOn = .gmail
    }
    return await finish(&state, report)
  }

  private var paused: Bool { pause.remainingMs(now: clock.nowMs()) > 0 }

  private func notePause(_ e: MailAPIError) {
    if case .throttled(let sec, _) = e { pause.begin(retryAfterSec: sec, now: clock.nowMs()) }
  }

  func flushOrStop(_ state: inout MailboxState, _ report: CycleReport) async -> CycleReport? {
    switch await ledger.flush() {
    case .accountFull: return await halt(&state, .accountFull, report)
    case .failed:
      var report = report
      report.haltedOn = .offline
      return await finish(&state, report)
    case .flushed: return nil
    }
  }

  func setPhase(
    _ state: inout MailboxState, _ phase: MailboxPhase, halt code: MailboxHaltCode, _ report: CycleReport, clearReader: Bool = false
  ) async -> CycleReport {
    var report = report
    markResume(&state)
    state.phase = phase
    state.haltedOn = code
    report.haltedOn = code
    return await finish(&state, report, clearReader: clearReader)
  }

  func resumesWithoutTryAgain(_ state: MailboxState, _ trigger: MailboxTrigger) -> Bool {
    switch state.haltedOn {
    case .templatesUnavailable?:
      return !templates.isEmpty
    case .accountFull?:
      if trigger == .launch || trigger == .foreground || trigger == .refresh { return true }
      return clock.nowMs() - (state.lastCycleAtMs ?? 0) >= config.accountFullRetryMs
    default:
      return false
    }
  }

  func halt(_ state: inout MailboxState, _ code: MailboxHaltCode, _ report: CycleReport) async -> CycleReport {
    await setPhase(&state, .halted, halt: code, report)
  }

  func finish(_ state: inout MailboxState, _ report: CycleReport, clearReader: Bool = false) async -> CycleReport {
    var report = report
    let passes = report.haltedOn.map(Self.passing) == true && state.phase != .halted
    if let h = report.haltedOn, h != .stagingFull, !(firstScanRunning && passes) { emit(.failed(h), 0, 0) }
    var c = commitState(state)
    c.clearReader = clearReader
    try? await commitForgetting(c)
    report.phase = state.phase
    return report
  }

  static let resumePrefix = "resume:"

  func markResume(_ state: inout MailboxState) {
    if state.phase == .scanning || state.phase == .authoringBackfill {
      state.haltedDetail = Self.resumePrefix + state.phase.rawValue
    }
  }

  func resumePhase(_ state: MailboxState) -> MailboxPhase {
    if state.watermarkMs != nil { return .active }
    if let d = state.haltedDetail, d.hasPrefix(Self.resumePrefix),
      let p = MailboxPhase(rawValue: String(d.dropFirst(Self.resumePrefix.count))),
      p == .scanning || p == .authoringBackfill
    {
      return p
    }
    return .scanning
  }

  func commitState(_ s: MailboxState) -> MailboxCommit {
    var c = MailboxCommit()
    c.state = s
    return c
  }
}
