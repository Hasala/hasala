import CoreMailbox
import CoreSync
import Foundation

actor WorkCoordinator {
  nonisolated enum Trigger: String, Sendable, CaseIterable {
    case launch, foreground, refresh, retryMail, authored, silentPush, bgRefresh, bgProcessing

    var sync: SyncTrigger {
      switch self {
      case .launch: .launch
      case .foreground: .foreground
      case .refresh, .retryMail: .refresh
      case .authored: .authored
      case .silentPush: .silentPush
      case .bgRefresh: .bgRefresh
      case .bgProcessing: .bgProcessing
      }
    }

    var mailbox: MailboxTrigger? {
      switch self {
      case .launch: .launch
      case .foreground: .foreground
      case .refresh: .refresh
      case .retryMail: .retry
      case .authored: nil
      case .silentPush: .silentPush
      case .bgRefresh: .appRefresh
      case .bgProcessing: .processing
      }
    }

    var strength: Int {
      switch self {
      case .authored: 0
      case .retryMail: 2
      default: 1
      }
    }

    var wakes: Bool { self == .silentPush || self == .bgRefresh || self == .bgProcessing }
  }

  nonisolated struct Outcome: Sendable, Equatable {
    var newData = false
    var stop: SyncStop?
    var ran = false
    var timedOut = false
    var mailHalt: MailboxHaltCode?

    static let notRun = Outcome(stop: .notNow)

    var failed: Bool { stop.map { !WorkCoordinator.tolerable($0) } ?? false }

    enum Settled: Sendable, Equatable {
      case updated, notRun, stillRunning, offline, mailStopped, failed
    }

    var settled: Settled {
      if timedOut { return .stillRunning }
      if !ran || stop == .cancelled { return .notRun }
      switch stop {
      case .offline?, .protocolError?: return .offline
      default: break
      }
      if failed { return .failed }
      switch mailHalt {
      case .offline?: return .offline
      case nil, .stagingFull?: return .updated
      default: return .mailStopped
      }
    }

    var announcement: String? {
      switch settled {
      case .updated: "Updated"
      case .offline: "Couldn't check. No connection."
      case .mailStopped: "Bank alerts stopped"
      case .failed: "Couldn't check"
      case .notRun, .stillRunning: nil
      }
    }
  }

  typealias SyncStage = @Sendable (SyncTrigger, ContinuousClock.Instant?) async -> (newData: Bool, stop: SyncStop?)
  typealias MailboxStage = @Sendable (MailboxTrigger, Int64?) async -> CycleReport
  typealias CategorizeStage = @Sendable (Trigger) async -> (newData: Bool, offScreen: Bool)
  typealias CommittedStage = @Sendable () async -> Void
  typealias StoppedStage = @Sendable (SyncStop) async -> Void

  nonisolated struct Stages: Sendable {
    var sync: @Sendable (_ trigger: SyncTrigger, _ deadline: ContinuousClock.Instant?) async -> (newData: Bool, stop: SyncStop?)
    var mailbox: (@Sendable (_ trigger: MailboxTrigger, _ deadlineMs: Int64?) async -> CycleReport)?
    var categorize: CategorizeStage?
    var committed: @Sendable () async -> Void
    var stopped: @Sendable (_ stop: SyncStop) async -> Void

    init(
      sync: @escaping SyncStage, mailbox: MailboxStage?, categorize: CategorizeStage? = nil, committed: @escaping CommittedStage,
      stopped: @escaping StoppedStage
    ) {
      self.sync = sync
      self.mailbox = mailbox
      self.categorize = categorize
      self.committed = committed
      self.stopped = stopped
    }
  }

  private enum RerunLimit {
    case unasked
    case unbounded
    case until(ContinuousClock.Instant)

    func widened(by deadline: ContinuousClock.Instant?) -> RerunLimit {
      guard let deadline else { return .unbounded }
      switch self {
      case .unasked: return .until(deadline)
      case .unbounded: return .unbounded
      case .until(let d): return .until(max(d, deadline))
      }
    }

    var deadline: ContinuousClock.Instant? {
      if case .until(let d) = self { return d }
      return nil
    }
  }

  static let foregroundSpacing: Duration = .seconds(60)

  private let stages: Stages
  private var inFlight: Task<Outcome, Never>?
  private var current: Trigger?
  private var currentSynced = false
  private var rerun: Trigger?
  private var rerunLimit = RerunLimit.unasked
  private var held: Trigger?
  private var waiters: [Int: Task<Outcome, Never>] = [:]
  private var nextWaiter = 0
  private var lastForeground: ContinuousClock.Instant?
  private var closed = false
  private var paused = false
  private var syncing: Task<(newData: Bool, stop: SyncStop?), Never>?
  private var handing: [SyncStop] = []
  private var settling: Task<Void, Never>?
  private(set) var runs = 0
  @TaskLocal private static var insideHandOver = false

  init(stages: Stages) {
    self.stages = stages
  }

  func close() {
    closed = true
    rerun = nil
    held = nil
    inFlight?.cancel()
  }

  func pause() async {
    paused = true
    if let rerun { hold(rerun) }
    rerun = nil
    await finished()
  }

  @discardableResult
  func resume() -> Trigger? {
    paused = false
    defer { held = nil }
    return held
  }

  private func hold(_ trigger: Trigger) {
    if Self.queues(trigger, over: held) { held = trigger }
  }

  func finished() async {
    if let syncing { _ = await syncing.value }
    guard !Self.insideHandOver else { return }
    var settled: Task<Void, Never>?
    while inFlight != nil || settling != settled {
      settled = settling
      await settled?.value
      if let inFlight { _ = await inFlight.value }
    }
  }

  @discardableResult
  func run(_ trigger: Trigger, budget: Duration? = nil, retestingLatch: Bool = false) async -> Outcome {
    guard !closed else { return .notRun }
    if trigger == .foreground, let last = lastForeground, ContinuousClock.now - last < Self.foregroundSpacing { return .notRun }
    guard !paused else {
      hold(trigger)
      return .notRun
    }
    let deadline = budget.map { ContinuousClock.now + $0 }
    let task: Task<Outcome, Never>
    if let t = inFlight {
      let running = retestingLatch && currentSynced ? nil : current
      if !Self.joins(trigger, running: running, queued: rerun, retestingLatch: retestingLatch) {
        if retestingLatch || Self.queues(trigger, over: rerun) { rerun = trigger }
        rerunLimit = rerunLimit.widened(by: deadline)
      }
      task = t
    } else {
      task = Task { await self.loop(trigger, deadline: deadline) }
      inFlight = task
    }
    let id = nextWaiter
    nextWaiter += 1
    waiters[id] = task
    let out = await Self.wait(
      for: task, until: deadline, timedOut: Outcome(newData: false, stop: .notNow, timedOut: true),
      cancelled: Outcome(newData: false, stop: .cancelled))
    let waited = waiters.removeValue(forKey: id)
    if Task.isCancelled, let waited { cancelIfUnwatched(waited) }
    return out
  }

  static func joins(_ trigger: Trigger, running: Trigger?, queued: Trigger?, retestingLatch: Bool = false) -> Bool {
    let runs = [running, queued]
    if retestingLatch { return runs.contains { $0?.sync.retestsALatch == true } }
    return trigger == .refresh && runs.contains { $0?.mailbox != nil }
  }

  static func queues(_ trigger: Trigger, over queued: Trigger?) -> Bool {
    guard let queued else { return true }
    return trigger.strength > queued.strength || trigger == .foreground && queued.wakes
  }

  var queued: Trigger? { rerun }

  private func cancelIfUnwatched(_ task: Task<Outcome, Never>) {
    guard task == inFlight, !waiters.values.contains(task) else { return }
    rerun = nil
    rerunLimit = .unasked
    task.cancel()
  }

  private func loop(_ trigger: Trigger, deadline: ContinuousClock.Instant?) async -> Outcome {
    var out = await once(trigger, deadline: deadline)
    while let next = rerun, !closed, !paused, !Task.isCancelled {
      let limit = rerunLimit
      rerun = nil
      rerunLimit = .unasked
      if out.stop.map(Self.endsTheAccount) == true { break }
      let again = await once(next, deadline: limit.deadline)
      out.newData = out.newData || again.newData
      out.stop = again.stop
      out.mailHalt = again.mailHalt
    }
    rerun = nil
    rerunLimit = .unasked
    inFlight = nil
    current = nil
    return out
  }

  private func once(_ trigger: Trigger, deadline: ContinuousClock.Instant?) async -> Outcome {
    runs += 1
    current = trigger
    currentSynced = false
    let stamp: ContinuousClock.Instant? = trigger == .foreground ? .now : nil
    if let stamp { lastForeground = stamp }
    var out = Outcome(ran: true)
    let sync = stages.sync
    let syncTask = Task { await sync(trigger.sync, deadline) }
    syncing = syncTask
    let synced = await Self.wait(
      for: syncTask, until: nil, timedOut: (newData: false, stop: SyncStop?.some(.cancelled)),
      cancelled: (newData: false, stop: SyncStop?.some(.cancelled)))
    currentSynced = true
    out.newData = synced.newData
    out.stop = synced.stop
    if Task.isCancelled {
      settle(syncTask)
      return Outcome(newData: out.newData, stop: .cancelled)
    }
    if let stop = synced.stop, Self.surfaces(stop) {
      await hand(stop)
      if Self.endsTheAccount(stop) { return out }
    }
    if !closed, let mailbox = stages.mailbox, let mt = trigger.mailbox, synced.stop.map(Self.tolerable) ?? true {
      let deadlineMs = deadline.map { d -> Int64 in
        let left = ContinuousClock.now.duration(to: d)
        let leftMs = left.components.seconds * 1000 + left.components.attoseconds / 1_000_000_000_000_000
        return Int64(Date().timeIntervalSince1970 * 1000) + leftMs
      }
      let report = await mailbox(mt, deadlineMs)
      if report.ops > 0 { out.newData = true }
      out.mailHalt = report.haltedOn
    }
    if Task.isCancelled { return Outcome(newData: out.newData, stop: .cancelled) }
    if !closed, let categorize = stages.categorize, synced.stop.map(Self.tolerable) ?? true {
      let c = await categorize(trigger)
      if c.newData { out.newData = true }
      if c.offScreen, let stamp, lastForeground == stamp { lastForeground = nil }
    }
    if Task.isCancelled { return Outcome(newData: out.newData, stop: .cancelled) }
    await stages.committed()
    return out
  }

  private func settle(_ sync: Task<(newData: Bool, stop: SyncStop?), Never>) {
    let earlier = settling
    settling = Task {
      await earlier?.value
      guard let stop = await sync.value.stop, Self.surfaces(stop), !closed else { return }
      await hand(stop)
    }
  }

  private func hand(_ stop: SyncStop) async {
    guard !handing.contains(stop) else { return }
    handing.append(stop)
    let stopped = stages.stopped
    await Task { await Self.$insideHandOver.withValue(true) { await stopped(stop) } }.value
    handing.removeAll { $0 == stop }
  }

  static func endsTheAccount(_ stop: SyncStop) -> Bool {
    switch stop {
    case .wipe, .needsSignIn, .needsRebind, .frozen, .needsUnlock, .keysRequired: true
    default: false
    }
  }

  static func surfaces(_ stop: SyncStop) -> Bool {
    if case .halted = stop { return true }
    return endsTheAccount(stop)
  }

  static func tolerable(_ stop: SyncStop) -> Bool {
    switch stop {
    case .rateLimited, .latched, .suspended, .notNow, .cancelled: true
    default: false
    }
  }

  nonisolated static func wait<T: Sendable>(
    for task: Task<T, Never>, until deadline: ContinuousClock.Instant?, timedOut: T, cancelled: T
  ) async -> T {
    let first = FirstOf<T>()
    Task { first.finish(await task.value) }
    let timer: Task<Void, Never>? = deadline.map { d in
      Task {
        do {
          try await Task.sleep(until: d, clock: .continuous)
          first.finish(timedOut)
        } catch {}
      }
    }
    defer { timer?.cancel() }
    return await withTaskCancellationHandler {
      await withCheckedContinuation { first.install($0) }
    } onCancel: {
      first.finish(cancelled)
    }
  }
}

nonisolated final class FirstOf<T: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<T, Never>?
  private var result: T?
  private var done = false

  func install(_ k: CheckedContinuation<T, Never>) {
    let ready: T? = lock.withLock {
      if done { return result }
      continuation = k
      return nil
    }
    if let ready { k.resume(returning: ready) }
  }

  @discardableResult
  func finish(_ value: T) -> Bool {
    let k: CheckedContinuation<T, Never>?? = lock.withLock {
      guard !done else { return nil }
      done = true
      result = value
      defer { continuation = nil }
      return .some(continuation)
    }
    guard let k else { return false }
    k?.resume(returning: value)
    return true
  }
}
