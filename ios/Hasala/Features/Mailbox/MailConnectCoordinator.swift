import HasalaModels
import Observation
import UIKit

@MainActor
@Observable
final class MailConnectCoordinator {
  enum Context: Equatable {
    case setup(stepOf: (Int, Int)?)
    case addMailbox
    case signInAgain(mailboxID: String)

    static func == (a: Context, b: Context) -> Bool {
      switch (a, b) {
      case (.setup(let x), .setup(let y)): x?.0 == y?.0 && x?.1 == y?.1
      case (.addMailbox, .addMailbox): true
      case (.signInAgain(let x), .signInAgain(let y)): x == y
      default: false
      }
    }
  }

  enum Outcome: Equatable {
    case connected(mailboxID: String)
    case failed(MailConnectFailure)
  }

  let context: Context
  @ObservationIgnored let mailbox: MailboxConnecting
  private(set) var busy = false
  private(set) var outcome: Outcome?
  private(set) var provider: MailProviderKind?
  private(set) var replacing = false
  private(set) var removingOld = false
  private(set) var linked: MailLinked?
  private(set) var question: MailSwitchQuestion?
  var pastMail: MailPastChoice?
  @ObservationIgnored private var answering: CheckedContinuation<MailSwitchChoice, Never>?
  @ObservationIgnored private(set) var presenters = 0
  @ObservationIgnored private var resigning: NSObjectProtocol?

  var nowReading: String? { linked?.nowReading }

  var pastMailChoice: MailPastChoice { pastMail ?? mailbox.defaultPastMail }

  init(mailbox: MailboxConnecting, context: Context) {
    self.mailbox = mailbox
    self.context = context
    resigning = NotificationCenter.default.addObserver(
      forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.leftForeground() }
    }
  }

  isolated deinit {
    if let resigning { NotificationCenter.default.removeObserver(resigning) }
  }

  func attachPresenter() {
    presenters += 1
  }

  func detachPresenter() {
    presenters = max(0, presenters - 1)
    if presenters == 0 { answer(.cancel) }
  }

  func leftForeground() {
    if question != nil { answer(.cancel) }
  }

  func connect(_ provider: MailProviderKind, replacing: Bool = false, removingOld: Bool = false) async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    outcome = nil
    linked = nil
    self.provider = provider
    self.replacing = replacing
    self.removingOld = replacing && removingOld
    let ask: MailSwitchAsk = { [weak self] question in await self?.ask(question) ?? .cancel }
    do {
      if case .signInAgain(let id) = context {
        let made = try await mailbox.signInAgain(id, ask: ask)
        linked = made
        outcome = .connected(mailboxID: id)
      } else {
        let made = try await mailbox.connect(
          provider, replacing: replacing, removingOld: self.removingOld, pastMail: pastMailChoice, ask: ask)
        linked = made
        outcome = .connected(mailboxID: made.mailboxID)
      }
    } catch .cancelled where provider == .gmail {
      outcome = nil
    } catch .switchDeclined {
      outcome = nil
    } catch {
      outcome = .failed(error)
    }
  }

  func retry(_ provider: MailProviderKind) async {
    let same = self.provider == provider
    await connect(provider, replacing: same && replacing, removingOld: same && removingOld)
  }

  func ask(_ question: MailSwitchQuestion) async -> MailSwitchChoice {
    answer(.cancel)
    guard presenters > 0, UIApplication.shared.applicationState != .background else { return .cancel }
    return await withCheckedContinuation { continuation in
      answering = continuation
      self.question = question
    }
  }

  func answer(_ choice: MailSwitchChoice) {
    question = nil
    let waiting = answering
    answering = nil
    waiting?.resume(returning: choice)
  }

  private static var pendingHand: MailConnectCoordinator?

  static func hand(_ coordinator: MailConnectCoordinator, to router: AppRouter) {
    guard router.sheet == .profile, let provider = coordinator.provider else { return }
    pendingHand = coordinator
    router.profile.append(.connectMail(provider))
  }

  static func handed(_ provider: MailProviderKind) -> MailConnectCoordinator? {
    guard let c = pendingHand, c.provider == provider else { return nil }
    pendingHand = nil
    return c
  }

  static func release() {
    pendingHand = nil
  }

  var failedWithNoMailbox: Bool {
    if case .failed(.noMailbox)? = outcome { return true }
    return false
  }

  func replaced(by provider: MailProviderKind) -> MailboxSnapshot? {
    if case .signInAgain = context { return nil }
    return mailbox.replaced(by: provider)
  }

  var takesOver: MailProviderKind? {
    if case .signInAgain = context { return nil }
    return mailbox.heldElsewhere
  }

  func asksPastMail(_ provider: MailProviderKind) -> Bool {
    if case .signInAgain = context { return false }
    if mailbox.heldElsewhere != nil { return false }
    return !mailbox.mailboxes.contains {
      $0.provider == provider && ($0.state == .needsSignIn || (mailbox.holdsOneLink && $0.state != .disconnected))
    }
  }

  func reset() {
    outcome = nil
    linked = nil
  }

  var signedInAgainLine: String? {
    guard case .connected? = outcome, let provider else { return nil }
    return MailCopy.signedInAgain(provider, nowReading: nowReading, removal: linked?.removal)
  }

  func takeRemovalFailure() -> String? {
    guard case .failed? = linked?.removal, let line = addedLine else { return nil }
    linked?.removal = nil
    return line
  }

  var addedLine: String? {
    guard case .connected? = outcome, let provider else { return nil }
    if let address = nowReading { return MailCopy.signedInAgain(provider, nowReading: address, removal: linked?.removal) }
    return MailCopy.added(provider, removal: linked?.removal)
  }

  func connectedMailbox(_ provider: MailProviderKind) -> MailboxSnapshot? {
    let live = mailbox.mailboxes.filter { $0.state != .disconnected }
    switch outcome {
    case .connected(let id)?:
      guard self.provider == nil || self.provider == provider else { return nil }
      if let m = live.first(where: { $0.id == id }) { return m.provider == provider ? m : nil }
      return MailboxSnapshot(id: id, provider: provider, address: provider.appName, state: .syncing, meta: "Checking now")
    case .failed?:
      return nil
    case nil:
      guard case .setup = context else { return nil }
      return live.first { $0.provider == provider }
    }
  }

  var errorScreen: MailConnectFailure? {
    guard case .failed(let failure)? = outcome, Self.hasScreen(failure, provider: provider ?? .gmail) else {
      return nil
    }
    return failure
  }

  var inlineMessage: String? {
    guard case .failed(let failure)? = outcome, let provider, !Self.hasScreen(failure, provider: provider) else {
      return nil
    }
    return failure.message(for: provider)
  }

  static func hasScreen(_ failure: MailConnectFailure, provider: MailProviderKind) -> Bool {
    failure.hasScreen && !(failure == .cancelled && provider == .gmail)
  }
}
