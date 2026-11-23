import Foundation
import Observation

@MainActor
@Observable
final class OnboardingStore {
  let services: AccountServices
  let session: () -> AccountSession
  private(set) var signup: SignupModel
  private(set) var signIn: SignInModel
  var storyPage = 0
  @ObservationIgnored private(set) var setup: SetupModel?
  @ObservationIgnored private(set) var replacement: SignupModel?
  @ObservationIgnored private(set) var unlock: UnlockModel?
  @ObservationIgnored private var finish: FinishSetupModel?
  @ObservationIgnored private var firstScan = FirstScanRun()
  @ObservationIgnored private var reconciledFacts: OnboardingStep.Facts?
  @ObservationIgnored private var lastPhase: AccountSession.Phase?

  init(services: AccountServices, session: @escaping () -> AccountSession) {
    self.services = services
    self.session = session
    signup = Self.signupModel(services, session)
    signIn = Self.signInModel(services.account, session)
  }

  private static func signupModel(_ services: AccountServices, _ session: @escaping () -> AccountSession) -> SignupModel {
    SignupModel(account: services.account, unseenPhrase: services.unseenPhrase) { session().accountCreated() }
  }

  private static func signInModel(_ account: AccountService, _ session: @escaping () -> AccountSession) -> SignInModel {
    SignInModel(account: account) { outcome in session().signedIn(outcome) }
  }

  func setupModel(displayName: String, facts: OnboardingStep.Facts) -> SetupModel {
    if let setup {
      if !displayName.isEmpty, setup.displayName != displayName { setup.displayName = displayName }
      if reconciledFacts != facts { reconcile(setup, facts) }
      return setup
    }
    let session = self.session
    let made = SetupModel(services: services, displayName: displayName, facts: facts, firstScan: firstScan) {
      session().setupFinished()
    }
    setup = made
    reconcile(made, facts)
    return made
  }

  private func reconcile(_ model: SetupModel, _ facts: OnboardingStep.Facts) {
    reconciledFacts = facts
    model.reconcile(facts: facts, banks: services.mailbox.chosenBanks())
  }

  func finishSetupModel() -> FinishSetupModel {
    if let finish { return finish }
    let made = FinishSetupModel(services: services, firstScan: firstScan, session: session)
    finish = made
    return made
  }

  func consumeInvite() {
    let session = self.session()
    guard let link = session.pendingInvite else { return }
    session.pendingInvite = nil
    guard signup.profile == nil, signIn.recovered == nil, !signIn.finishingRecovery else {
      session.notice = AccountSession.hasAccountNotice
      return
    }
    signup.applyInviteLink(link)
    signup.path = [.inviteReady]
  }

  func replacementModel() -> SignupModel {
    if let replacement { return replacement }
    let made = SignupModel(account: services.account, unseenPhrase: services.unseenPhrase)
    made.startReplacement()
    replacement = made
    return made
  }

  func unlockModel(passkeyCanUnlock: Bool) -> UnlockModel {
    let offered = passkeyCanUnlock && services.account.capabilities.contains(.signInPasskey)
    if let unlock, unlock.passkeyCanUnlock == offered { return unlock }
    let session = self.session
    let made = UnlockModel(account: services.account, passkeyCanUnlock: offered) { session().unlocked() }
    unlock = made
    return made
  }

  func phaseChanged(from old: AccountSession.Phase?, to new: AccountSession.Phase) {
    let previous = old ?? lastPhase
    lastPhase = new
    if case .needsUnlock = new {} else { unlock = nil }
    if new == .signedOut, let previous, previous != .signedOut { forgetAccountDrafts() }
    if new != .signedOut, new != .checking { signIn.forgetRecovery() }
  }

  func forgetAccountDrafts() {
    signIn.forgetRecovery()
    setup = nil
    finish = nil
    firstScan = FirstScanRun()
    reconciledFacts = nil
    replacement = nil
    signup = Self.signupModel(services, session)
    signIn = Self.signInModel(services.account, session)
  }
}

@MainActor
final class FirstScanRun {
  private(set) var running = false
  private var generation = 0

  func start(_ mailbox: MailboxConnecting, again: Bool = false) {
    guard again || !running else { return }
    running = true
    generation += 1
    let id = generation
    let stream = mailbox.firstScan()
    Task { [weak self] in
      for await _ in stream {}
      if self?.generation == id { self?.running = false }
    }
  }
}
