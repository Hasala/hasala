import Foundation
import Observation

@MainActor
@Observable
final class SignInModel {
  private let account: AccountService
  private let onOutcome: (SignInOutcome) -> Void

  var email = ""
  var password = ""
  var busy = false
  private(set) var signingIn: SignInMethod?
  var failure: AuthFailure?
  private(set) var failureOn: WelcomeRoute?
  private(set) var lastTried: SignInMethod?

  var resetEmail = ""
  var resetCodeText = ""
  private(set) var reset: ResetTicket?
  private(set) var resetCodeSentAt: Date?
  private(set) var resetCodeUsedUp = false
  var newPassword = ""
  var confirmPassword = ""
  private(set) var approvalDeadline: Date?
  private(set) var resetApproved = false

  var phraseText = ""
  private(set) var recovery: RecoveryTicket?
  private(set) var recoverCodeSentAt: Date?
  private(set) var recoverCodeUsedUp = false
  var recoverCode = ""
  private(set) var verifiedRecoveryKind: SignInMethod?
  private(set) var recovered: SignInMethod?
  private(set) var finishingRecovery = false
  var pastedPhraseChangeCount: Int?
  var clearPasteboard: @MainActor (Int?) -> Void = { clearPastedPhrase(changeCount: $0) }

  static let approvalWindow: TimeInterval = 600

  init(account: AccountService, onOutcome: @escaping (SignInOutcome) -> Void) {
    self.account = account
    self.onOutcome = onOutcome
  }

  var capabilities: AccountCapabilities { account.capabilities }

  func failure(on route: WelcomeRoute) -> AuthFailure? {
    failureOn == route ? failure : nil
  }

  private func fail(_ f: AuthFailure, on route: WelcomeRoute) {
    failure = f
    failureOn = route
    guard f == .codeExpired else { return }
    if route == .forgotCode { resetCodeUsedUp = true }
    if route == .recoverCode { recoverCodeUsedUp = true }
  }

  private func clearFailure() {
    failure = nil
    failureOn = nil
  }

  func signInWithPasskey() async {
    guard !busy else { return }
    busy = true
    signingIn = .passkey
    lastTried = .passkey
    defer {
      busy = false
      signingIn = nil
    }
    do {
      let outcome = try await account.signInWithPasskey()
      clearFailure()
      onOutcome(outcome)
    } catch {
      fail(error, on: .signIn)
    }
  }

  var passwordSignInReady: Bool { AccountFields.email(email) != nil && !password.isEmpty }

  func signInWithPassword() async {
    guard passwordSignInReady, !busy else { return }
    busy = true
    signingIn = .password
    lastTried = .password
    defer {
      busy = false
      signingIn = nil
    }
    do {
      let outcome = try await account.signInWithPassword(email: email, password: password)
      password = ""
      clearFailure()
      onOutcome(outcome)
    } catch {
      fail(error, on: .signIn)
      password = ""
    }
  }

  func passwordEdited() {
    guard !password.isEmpty else { return }
    if failureOn == .signIn, lastTried == .password, failure == .wrongCredentials { clearFailure() }
  }

  func startReset() {
    resetEmail = email
    resetCodeText = ""
    reset = nil
    resetCodeUsedUp = false
    resetApproved = false
    clearFailure()
  }

  func submitResetEmail() async -> Bool {
    busy = true
    defer { busy = false }
    do {
      reset = try await account.beginPasswordReset(email: resetEmail)
      resetCodeSentAt = .now
      resetCodeUsedUp = false
      resetCodeText = ""
      clearFailure()
      return true
    } catch {
      fail(error, on: reset == nil ? .forgotEmail : .forgotCode)
      return false
    }
  }

  func submitResetCode() async -> Bool {
    guard let reset, resetCodeText.count == 6 else { return false }
    busy = true
    defer { busy = false }
    do {
      self.reset = try await account.verifyPasswordReset(reset, code: resetCodeText)
      clearFailure()
      return true
    } catch {
      fail(error, on: .forgotCode)
      return false
    }
  }

  func resetCodeExpired(now: Date) -> Bool {
    guard let resetCodeSentAt else { return false }
    return resetCodeUsedUp || EmailCode.expired(sentAt: resetCodeSentAt, now: now)
  }

  func resetCodeEdited() {
    if failureOn == .forgotCode, case .codeWrong = failure { clearFailure() }
  }

  var canApproveOnOtherPhone: Bool { reset?.approvers ?? false }

  var newPasswordAssessment: PasswordAssessment {
    PasswordRules.assess(newPassword, personal: [resetEmail])
  }

  var newPasswordReady: Bool {
    newPasswordAssessment.acceptable && !confirmPassword.isEmpty && confirmPassword == newPassword
  }

  func requestApproval() async -> Bool {
    guard let reset, newPasswordReady else { return false }
    busy = true
    defer { busy = false }
    do {
      self.reset = try await account.requestResetApproval(reset, newPassword: newPassword)
      newPassword = ""
      confirmPassword = ""
      approvalDeadline = .now.addingTimeInterval(Self.approvalWindow)
      clearFailure()
      return true
    } catch {
      fail(error, on: .forgotNewPassword)
      return false
    }
  }

  var resetCodeGroups: String {
    guard let c = reset?.resetCode else { return "" }
    var out = ""
    for (i, ch) in c.enumerated() {
      if i > 0, i % 4 == 0 { out.append(" ") }
      out.append(ch)
    }
    return out
  }

  func waitForApproval(interval: Duration = .seconds(3), limit: Duration = .seconds(600)) async {
    guard let reset else { return }
    let start = ContinuousClock.now
    while !Task.isCancelled {
      do {
        if try await account.pollResetApproval(reset) {
          clearFailure()
          resetApproved = true
          onOutcome(.needsUnlock(passkeyCanUnlock: false))
          return
        }
      } catch {
        fail(error, on: .forgotWaiting)
        return
      }
      if ContinuousClock.now - start > limit {
        fail(.approvalExpired, on: .forgotWaiting)
        return
      }
      try? await Task.sleep(for: interval)
    }
  }

  func submitRecoveryWords(on route: WelcomeRoute = .recoverWords) async -> Bool {
    switch PhraseRules.validate(phraseText) {
    case .failure(let f):
      fail(f, on: route)
      return false
    case .success(let words):
      busy = true
      defer { busy = false }
      do {
        recovery = try await account.beginRecovery(words: words)
        recoverCodeSentAt = .now
        recoverCodeUsedUp = false
        recoverCode = ""
        verifiedRecoveryKind = nil
        clearFailure()
        return true
      } catch {
        fail(error, on: route)
        return false
      }
    }
  }

  func recoverCodeExpired(now: Date) -> Bool {
    guard verifiedRecoveryKind == nil, let recoverCodeSentAt else { return false }
    return recoverCodeUsedUp || EmailCode.expired(sentAt: recoverCodeSentAt, now: now)
  }

  func resendRecoveryCode() async -> Bool {
    await submitRecoveryWords(on: .recoverCode)
  }

  func forgetRecovery() {
    clearPasteboard(pastedPhraseChangeCount)
    pastedPhraseChangeCount = nil
    phraseText = ""
    recoverCode = ""
    recovery = nil
    recoverCodeSentAt = nil
    recoverCodeUsedUp = false
    verifiedRecoveryKind = nil
  }

  func submitRecoveryCode() async -> Bool {
    guard let recovery, recoverCode.count == 6, recoverCode.allSatisfy(\.isASCII), recoverCode.allSatisfy(\.isNumber)
    else { return false }
    clearFailure()
    guard !capabilities.contains(.recoverWithPassword), verifiedRecoveryKind == nil else { return true }
    busy = true
    defer { busy = false }
    do {
      try await account.verifyRecovery(recovery, code: recoverCode, kind: .passkey)
      verifiedRecoveryKind = .passkey
      return true
    } catch {
      switch error {
      case .codeWrong, .codeExpired: recoverCode = ""
      default: break
      }
      fail(error, on: .recoverCode)
      return false
    }
  }

  enum RecoveryResult: Equatable {
    case done
    case codeRejected
    case startAgain
    case failed
  }

  func finishRecovery(_ credential: NewCredential) async -> RecoveryResult {
    guard let recovery else { return .failed }
    let screen: WelcomeRoute = credential.method == .passkey ? .recoverMethod : .recoverPassword
    busy = true
    finishingRecovery = true
    defer {
      busy = false
      finishingRecovery = false
    }
    if let kind = verifiedRecoveryKind, kind != credential.method {
      fail(.badPhrase("This recovery is for a \(kind == .passkey ? "passkey" : "password"). To switch, go back to your words."),
           on: screen)
      return .failed
    }
    if verifiedRecoveryKind == nil {
      do {
        try await account.verifyRecovery(recovery, code: recoverCode, kind: credential.method)
        verifiedRecoveryKind = credential.method
      } catch {
        switch error {
        case .codeWrong, .codeExpired:
          recoverCode = ""
          fail(error, on: .recoverCode)
          return .codeRejected
        default:
          fail(error, on: screen)
          return .failed
        }
      }
    }
    do {
      try await account.finishRecovery(recovery, credential: credential)
      phraseText = ""
      recoverCode = ""
      newPassword = ""
      confirmPassword = ""
      clearFailure()
      recovered = credential.method
      return .done
    } catch .cancelled {
      fail(.cancelled, on: screen)
      return .failed
    } catch .notInThisBuild {
      fail(.notInThisBuild, on: screen)
      return .failed
    } catch {
      if account.recoveryCanContinue(recovery) {
        fail(error, on: screen)
        return .failed
      }
      self.recovery = nil
      recoverCodeSentAt = nil
      recoverCodeUsedUp = false
      recoverCode = ""
      verifiedRecoveryKind = nil
      fail(error, on: .recoverWords)
      return .startAgain
    }
  }

  var greetingName: String { account.profile?.greetingName ?? "" }
  var accountEmail: String { account.profile?.email ?? "" }

  func recoveryDone() {
    onOutcome(.ready)
  }
}
