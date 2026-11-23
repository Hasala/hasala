import Foundation
import Observation

@MainActor
@Observable
final class SecurityModel {
  enum Confirmation: Equatable, Identifiable {
    case perform(SecurityAction)
    case viewPhrase
    case changeEmail

    var id: String {
      switch self {
      case .perform(let a): "perform.\(a.explainer)"
      case .viewPhrase: "viewPhrase"
      case .changeEmail: "changeEmail"
      }
    }
  }

  enum Host: Equatable { case page, passwordEditor, lockdown }

  private let session: AccountSession
  private var account: AccountService { session.account }

  private(set) var state: SecurityState?
  var busy = false
  var failure: AuthFailure?
  var notice: String?

  private(set) var confirming: Confirmation?
  private(set) var confirmHost: Host = .page
  var confirmPassword = ""
  private(set) var lacksDeviceKey = false

  var editingPassword = false {
    didSet {
      if !editingPassword {
        newPassword = ""
        confirmNewPassword = ""
      }
    }
  }
  var newPassword = ""
  var confirmNewPassword = ""

  var viewedPhrase: [String]?
  var phraseRevealed = false {
    didSet {
      if phraseRevealed, phraseMasked || viewedPhrase == nil { phraseRevealed = false }
      if phraseRevealed { session.services.unseenPhrase.noteSeen() }
    }
  }
  private(set) var phraseFirstView = false
  var phraseMasked = false {
    didSet { if phraseMasked { phraseRevealed = false } }
  }
  var emailChange: EmailChangeTicket?

  private var pendingPhrase: [String]?
  private var pendingEmailChange: EmailChangeTicket?

  init(session: AccountSession) {
    self.session = session
  }

  var isFrozen: Bool { state?.frozen != nil }

  var capabilities: AccountCapabilities { session.capabilities }

  var email: String { state?.email ?? account.profile?.email ?? "" }

  var offersLockdown: Bool {
    capabilities.isSuperset(of: [
      .signOutEverywhere, .removePasskey, .removeDevice, .changePassword, .rotatePhrase, .freeze,
    ])
  }

  var lacksAnAction: Bool {
    !capabilities.isSuperset(of: [
      .changeEmail, .addPasskey, .removePasskey, .changePassword, .removeDevice, .rotatePhrase, .freeze,
    ])
  }

  func load() async {
    do {
      state = try await account.securityState()
      failure = nil
    } catch {
      failure = error
    }
  }

  func keepLoading(firstWait: Duration = .seconds(5)) async {
    var wait = firstWait
    await load()
    while state == nil, failure == .offline || failure == .rateLimited, !Task.isCancelled {
      try? await Task.sleep(for: wait)
      guard !Task.isCancelled else { return }
      wait = min(wait * 2, .seconds(30))
      await load()
    }
  }

  func request(_ action: SecurityAction, host: Host = .page) async {
    guard let state else { return }
    if isFrozen, action != .unfreeze {
      failure = .frozen
      return
    }
    if action == .unfreeze, state.frozen?.by != .holder { return }
    if case .removePasskey = action, session.services.unseenPhrase.unseen {
      notice = nil
      failure = .wordsBeforeRemovingPasskey
      return
    }
    ask(.perform(action), host: host)
  }

  func requestPhrase() {
    guard let state, state.hasPasskey, capabilities.contains(.viewPhrase) else { return }
    if isFrozen {
      failure = .frozen
      return
    }
    ask(.viewPhrase, host: .page)
  }

  func requestEmailChange() {
    guard state != nil, capabilities.contains(.changeEmail) else { return }
    if isFrozen {
      failure = .frozen
      return
    }
    ask(.changeEmail, host: .page)
  }

  private func ask(_ c: Confirmation, host: Host) {
    failure = nil
    notice = nil
    confirmPassword = ""
    lacksDeviceKey = false
    confirmHost = host
    confirming = c
  }

  var confirmFactor: ConfirmRequest.Factor {
    if state?.hasPasskey == true { return .faceID }
    return lacksDeviceKey ? .noKey : .password
  }

  var confirmRequest: ConfirmRequest? {
    guard let confirming else { return nil }
    let (title, bullets) = Self.words(for: confirming, email: email, state: state)
    return ConfirmRequest(title: title, factor: confirmFactor, bullets: bullets,
                          otherDevice: state?.devices.first { !$0.isThisDevice }?.title)
  }

  func confirm() async {
    guard let c = confirming else { return }
    let password = state?.hasPasskey == true ? nil : confirmPassword
    busy = true
    defer { busy = false }
    do throws(AuthFailure) {
      switch c {
      case .perform(let action):
        try await account.perform(action, password: password)
        closeConfirmation()
        await performed(action)
      case .viewPhrase:
        let words = try await account.viewRecoveryPhrase()
        closeConfirmation()
        pendingPhrase = words
      case .changeEmail:
        let ticket = try await account.beginEmailChange(password: password)
        closeConfirmation()
        pendingEmailChange = ticket
      }
    } catch .cancelled {
      confirmPassword = ""
    } catch .stepUpFailed {
      confirmPassword = ""
      failure = .stepUpFailed
    } catch .passkeyCantShowPhrase {
      closeConfirmation()
      failure = session.services.unseenPhrase.unseen ? .passkeyCantShowUnseenPhrase : .passkeyCantShowPhrase
    } catch .noDeviceKey {
      confirmPassword = ""
      failure = nil
      lacksDeviceKey = true
    } catch .frozenByOperator {
      closeConfirmation()
      session.learnedOperatorFreeze()
      await load()
      failure = .frozenByOperator
    } catch .frozen {
      closeConfirmation()
      await load()
      failure = .frozen
    } catch .sessionEnded {
      closeConfirmation()
      session.signedOut()
    } catch {
      closeConfirmation()
      failure = error
    }
  }

  func cancelConfirmation() {
    guard !busy else { return }
    closeConfirmation()
    failure = nil
  }

  private func closeConfirmation() {
    confirming = nil
    confirmPassword = ""
    lacksDeviceKey = false
  }

  func confirmationDismissed() {
    if let words = pendingPhrase {
      pendingPhrase = nil
      phraseRevealed = false
      phraseFirstView = session.services.unseenPhrase.unseen
      viewedPhrase = words
    }
    if let ticket = pendingEmailChange {
      pendingEmailChange = nil
      emailChange = ticket
    }
  }

  private func performed(_ action: SecurityAction) async {
    failure = nil
    notice = Self.notice(for: action)
    switch action {
    case .freeze:
      session.froze(FreezeInfo(by: .holder, when: "just now", inApp: true))
    case .deleteAccount, .signOutEverywhere:
      session.signedOut()
      return
    case .removeThisIPhoneLosingUnsent:
      session.signedOut()
      return
    case .unfreeze:
      session.unfroze()
    case .setPassword, .changePassword:
      editingPassword = false
    default:
      break
    }
    await load()
  }

  static func notice(for action: SecurityAction) -> String? {
    switch action {
    case .removePasskey: "Removed from your account. Delete it in the Passwords app too."
    case .addPasskey: "Passkey added."
    case .setPassword: "Password set. It never unlocks your data."
    case .changePassword: "Password changed. Other devices were signed out."
    case .removePassword: "Password removed."
    case .removeDevice: "Device removed."
    default: nil
    }
  }

  static func words(for c: Confirmation, email: String, state: SecurityState?) -> (String, [String]) {
    let weEmail = email.isEmpty ? "We email you about it" : "We email \(email) about it"
    switch c {
    case .viewPhrase:
      return ("Show your 12 words", ["Shown on this screen only", "They hide again when you leave"])
    case .changeEmail:
      return ("Change your email", ["A code goes to both addresses next", "Nothing changes until both match"])
    case .perform(let action):
      switch action {
      case .addPasskey:
        return ("Add a passkey", ["iOS asks where to save it next", weEmail])
      case .removePasskey(let id):
        guard let name = state?.passkeys.first(where: { $0.id == id })?.provider else {
          return ("Remove this passkey", ["This passkey can't sign in any more", weEmail])
        }
        return ("Remove the \(name) passkey", ["The \(name) passkey can't sign in any more", weEmail])
      case .setPassword:
        return ("Set a password", ["Signs you in, never unlocks your data", weEmail])
      case .changePassword:
        return ("Change your password", ["Other devices are signed out", weEmail])
      case .removePassword:
        return ("Remove your password", ["You'll sign in with your passkey only", weEmail])
      case .removeDevice(let id):
        let name = state?.devices.first { $0.id == id }?.title ?? "this device"
        return ("Remove \(name)", ["It's signed out now", "Its copy of your data is erased when it next opens Hasala"])
      case .removeThisIPhoneLosingUnsent:
        return ("Remove this iPhone", ["Changes that can't upload are lost for good", "Everything you uploaded stays in your account"])
      case .signOutEverywhere:
        return ("Sign out everywhere", ["Every device signs out, this one too", "Your sealed backup stays"])
      case .freeze:
        return ("Freeze your account", ["Everyone is signed out", "Sign-in and key changes stop until unfrozen"])
      case .unfreeze:
        return ("Unfreeze your account", ["Sign-in and key changes work again"])
      case .deleteAccount:
        return ("Delete your account", ["Everything is erased, here and on our server",
                                        email.isEmpty ? "We email you to confirm" : "We email \(email) to confirm"])
      }
    }
  }

  var newPasswordAssessment: PasswordAssessment {
    PasswordRules.assess(newPassword, personal: [state?.email ?? "", session.account.profile?.displayName ?? ""])
  }

  var newPasswordsMatch: Bool { !confirmNewPassword.isEmpty && newPassword == confirmNewPassword }

  var newPasswordReady: Bool { newPasswordAssessment.acceptable && newPasswordsMatch }

  func savePassword() async {
    guard newPasswordReady, let state else { return }
    let pw = newPassword
    await request(state.hasPassword ? .changePassword(new: pw) : .setPassword(new: pw), host: .passwordEditor)
  }

  func closePhrase() {
    phraseRevealed = false
    viewedPhrase = nil
  }

  func finishEmailChange(to newEmail: String?) async {
    emailChange = nil
    if let newEmail {
      notice = "Email changed. Sign-in codes and security emails now go to\n\(newEmail)"
      await load()
    }
  }

  var accountForEmailChange: AccountService { account }

  func signOut() async {
    await session.signOut()
  }

  func enterWordsToUnlock() {
    closeConfirmation()
    session.signedIn(.needsUnlock(passkeyCanUnlock: false))
  }
}
