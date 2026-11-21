import CoreAuth
import CoreMailbox
import CoreStore
import CoreSync
import Foundation
import HasalaModels
import Observation
import UIKit

@MainActor
@Observable
final class BootController {
  enum State: Equatable {
    case waiting
    case decided
  }

  enum Wall: Equatable {
    case otherAccount(email: String?)
    case foreignData
    case unenrolled
    case restoring
    case openFailed
    case updateRequired
  }

  @ObservationIgnored let env: AppEnvironment
  private(set) var session: AccountSession
  @ObservationIgnored let onboarding: OnboardingStore
  private(set) var state: State = .waiting
  private(set) var runtime: AccountRuntime?
  private(set) var app: AppModel?
  @ObservationIgnored private var widgets: WidgetPublisher?
  @ObservationIgnored private var badge: AppIconBadge?
  private(set) var generation = 0
  private(set) var setupFacts = OnboardingStep.Facts(hasSession: true, keysReady: true)
  private(set) var wall: Wall?
  private(set) var erasing = false
  private(set) var syncHalt: HaltKind?
  private(set) var retryingSync = false

  @ObservationIgnored private let account: LiveAccountService
  @ObservationIgnored private let services: AccountServices
  @ObservationIgnored private let turns = RuntimeTurns<AccountRuntime>()
  @ObservationIgnored private var observingProtectedData = false
  @ObservationIgnored private var startRetry: Task<Void, Never>?
  @ObservationIgnored private var startRetryDelay: Duration = .seconds(1)
  @ObservationIgnored private var syncWatch: Task<Void, Never>?

  init(env: AppEnvironment) {
    self.env = env
    let account = LiveAccountService(env: env.account, build: env.build)
    self.account = account
    let holder = RuntimeHolder()
    let unseenPhrase = StoredUnseenPhrase()
    services = AccountServices(
      account: account, mailbox: LiveMailboxConnecting(
        runtime: { holder.boot?.runtime }, buildProviders: LiveMailboxConnecting.providers(build: env.build)),
      setup: LiveSetupAuthoring(runtime: { holder.boot?.runtime }), notifications: SystemNotificationPermission(),
      hasPasscode: env.hasPasscode, cloudSort: LiveCloudSort(),
      unseenPhrase: unseenPhrase, manualEntry: ManualEntryChoice(defaults: .standard),
      finishRows: FinishSetupRows(defaults: .standard),
      bankTexts: LiveBankTexts(runtime: { holder.boot?.runtime }))
    let first = AccountSession(services: services, phase: .signedOut)
    session = first
    onboarding = OnboardingStore(services: services, session: { [weak holder] in holder?.boot?.session ?? first })
    holder.boot = self
    account.hooks = LiveAccountHooks(
      engine: { [weak self] in self?.runtime?.engine },
      context: { [weak self] in self?.runtime?.context },
      pause: { [weak self] in await self?.runtime?.holdWork() },
      resume: { [weak self] in await self?.runtime?.resumeWork() },
      left: { [weak self] in await self?.left() },
      forgetHomeLayout: { [weak self] in
        self?.app?.forgetHomeLayout()
        HomeLayoutStore.forgetAll()
      },
      otherAccountHere: { [weak self] email in self?.wall = .otherAccount(email: email) },
      deviceUnenrolled: { [weak self] in self?.wall = .unenrolled })
    BackgroundScheduler.shared.install { kind, _ in await BootController.backgroundTask(kind) }
  }

  static func backgroundTask(_ kind: BackgroundScheduler.Kind) async -> Bool {
    await BackgroundEntry.task(BackgroundEntry.live()) { await $0.backgroundWork(kind) }
  }

  var waitingForRuntime: Bool {
    guard state == .decided, runtime == nil, wall == nil else { return false }
    switch session.phase {
    case .onboarding, .ready: return true
    default: return false
    }
  }

  func start() {
    guard state == .waiting else { return }
    guard case .done = env.retryInstallCheck() else { return waitForProtectedData() }
    let facts = Boot.gather(env.account)
    let boot = Boot.decide(facts)
    if boot == .waitingForUnlock { return waitForProtectedData() }
    startRetry?.cancel()
    startRetry = nil
    account.loadProfile()
    LocalAccountData.migrate(boundUserID: facts.binding?.user_id)
    MerchantSuggestionsSetting.migrateReviewAsk(setupFinished: LocalAccountData.setupFinished())
    let (phase, wall) = Self.initialPhase(boot, finished: LocalAccountData.setupFinished())
    Self.dropLockedTextsMarker(phase)
    self.wall = wall
    let decided = AccountSession(services: services, phase: phase)
    decided.onPhaseChange = { [weak self] in self?.phaseChanged($0) }
    decided.onUnfroze = { [weak self] in self?.relaunch() }
    session = decided
    state = .decided
    phaseChanged(session.phase)
    let env = self.env.account
    Task { await LiveAccountService.retryPendingLogout(env) }
  }

  private func waitForProtectedData() {
    if !observingProtectedData {
      observingProtectedData = true
      NotificationCenter.default.addObserver(
        forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.start() }
      }
    }
    guard UIApplication.shared.isProtectedDataAvailable, startRetry == nil else { return }
    let delay = startRetryDelay
    startRetryDelay = min(startRetryDelay * 2, .seconds(30))
    startRetry = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      self?.startRetry = nil
      self?.start()
    }
  }

  static func dropLockedTextsMarker(_ phase: AccountSession.Phase, marker: LockedTextsMarkerFile = .shared) {
    guard phase == .signedOut else { return }
    marker.remove()
  }

  static func initialPhase(_ boot: BootState, finished: Bool) -> (AccountSession.Phase, Wall?) {
    switch boot {
    case .signedOut, .signedOutBound, .waitingForUnlock: (.signedOut, nil)
    case .foreignData: (.signedOut, .foreignData)
    case .unenrolled: (.signedOut, .unenrolled)
    case .restoring: (.signedOut, .restoring)
    case .onboardingKeys, .needsUnlock: (.checking, nil)
    case .opening: (finished ? .ready : .onboarding, nil)
    }
  }

  func phaseChanged(_ phase: AccountSession.Phase) {
    Self.noteReached(phase)
    switch phase {
    case .onboarding, .ready, .frozen:
      openRuntimeIfNeeded()
    case .signedOut:
      let secrets = env.account.secrets
      LocalAccountData.forgetIfNoAccount(binding: { try secrets.binding() })
      Task { await closeRuntime() }
    case .checking, .needsUnlock, .needsKeys:
      break
    }
  }

  static func noteReached(_ phase: AccountSession.Phase, defaults: UserDefaults = .standard) {
    if phase == .ready { LocalAccountData.markSetupFinished(defaults) }
  }

  func openedRuntime() async -> AccountRuntime? {
    if let runtime { return runtime }
    return await turns.opened()
  }

  func foreground() {
    if state == .waiting { start() }
    let env = self.env.account
    Task { await LiveAccountService.retryPendingLogout(env) }
    guard let rt = runtime else { return }
    if syncHalt != nil { return retrySync() }
    Task { await rt.coordinator.run(.foreground) }
    Task { await rt.backlog.ensure() }
  }

  private func openRuntimeIfNeeded() {
    guard runtime == nil, !turns.isOpening, wall == nil, let binding = try? env.account.secrets.binding() else { return }
    if account.enrolled?.userID.string != binding.user_id, !Self.storeExists(env.account, binding) {
      wall = .restoring
      return
    }
    let env = self.env
    let account = self.account
    let profile = Self.profileInfo(account.profile, binding: binding)
    turns.open { [weak self] turn in
      let stopped: @Sendable (SyncStop) async -> Void = { [weak self] stop in await self?.stopped(stop, turn: turn) }
      let rt: AccountRuntime
      do {
        rt = try await AccountRuntime.open(
          env: env.account, binding: binding, enrolled: account.enrolled, build: env.build, profile: profile,
          usesPasskey: { await account.usesPasskey() }, stopped: stopped)
      } catch {
        guard let self, self.turns.isCurrent(turn) else { return nil }
        self.turns.finishOpening(turn)
        if self.session.phase != .signedOut { self.wall = .openFailed }
        return nil
      }
      guard let self, self.turns.isCurrent(turn), self.session.phase != .signedOut else {
        await rt.close()
        return nil
      }
      var facts = Self.facts(rt, texts: self.services.bankTexts)
      if let phase = rt.store.mailboxPhase { facts.mailbox = Self.mailboxFact(phase) }
      self.turns.finishOpening(turn)
      self.runtime = rt
      let layouts = HomeLayoutStore(account: LocalAccountData.digest(binding.user_id, salt: LocalAccountData.salt()))
      let app = AppModel(
        store: rt.store, mailbox: self.services.mailbox, layouts: layouts,
        notificationReads: NotificationReads(defaults: .standard), bankTexts: self.services.bankTexts,
        reviewOrderDefaults: .standard, amountsDefaults: .standard)
      if BuildSurface.showsCloudSuggestions { app.cloudSort = LiveCloudSortController(runtime: rt) }
      rt.store.onWriteFailed = { [weak app] in app?.writeFailed() }
      app.syncNotices.eraseThisIPhone = { [weak self] in await self?.eraseThisIPhone() }
      app.syncNotices.acknowledge = { [weak rt] in await rt?.engine.acknowledgeAlarms() }
      self.watchSync(rt.engine, notices: app.syncNotices)
      app.refreshWork = { [weak rt] in _ = await rt?.coordinator.run(.refresh, budget: .seconds(20)) }
      self.app = app
      self.widgets = WidgetPublisher(app: app, locked: { [weak app] in app?.store.state.prefs.faceIDLock ?? false })
      let badge = AppIconBadge(app: app)
      self.badge = badge
      rt.onRunCommitted = { [weak badge] in await badge?.publish() }
      self.generation += 1
      self.setupFacts = facts
      rt.onAccount = { [weak self, weak rt] info in
        guard let self, let rt, self.runtime === rt else { return }
        account.noteAccount(info)
        if info.has_keys == true {
          await self.services.unseenPhrase.adopt(serverUnseenSince: LiveAccountService.instant(info.phrase_unseen_since))
        }
        rt.store.profile = Self.profileInfo(account.profile, binding: binding)
        self.session.reviewAccount = rt.reviewAccount
        await rt.store.reload()
      }
      BackgroundScheduler.shared.scheduleAfterOpening(rt.store.mailboxPhase)
      Task { [weak self] in await self?.launch(rt, binding: binding, turn: turn) }
      return rt
    }
  }

  private func launch(_ rt: AccountRuntime, binding: AccountBinding, turn: RuntimeTurns<AccountRuntime>.Turn) async {
    await rt.start(buildNumber: env.buildNumber, stopped: { [weak self] stop in await self?.stopped(stop, turn: turn) })
    guard runtime === rt else { return }
    PushRegistrar.shared.register(env: env.account, userID: binding.user_id)
  }

  private func watchSync(_ engine: SyncEngine, notices: SyncNotices) {
    syncWatch?.cancel()
    syncWatch = Task { [weak notices] in
      for await status in await engine.statusUpdates() {
        notices?.update(status)
      }
    }
  }

  private func left() async {
    await closeRuntime()
    wall = nil
    if session.phase != .signedOut { session.signedOut() }
  }

  func closeRuntime() async {
    SearchHistory.shared.clear()
    WidgetLinkInbox.shared.pending = nil
    widgets?.stop()
    widgets = nil
    WidgetPublisher.clear()
    badge?.stop()
    badge = nil
    AppIconBadge.clear()
    BackgroundScheduler.shared.cancelAll()
    syncWatch?.cancel()
    syncWatch = nil
    syncHalt = nil
    wall = Self.wallAfterClosing(wall)
    setupFacts = OnboardingStep.Facts(hasSession: true, keysReady: true)
    let rt = runtime
    if rt != nil {
      runtime = nil
      app = nil
      session.reviewAccount = false
      PushRegistrar.shared.forget()
    }
    await turns.close(rt) { await $0.close() }
  }

  static func wallAfterClosing(_ wall: Wall?) -> Wall? {
    wall == .updateRequired ? nil : wall
  }

  func tryAgain() {
    switch wall {
    case .openFailed:
      wall = nil
      openRuntimeIfNeeded()
    case .updateRequired:
      wall = nil
      relaunch()
    default:
      break
    }
  }

  private func relaunch() {
    guard let rt = runtime, let binding = try? env.account.secrets.binding() else { return }
    let turn = turns.turn
    Task { await launch(rt, binding: binding, turn: turn) }
  }

  func retrySync() {
    guard syncHalt != nil, !retryingSync, let rt = runtime else { return }
    retryingSync = true
    Task {
      let out = await rt.coordinator.run(.refresh, retestingLatch: true)
      let latch = await rt.engine.status.latch
      retryingSync = false
      guard runtime === rt else { return }
      if Self.clearsSyncHalt(out.stop, latch: latch) { syncHalt = nil }
    }
  }

  static func clearsSyncHalt(_ stop: SyncStop?, latch: OutboxLatch? = nil) -> Bool {
    guard latch != .chainBreak else { return false }
    switch stop {
    case nil, .latched?: return true
    default: return false
    }
  }

  static func syncHalt(for stop: SyncStop) -> HaltKind? {
    guard case .halted(let kind) = stop, kind != .updateRequired else { return nil }
    return kind
  }

  func dismissWall() {
    if case .otherAccount = wall { wall = nil }
  }

  func eraseThisIPhone() async {
    guard !erasing else { return }
    erasing = true
    await closeRuntime()
    await env.eraseLocalData()
    account.forgetAll()
    wall = nil
    erasing = false
    if session.phase != .signedOut { session.signedOut() }
    guard case .notNow = env.installCheck else { return }
    state = .waiting
    start()
  }

  private func stopped(_ stop: SyncStop, turn: RuntimeTurns<AccountRuntime>.Turn) async {
    guard turns.isCurrent(turn) else { return }
    switch stop {
    case .wipe:
      let binding = try? env.account.secrets.binding()
      await closeRuntime()
      if let b = binding, let u = b.userID {
        let build = env.build
        await MailboxLane.endGrantThenWipe(env.account, userID: u, writerID: b.writerID) {
          await MailboxLane.endGrant($0, build: build, stopWatch: false)
        }
      }
      try? env.account.secrets.deleteSession()
      LocalAccountData.forget()
      account.forgetAll()
      session.signedOut()
    case .needsSignIn, .needsRebind:
      await closeRuntime()
      try? env.account.secrets.deleteSession()
      session.signedOut()
    case .frozen:
      let info = await account.freezeInfo()
      guard turns.isCurrent(turn), session.phase != .signedOut else { return }
      session.runFoundFrozen(info)
    case .needsUnlock, .keysRequired:
      await closeRuntime()
      await account.endSessionKeepingData()
      session.signedOut()
    case .halted(.updateRequired):
      wall = .updateRequired
    case .halted:
      guard runtime != nil, let kind = Self.syncHalt(for: stop) else { return }
      syncHalt = kind
    default:
      break
    }
  }

  static func facts(_ rt: AccountRuntime, texts: (any BankTextsConnecting)?) -> OnboardingStep.Facts {
    var f = OnboardingStep.Facts(hasSession: true, keysReady: true)
    f.textsChosen = BankTexts.setUpHere(texts)
    let r = rt.projection.reader
    f.banksChosen = !((try? r.senderTrust()) ?? [:]).isEmpty
    f.sampleLoaded = (try? r.holdsSample()) ?? false
    return f
  }

  static func mailboxFact(_ phase: MailboxPhase) -> OnboardingStep.Facts.Mailbox {
    switch phase {
    case .unlinked: .unlinked
    case .scanning, .awaitingCards: .scanning
    case .otherDevice: .otherDevice
    case .authoringBackfill, .active, .reconnectRequired, .halted: .linked
    }
  }

  static func storeExists(_ env: AccountEnvironment, _ binding: AccountBinding) -> Bool {
    guard let u = binding.userID, let dir = env.storeDirectory(for: u) else { return true }
    return FileManager.default.fileExists(atPath: dir.appendingPathComponent("ledger.sqlite").path)
  }

  static func profileInfo(_ p: AccountProfile?, binding: AccountBinding) -> ProfileInfo {
    ProfileInfo(
      displayName: p?.displayName.isEmpty == false ? p!.displayName : (binding.display_name ?? ""),
      email: p?.email.isEmpty == false ? p!.email : binding.email_norm,
      signIn: p?.method == .password ? .password : .passkey)
  }
}

@MainActor
private final class RuntimeHolder {
  weak var boot: BootController?
}

struct BackgroundEntry<Runtime> {
  var start: () -> Void
  var opened: () async -> Runtime?

  func runtime() async -> Runtime? {
    start()
    return await opened()
  }

  static func task(_ entry: BackgroundEntry?, _ work: (Runtime) async -> Bool) async -> Bool {
    guard let rt = await entry?.runtime() else { return false }
    return await work(rt)
  }
}

extension BackgroundEntry where Runtime == AccountRuntime {
  init(_ boot: BootController) {
    self.init(start: { boot.start() }, opened: { await boot.openedRuntime() })
  }

  static func live() -> BackgroundEntry? { AppGraph.boot.map(BackgroundEntry.init) }
}

@MainActor
enum AppGraph {
  private(set) static var boot: BootController?

  static func live() -> BootController {
    if let boot { return boot }
    let made = BootController(env: .live())
    boot = made
    return made
  }
}
