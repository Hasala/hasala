import CoreAuth
import CoreCategorize
import CoreDomain
import CoreMailbox
import CoreOutbox
import CoreProjection
import CoreSync
import CoreStore
import Foundation
import HasalaCloud
import HasalaModel
import HasalaModels
import Observation

@MainActor
@Observable
final class AccountRuntime {
  @ObservationIgnored let env: AccountEnvironment
  @ObservationIgnored let binding: AccountBinding
  @ObservationIgnored let context: SyncContext
  @ObservationIgnored let projection: ProjectionStore
  @ObservationIgnored let observer: LedgerPageObserver
  @ObservationIgnored let engine: SyncEngine
  @ObservationIgnored let outbox: Outbox
  @ObservationIgnored let coordinator: WorkCoordinator
  @ObservationIgnored let lanes: [MailboxProvider: MailboxLane]
  @ObservationIgnored private let active: ActiveLane
  @ObservationIgnored let mailboxLedger: RuntimeMailboxLedger
  @ObservationIgnored let mailboxServer: HTTPMailboxServer
  @ObservationIgnored let backlog: BacklogSorter
  @ObservationIgnored let suggestions: ModelSuggestionStage
  @ObservationIgnored let bankTexts: CoreBankTextAuthoring
  @ObservationIgnored let linkCopy: BankTextsLinkKeeper
  @ObservationIgnored private var switchOff: NSObjectProtocol?
  @ObservationIgnored private var switchOn: NSObjectProtocol?
  let store: LiveLedgerStore

  private(set) var activeProvider: MailboxProvider?

  private(set) var serverLink: MailboxLinkStatus?

  private(set) var reviewAccount = false
  @ObservationIgnored private(set) var closed = false
  @ObservationIgnored private var connects = 0
  @ObservationIgnored private(set) var account: AccountInfo?
  @ObservationIgnored var onAccount: (@MainActor (AccountInfo) async -> Void)?
  @ObservationIgnored var onRunCommitted: (@MainActor () async -> Void)?
  @ObservationIgnored private var importFollower: ImportFollower?

  nonisolated static let dictionary = (try? MerchantDictionary.bundled().get()) ?? .empty

  private init(
    env: AccountEnvironment, binding: AccountBinding, context: SyncContext, projection: ProjectionStore,
    observer: LedgerPageObserver, engine: SyncEngine, outbox: Outbox, coordinator: WorkCoordinator,
    lanes: [MailboxProvider: MailboxLane], active: ActiveLane, mailboxLedger: RuntimeMailboxLedger,
    mailboxServer: HTTPMailboxServer, backlog: BacklogSorter, suggestions: ModelSuggestionStage,
    bankTexts: CoreBankTextAuthoring, linkCopy: BankTextsLinkKeeper, store: LiveLedgerStore
  ) {
    self.env = env
    self.binding = binding
    self.context = context
    self.projection = projection
    self.observer = observer
    self.engine = engine
    self.outbox = outbox
    self.coordinator = coordinator
    self.lanes = lanes
    self.active = active
    activeProvider = active.lane?.provider
    self.mailboxLedger = mailboxLedger
    self.mailboxServer = mailboxServer
    self.backlog = backlog
    self.suggestions = suggestions
    self.bankTexts = bankTexts
    self.linkCopy = linkCopy
    self.store = store
  }

  var userID: UserID { context.userID }

  var lane: MailboxLane? { active.lane }

  var providers: [MailboxProvider] { MailboxProvider.allCases.filter { lanes[$0] != nil } }

  var linkedProvider: MailboxProvider? {
    guard let p = activeProvider, let phase = store.mailboxPhase, phase != .unlinked else { return nil }
    return p
  }

  func activate(_ provider: MailboxProvider) {
    guard let lane = lanes[provider] else { return }
    active.set(lane)
    if activeProvider != provider { activeProvider = provider }
    LocalAccountData.setMailboxProvider(provider)
  }

  func connectStarted() { connects += 1 }

  func connectEnded() { connects -= 1 }

  func linkedHere(_ provider: MailboxProvider) {
    activate(provider)
    serverLink = .holder(isThisDevice: true, watchExpiresAtMs: nil)
    linkCopy.connected()
  }

  func unlinkedHere(_ outcome: MailboxDisconnectOutcome) {
    linkCopy.disconnected(outcome)
  }

  nonisolated static func initialLane(
    _ lanes: [MailboxProvider: MailboxLane], held: MailboxProvider? = nil, remembered: MailboxProvider?
  ) async -> MailboxLane? {
    for p in [held, remembered].compactMap({ $0 }) {
      if let lane = lanes[p] { return lane }
    }
    for p in [MailboxProvider.outlook, .gmail] {
      if let lane = lanes[p], await lane.hasGrant() == true { return lane }
    }
    return lanes[.gmail] ?? lanes[.outlook]
  }

  nonisolated static func interruptedSwitch(held: MailboxProvider?, remembered: MailboxProvider?) -> MailboxProvider? {
    guard let held, let remembered, held != remembered else { return nil }
    return remembered
  }

  func finishInterruptedSwitch(held: MailboxProvider?, remembered: MailboxProvider?, defaults: UserDefaults = .standard) {
    guard let held, let old = Self.interruptedSwitch(held: held, remembered: remembered) else { return }
    LocalAccountData.setMailboxProvider(held, defaults)
    guard let lane = lanes[old] else { return }
    lane.work.start { await lane.endGrant() }
  }

  var haltMessage: String? {
    guard store.mailboxHalt == .noMailbox, let provider = activeProvider else { return nil }
    return LiveMailboxConnecting.message(.noMailbox, provider: provider)
  }

  var offersSampleData: Bool { reviewAccount && store.loaded && store.state.txns.isEmpty }

  var mailOffer: MailOffer? {
    guard let lane, store.loaded, let phase = store.mailboxPhase else { return nil }
    return LiveMailboxConnecting.offer(
      phase: phase, halt: store.mailboxHalt, sampleLoaded: store.holdsSample || reviewAccount, serverLink: serverLink,
      provider: lane.provider)
  }

  var mailOfferKnown: Bool {
    guard lane != nil else { return true }
    guard store.loaded, let phase = store.mailboxPhase else { return false }
    return LiveMailboxConnecting.offerKnown(
      phase: phase, sampleLoaded: store.holdsSample || reviewAccount, serverLink: serverLink)
  }

  @ObservationIgnored private(set) var moveNote = MailboxMoveNote(kept: nil, movedAwayMs: nil, current: nil)

  func startMoveNote(current: MailboxPhase?) {
    moveNote = MailboxMoveNote(
      kept: LocalAccountData.mailboxPhaseSeen(), movedAwayMs: LocalAccountData.mailboxMovedAway(), current: current)
    LocalAccountData.setMailboxPhaseSeen(moveNote.lastPhase)
  }

  private func seeMailboxPhase(_ phase: MailboxPhase) {
    guard phase != moveNote.lastPhase else { return }
    moveNote.see(phase, nowMs: context.clock.nowMs())
    LocalAccountData.setMailboxPhaseSeen(phase)
    LocalAccountData.setMailboxMovedAway(moveNote.movedAwayMs)
  }

  func reading(
    textsChosen: Bool, textsLastRunMs: Int64?, textsTestMissed: Bool = false,
    backgroundRefreshOff: Bool = LiveReading.backgroundRefreshOff
  ) -> ReadingState {
    LiveReading.state(readingInputs(textsChosen: textsChosen, textsLastRunMs: textsLastRunMs, textsTestMissed: textsTestMissed,
                                    backgroundRefreshOff: backgroundRefreshOff))
  }

  func readingInputs(
    textsChosen: Bool, textsLastRunMs: Int64?, textsTestMissed: Bool, backgroundRefreshOff: Bool
  ) -> LiveReading.Inputs {
    let provider = lane?.provider ?? .gmail
    let status = lane == nil ? nil : store.readMailboxStatus
    if status != nil, let phase = store.mailboxPhase { seeMailboxPhase(phase) }
    let held = status.flatMap { s in
      lane.flatMap { LiveMailboxConnecting.heldElsewhere(phase: s.phase, link: serverLink, provider: $0.provider) }
    }
    let trusted = LiveMailboxConnecting.banks(
      trusted: BankDomains.effectiveTrusted((try? projection.reader.senderTrust()) ?? [:]))
    return LiveReading.Inputs(
      nowMs: context.clock.nowMs(), known: store.loaded && (lane == nil || status != nil),
      sample: store.holdsSample || reviewAccount, status: status, provider: provider, progress: store.importProgress,
      heldElsewhere: held, textsChosen: textsChosen, textsLastRunMs: textsLastRunMs, textsTestMissed: textsTestMissed, trustedBanks: trusted,
      newestMailRowMs: (try? projection.reader.newestMailboxPostedMs()) ?? nil, txns: store.state.txns,
      backgroundRefreshOff: backgroundRefreshOff, movedAwayMs: moveNote.movedAwayMs)
  }

  func retryMailbox() async {
    _ = await coordinator.run(.retryMail, budget: .seconds(20))
  }

  func refreshMailbox() async {
    guard !closed, let lane else { return }
    store.noteMailbox(await lane.status(), nowMs: context.clock.nowMs())
    await store.reload()
    await checkServerLink()
  }

  func checkServerLink() async {
    guard lane != nil else { return }
    await linkCopy.afterRun(store.mailboxPhase) { _ = await askServerLink() }
  }

  func askServerLink() async -> MailboxLinkStatus? {
    let server = mailboxServer
    guard let (link, provider) = await linkCopy.ask({ try await server.linkStatusAndProvider() }) else { return nil }
    if serverLink != link { serverLink = link }
    if case .holder(false, _) = link, connects == 0, !closed, store.mailboxPhase == .unlinked || store.mailboxPhase == .otherDevice,
      let p = provider.flatMap({ MailboxProvider(rawValue: $0.rawValue) }), p != activeProvider
    {
      activate(p)
      await lanes[p]?.resume(restartingCut: false)
    }
    return link
  }

  static func open(
    env: AccountEnvironment, binding: AccountBinding, enrolled: EnrolledAccount?, build: BuildInfo,
    profile: ProfileInfo, usesPasskey: @escaping @Sendable () async -> Bool,
    stopped: @escaping @Sendable (SyncStop) async -> Void, bankTextFacts: BankTextsFacts = .shared,
    mailHTTP: (any HTTPExchange)? = nil, providerDefaults: UserDefaults = .standard
  ) async throws -> AccountRuntime {
    let context: SyncContext
    if let enrolled, enrolled.userID.string == binding.user_id {
      context = Enrolment.context(env, account: enrolled, build: build.buildNumber)
    } else {
      context = try Enrolment.context(env, binding: binding, build: build.buildNumber)
    }
    let projection: ProjectionStore
    if let dir = env.storeDirectory(for: context.userID) {
      projection = try ProjectionStore.open(directory: dir)
    } else {
      projection = try ProjectionStore.inMemory()
    }
    let observer = LedgerPageObserver(context: context, projection: projection, dictionary: dictionary)
    let engine = SyncEngine(context: context, observer: observer)
    let box = CoordinatorBox()
    let outbox = Outbox(store: context.store, clock: context.clock) {
      await box.get()?.run(.authored)
    }
    let afterRun = AfterRun()
    let authoring = MailboxAuthoring(observer: observer)
    let mailboxLedger = RuntimeMailboxLedger(engine: engine, observer: observer, outbox: outbox, authoring: authoring)
    let mailboxServer = HTTPMailboxServer(
      http: SessionHTTPExchange(transport: env.client.api.transport, secrets: env.secrets), base: env.apiBase)
    let persistence = LedgerMailboxPersistence(
      store: context.store, authoring: authoring, nowMs: { context.clock.nowMs() })
    let stepUp = LiveStepUp(env: env, usesPasskey: usesPasskey, askPassword: { await StepUpPrompt.password($0) })
    let categorizer = PipelineCategorizer(projection: projection, dictionary: dictionary)
    var lanes: [MailboxProvider: MailboxLane] = [:]
    for p in MailboxProvider.allCases {
      lanes[p] = MailboxLane(
        provider: p, build: build, secrets: env.secrets, userID: context.userID, persistence: persistence,
        ledger: mailboxLedger, server: mailboxServer, stepUp: stepUp, categorizer: categorizer,
        presenter: WebAuthenticationPresenter(for: p), mailHTTP: mailHTTP)
    }
    let held = (try? await persistence.loadState())?.heldProvider.flatMap { MailboxProvider(rawValue: $0.rawValue) }
    let remembered = LocalAccountData.mailboxProvider(providerDefaults)
    let active = ActiveLane(await initialLane(lanes, held: held, remembered: remembered))
    let editor = LedgerEditAuthor(observer: observer, outbox: outbox)
    let store = LiveLedgerStore(
      reader: projection.reader, author: editor, profile: profile, prefs: DevicePrefsStore(), clock: LiveLedgerStore.runClock())
    var mailboxStage: WorkCoordinator.MailboxStage?
    if !lanes.isEmpty {
      mailboxStage = { @Sendable (trigger: MailboxTrigger, deadlineMs: Int64?) async -> CycleReport in
        await active.cycle(trigger, deadlineMs)
      }
    }
    let activity = BacklogActivity()
    let link = BacklogLink()
    let suggestions = ModelSuggestionStage(
      observer: observer, outbox: outbox, cache: FMCache(context.store), dictionary: dictionary,
      onDevice: HasalaModelFactory.make(),
      cloud: HasalaCloudFactory.makeCategoryModel(
        baseURL: build.assistBaseURL, clientVersion: build.marketingVersion,
        isEnabled: MerchantSuggestionsSetting.isEnabledReader,
        isAutoFileEnabled: MerchantSuggestionsSetting.isAutoSortEnabledReader,
        refusal: MerchantSuggestionsSetting.refusal(
          version: MerchantSuggestionsSetting.appVersion(marketing: build.marketingVersion, build: build.buildNumber)),
        onScreen: { OnScreen.shared.isOn }),
      onDeviceAlone: BuildSurface.showsUnfinished,
      nowMs: { context.clock.nowMs() },
      backlogActive: { activity.isActive },
      autoFileEnabled: MerchantSuggestionsSetting.isAutoSortEnabledReader,
      cloudBudget: { await link.budget() },
      cloudSpent: { await link.spent($0) },
      willFile: { await link.willFile($0) },
      trusts: TrustCounts.shared.autoFile)
    let backlog = BacklogSorter(
      pass: { await suggestions.backlogPass($0, dayLeft: $1) }, waiting: { await suggestions.backlogWaiting($0) },
      store: .live(BacklogRunStore(context.store)),
      nowMs: { Int64(Date().timeIntervalSince1970 * 1000) },
      importRunning: {
        guard let lane = active.lane else { return false }
        return await importing(lane)
      }, enabled: MerchantSuggestionsSetting.isEnabledReader, activity: activity, mayRun: false)
    link.set(backlog)
    let coordinator = WorkCoordinator(
      stages: WorkCoordinator.Stages(
        sync: { trigger, deadline in
          let out = await engine.run(trigger, deadline: deadline)
          if let seen = try? await observer.seenStamps() { authoring.updateSeen(seen) }
          await Self.authorOpeningOps(after: out, observer: observer, outbox: outbox)
          let phase = await engine.status.phase
          let shown = Self.shownStop(out.stop, phase: phase)
          if shown == nil { await backlog.allowRuns(true) }
          return (out.newData, shown)
        },
        mailbox: mailboxStage,
        categorize: { trigger in
          let followed = await editor.followUp()
          let suggested = await suggestions.run(trigger)
          return (followed || suggested.newData, suggested.offScreen)
        },
        committed: {
          if let lane = active.lane {
            let status = await lane.status()
            await MainActor.run { store.noteMailbox(status, nowMs: context.clock.nowMs()) }
          }
          await store.reload()
          await afterRun.run()
          Task { await backlog.ensure() }
        },
        stopped: { stop in
          await backlog.allowRuns(false)
          await stopped(stop)
        }))
    box.set(coordinator)
    try await observer.open()
    if let lane = active.lane { store.noteMailbox(await lane.status(), nowMs: context.clock.nowMs()) }
    await store.reload()
    let rt = AccountRuntime(
      env: env, binding: binding, context: context, projection: projection, observer: observer, engine: engine,
      outbox: outbox, coordinator: coordinator, lanes: lanes, active: active, mailboxLedger: mailboxLedger,
      mailboxServer: mailboxServer, backlog: backlog, suggestions: suggestions,
      bankTexts: CoreBankTextAuthoring(ledger: mailboxLedger, reader: projection.reader, categorizer: categorizer),
      linkCopy: BankTextsLinkKeeper(facts: bankTextFacts, nowMs: { context.clock.nowMs() }), store: store)
    afterRun.set { [weak rt] in
      await rt?.onRunCommitted?()
      await rt?.refreshAccountIfUnknown()
      await rt?.checkServerLink()
    }
    rt.finishInterruptedSwitch(held: held, remembered: remembered, defaults: providerDefaults)
    rt.linkCopy.ownLink(store.mailboxPhase)
    rt.startMoveNote(current: store.mailboxPhase)
    store.readingSource = { [weak rt] in
      guard let rt else { return nil }
      let texts = bankTextFacts.read(nowMs: context.clock.nowMs())
      return rt.reading(textsChosen: texts.chosen, textsLastRunMs: texts.lastRunMs, textsTestMissed: bankTextFacts.testMissed)
    }
    await store.reload()
    await rt.followImports()
    rt.followSwitch()
    await backlog.watchNetwork()
    Task { await backlog.ensure(retry: true) }
    return rt
  }

  nonisolated static func shownStop(_ stop: SyncStop?, phase: SyncPhase) -> SyncStop? {
    guard case .halted = stop, case .halted(let kind) = phase else { return stop }
    return .halted(kind)
  }

  func start(buildNumber: Int, stopped: @escaping @Sendable (SyncStop) async -> Void) async {
    let probe = await LaunchProbe.run(context, build: buildNumber)
    switch probe {
    case .frozen:
      await backlog.allowRuns(false)
      await stopped(.frozen)
      await refreshAccount()
      return
    case .updateRequired:
      await backlog.allowRuns(false)
      await stopped(.halted(.updateRequired))
      return
    case .unbound:
      await stopped(.needsRebind)
      return
    case .stop(let stop) where WorkCoordinator.endsTheAccount(stop):
      await stopped(stop)
      return
    case .stop(.halted):
      break
    case .ok, .stop:
      await backlog.allowRuns(true)
    }
    await refreshAccount()
    await coordinator.run(.launch)
  }

  func refreshAccount() async {
    guard let token = try? env.secrets.activeSession()?.token else { return }
    guard let info = try? await env.client.account(bearer: token), info.user_id == binding.user_id else { return }
    await adopt(info)
  }

  private func adopt(_ info: AccountInfo) async {
    account = info
    reviewAccount = info.review_account == true
    await onAccount?(info)
  }

  func refreshAccountIfUnknown() async {
    if account == nil { await refreshAccount() }
  }

  func backgroundWork(_ kind: BackgroundScheduler.Kind) async -> Bool {
    switch kind {
    case .refresh:
      _ = await coordinator.run(.bgRefresh, budget: .seconds(25))
      return false
    case .processing:
      _ = await coordinator.run(.bgProcessing)
      guard let lane, !Task.isCancelled else { return false }
      return await Self.importing(lane)
    }
  }

  nonisolated static func importing(_ lane: MailboxLane) async -> Bool {
    await lane.status().phase.isImporting
  }

  nonisolated static func authorOpeningOps(after out: RunOutcome, observer: LedgerPageObserver, outbox: Outbox) async {
    try? await observer.writes.run {
      guard let blob = try await observer.openingOps(after: out) else { return }
      try await outbox.enqueue(blob.ops)
      try await observer.reproject()
    }
  }

  func loadSample() async throws(SetupFailure) {
    guard let token = try? env.secrets.activeSession()?.token else { throw .failed("You're signed out. Sign in again.") }
    let info: AccountInfo
    do {
      info = try await env.client.account(bearer: token)
    } catch {
      throw .offline
    }
    await adopt(info)
    let outbox = self.outbox
    do {
      try await observer.loadSample(account: info) { try await outbox.enqueue($0) }
    } catch .notSaved {
      throw .failed("Couldn't save the sample data. Try again.")
    } catch {
      throw .failed("Sample data isn't available for this account.")
    }
    await store.reload()
    Task { await coordinator.run(.authored) }
  }

  func close() async {
    closed = true
    stopFollowingImports()
    for token in [switchOff, switchOn].compactMap({ $0 }) { NotificationCenter.default.removeObserver(token) }
    switchOff = nil
    switchOn = nil
    await backlog.suspend()
    await coordinator.close()
    await engine.stop()
    for lane in lanes.values { await lane.close() }
    await mailboxLedger.textWrites.hold()
    await backlog.settled()
    await coordinator.finished()
  }

  func holdWork() async {
    await backlog.holdRuns()
    await coordinator.pause()
    for lane in lanes.values { await lane.stop() }
    await mailboxLedger.textWrites.hold()
    await store.writesFinished()
    await observer.writes.finished()
  }

  func resumeWork() async {
    mailboxLedger.textWrites.releaseHold()
    let running = lane
    for other in lanes.values { await other.resume(restartingCut: other === running) }
    let held = await coordinator.resume()
    await backlog.releaseRuns()
    if let held { Task { await coordinator.run(held) } }
  }

  func followSwitch() {
    let sorter = backlog
    let center = NotificationCenter.default
    let defaults = UserDefaults.standard
    switchOff = center.addObserver(forName: MerchantSuggestionsSetting.turnedOff, object: defaults, queue: nil) { _ in
      Task { await sorter.switchedOff() }
    }
    switchOn = center.addObserver(forName: MerchantSuggestionsSetting.turnedOn, object: defaults, queue: nil) { _ in
      Task { await sorter.switchedOn() }
    }
  }

  func sendAllBack() async -> Int {
    let stage = suggestions
    return await backlog.sendAllBack { await stage.sendBack(filed: $0) }
  }

  func followImports() async {
    let sorter = backlog
    let follower = ImportFollower(
      store: store,
      refreshStatus: { [weak self] in
        guard let self, let lane = self.lane else { return }
        self.store.noteMailbox(await lane.status(), nowMs: self.context.clock.nowMs())
      },
      imported: { Task { await sorter.ensure() } })
    follower.follow(lanes.values.map(\.events))
    for lane in lanes.values { await lane.relayEvents() }
    importFollower = follower
  }

  private func stopFollowingImports() {
    importFollower?.stop()
    importFollower = nil
  }
}

@MainActor
final class ImportFollower {
  private let store: LiveLedgerStore
  private let refreshStatus: @MainActor () async -> Void
  private let imported: @MainActor () -> Void
  private var task: Task<Void, Never>?
  private var listeners: [(LaneEvents, UUID)] = []

  init(
    store: LiveLedgerStore, refreshStatus: @escaping @MainActor () async -> Void, imported: @escaping @MainActor () -> Void = {}
  ) {
    self.store = store
    self.refreshStatus = refreshStatus
    self.imported = imported
  }

  func follow(_ sources: [LaneEvents]) {
    let (stream, continuation) = AsyncStream<LaneEvents.Event>.makeStream(bufferingPolicy: .bufferingNewest(64))
    for events in sources { listeners.append((events, events.add { continuation.yield($0) })) }
    task = Task { [weak self] in
      for await event in stream {
        guard let self else { return }
        await self.handle(event)
      }
    }
  }

  func stop() {
    for (events, id) in listeners { events.remove(id) }
    listeners = []
    task?.cancel()
    task = nil
  }

  func handle(_ event: LaneEvents.Event) async {
    switch event {
    case .committed:
      await store.reload()
      imported()
    case .progress(let p):
      store.noteImport(p)
      switch p.stage {
      case .done, .failed:
        await refreshStatus()
        await store.reload()
        imported()
      case .listing, .downloading, .authoring:
        break
      }
    }
  }
}

nonisolated final class AfterRun: @unchecked Sendable {
  private let lock = NSLock()
  private var action: (@Sendable () async -> Void)?

  func set(_ a: @escaping @Sendable () async -> Void) { lock.withLock { action = a } }
  func run() async {
    let a = lock.withLock { action }
    await a?()
  }
}

nonisolated final class CoordinatorBox: @unchecked Sendable {
  private let lock = NSLock()
  private var coordinator: WorkCoordinator?

  func set(_ c: WorkCoordinator) { lock.withLock { coordinator = c } }
  func get() -> WorkCoordinator? { lock.withLock { coordinator } }
}

nonisolated final class ActiveLane: @unchecked Sendable {
  private let lock = NSLock()
  private var current: MailboxLane?

  init(_ lane: MailboxLane?) { current = lane }

  var lane: MailboxLane? { lock.withLock { current } }
  func set(_ lane: MailboxLane) { lock.withLock { current = lane } }

  func cycle(_ trigger: MailboxTrigger, _ deadlineMs: Int64?) async -> CycleReport {
    guard let lane else { return CycleReport() }
    return await lane.cycle(trigger: trigger, deadlineMs: deadlineMs)
  }
}
