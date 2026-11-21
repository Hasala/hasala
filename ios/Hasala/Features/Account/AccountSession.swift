import Foundation
import Observation

@MainActor
@Observable
final class AccountSession {
  enum Phase: Equatable {
    case signedOut
    case checking
    case onboarding
    case needsUnlock(passkeyCanUnlock: Bool)
    case needsKeys
    case frozen(FreezeInfo)
    case ready
  }

  let services: AccountServices
  private(set) var phase: Phase {
    didSet { if phase != oldValue { onPhaseChange?(phase) } }
  }
  @ObservationIgnored var onPhaseChange: (@MainActor (Phase) -> Void)?
  @ObservationIgnored var onUnfroze: (@MainActor () -> Void)?
  private(set) var leftFrozen: FreezeInfo?
  private var setupBehindWall = false
  private var behindWall: Phase { setupBehindWall ? .onboarding : .ready }
  var pendingInvite: InviteLink?
  var notice: String?
  static let hasAccountNotice = "You already have an account"
  var reviewAccount = false

  init(services: AccountServices, phase: Phase) {
    self.services = services
    self.phase = phase
  }

  var account: AccountService { services.account }

  var capabilities: AccountCapabilities { account.capabilities }

  func signedIn(_ outcome: SignInOutcome) {
    switch outcome {
    case .ready: phase = .ready
    case .needsUnlock(let p): phase = .needsUnlock(passkeyCanUnlock: p)
    case .needsKeys: phase = .needsKeys
    case .frozen(let info): phase = .frozen(info)
    }
  }

  private(set) var resumeFailure: AuthFailure?

  private(set) var resuming = false

  func resume() async {
    guard phase == .checking, !resuming else { return }
    resuming = true
    defer { resuming = false }
    do {
      let outcome = try await account.resumeSignedIn()
      guard phase == .checking else { return }
      resumeFailure = nil
      signedIn(outcome)
    } catch .offline, .rateLimited {
      guard phase == .checking else { return }
      resumeFailure = .offline
    } catch {
      guard phase == .checking else { return }
      resumeFailure = nil
      await account.signOut()
      signedOut()
    }
  }

  func accountCreated() {
    switch phase {
    case .signedOut, .needsKeys: phase = .onboarding
    default: break
    }
  }

  func unlocked() {
    guard case .needsUnlock = phase else { return }
    phase = .ready
  }

  func setupFinished() {
    switch phase {
    case .onboarding:
      setupBehindWall = false
      phase = .ready
    case .frozen: setupBehindWall = false
    default: break
    }
  }

  func froze(_ info: FreezeInfo) {
    if case .onboarding = phase { setupBehindWall = true }
    leftFrozen = nil
    phase = .frozen(info)
  }

  func runFoundFrozen(_ info: FreezeInfo?) {
    if let left = leftFrozen {
      leftFrozen = info ?? left
      return
    }
    var known: FreezeInfo?
    if case .frozen(let shown) = phase { known = shown }
    froze(info ?? known ?? FreezeInfo(by: .holder, when: nil))
  }

  var canLeaveFrozen: Bool { account.keysOnThisIPhone }

  var deleteWaitsForUnfreeze: Bool { leftFrozen != nil }

  func leaveFrozen() {
    guard canLeaveFrozen, case .frozen(let info) = phase else { return }
    leftFrozen = info
    phase = behindWall
  }

  func showFrozenWall() {
    guard let info = leftFrozen else { return }
    froze(info)
  }

  func unfroze() {
    switch phase {
    case .frozen: phase = behindWall
    case .onboarding, .ready: break
    default: return
    }
    leftFrozen = nil
    onUnfroze?()
  }

  func learnedOperatorFreeze() {
    if case .frozen(let info) = phase {
      phase = .frozen(FreezeInfo(by: .operator, when: info.when))
    } else if let info = leftFrozen {
      leftFrozen = FreezeInfo(by: .operator, when: info.when)
    }
  }

  func unfreeze(password: String?) async throws(AuthFailure) {
    do {
      try await account.perform(.unfreeze, password: password)
    } catch .frozenByOperator {
      learnedOperatorFreeze()
      throw .frozenByOperator
    } catch .sessionEnded {
      signedOut()
      throw .sessionEnded
    }
    guard account.keysOnThisIPhone else {
      guard case .frozen = phase else { return }
      leftFrozen = nil
      setupBehindWall = false
      phase = .checking
      await resume()
      return
    }
    unfroze()
  }

  func signOut() async {
    await account.signOut()
    signedOut()
  }

  func signedOut() {
    if phase != .signedOut { account.sessionEnded() }
    leftFrozen = nil
    setupBehindWall = false
    reviewAccount = false
    phase = .signedOut
  }

  func open(_ url: URL) {
    guard let link = InviteLink.parse(url) else { return }
    if phase == .signedOut {
      pendingInvite = link
    } else {
      notice = Self.hasAccountNotice
    }
  }
}

@MainActor
struct AccountServices {
  var account: AccountService
  var mailbox: MailboxConnecting
  var setup: SetupAuthoring
  var notifications: NotificationPermissionAsking
  var hasPasscode: @MainActor () -> Bool = { DevicePasscode.isSet() }
  var cloudSort: CloudSortOffering?
  var unseenPhrase: any UnseenPhraseNoting = InMemoryUnseenPhrase()
  var manualEntry = ManualEntryChoice()
  var finishRows = FinishSetupRows()
  var bankTexts: (any BankTextsConnecting)?
}
