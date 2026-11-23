import BackgroundTasks
import CoreMailbox
import Foundation
import os

nonisolated final class BackgroundScheduler: Sendable {
  enum Kind: Sendable { case refresh, processing }

  typealias Work = @Sendable (_ kind: Kind, _ deadlineMs: Int64?) async -> Bool

  static let refreshID = "app.hasala.ios.refresh"
  static let processingID = "app.hasala.ios.processing"
  static let refreshInterval: TimeInterval = 15 * 60
  static let refreshBudgetMs: Int64 = 25_000

  static let shared = BackgroundScheduler()

  private let work = OSAllocatedUnfairLock<Work?>(initialState: nil)
  private let log = Logger(subsystem: "app.hasala.ios", category: "background")

  func install(_ w: Work?) { work.withLock { $0 = w } }

  func register() {
    BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshID, using: nil) { task in
      self.handle(task, kind: .refresh)
    }
    BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.processingID, using: nil) { task in
      self.handle(task, kind: .processing)
    }
  }

  func scheduleRefresh() {
    let r = BGAppRefreshTaskRequest(identifier: Self.refreshID)
    r.earliestBeginDate = Date(timeIntervalSinceNow: Self.refreshInterval)
    submit(r)
  }

  func scheduleProcessing() {
    let r = BGProcessingTaskRequest(identifier: Self.processingID)
    r.requiresNetworkConnectivity = true
    r.requiresExternalPower = false
    submit(r)
  }

  static func kinds(afterOpening phase: MailboxPhase?) -> [Kind] {
    phase?.isImporting == true ? [.refresh, .processing] : [.refresh]
  }

  func scheduleAfterOpening(_ phase: MailboxPhase?) {
    for kind in Self.kinds(afterOpening: phase) {
      switch kind {
      case .refresh: scheduleRefresh()
      case .processing: scheduleProcessing()
      }
    }
  }

  func cancelAll() {
    BGTaskScheduler.shared.cancelAllTaskRequests()
  }

  private func submit(_ r: BGTaskRequest) {
    do { try BGTaskScheduler.shared.submit(r) } catch {
      log.info("bg submit refused: \(String(describing: type(of: error)), privacy: .public)")
    }
  }

  private func handle(_ task: BGTask, kind: Kind) {
    if kind == .refresh { scheduleRefresh() }
    guard let w = work.withLock({ $0 }) else {
      task.setTaskCompleted(success: true)
      return
    }
    let deadline: Int64? =
      kind == .refresh ? Int64(Date().timeIntervalSince1970 * 1000) + Self.refreshBudgetMs : nil
    let box = TaskBox(task)
    let job = Task {
      let pending = await w(kind, deadline)
      if pending { self.scheduleProcessing() }
      box.task.setTaskCompleted(success: !Task.isCancelled)
    }
    task.expirationHandler = { job.cancel() }
  }
}

nonisolated private final class TaskBox: @unchecked Sendable {
  let task: BGTask
  init(_ t: BGTask) { task = t }
}
