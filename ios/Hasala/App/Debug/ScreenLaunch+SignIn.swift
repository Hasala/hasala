#if HASALA_MOCKS
  import CoreStore
  import CoreSync
  import Foundation
  import SwiftUI

  enum SignInLaunchStep: Equatable {
    case unlockEntry, unlockUnlocking, unlockWelcomeBack, unlockHonestEnd
    case alertRemovePasskey, alertRemoveDevice, alertRemoveThisIPhone, alertSignOut, alertSignOutAll
    case viewWords, lockdown, changeEmail, changeEmailCodes
    case confirmFaceID, confirmPassword, confirmNoKey
    case unfreeze
    case emailNewAddress, emailCodes
  }

  extension ScreenLaunch {
    static let signInScreens: [Screen] = [
      Screen("signin", scenario: "signInPassword", prepare: { $0.onboarding.signup.path = [.signIn] }),
      Screen("signin.wrongPassword", scenario: "signInPassword") { graph in
        graph.onboarding.signup.path = [.signIn]
        let signIn = graph.onboarding.signIn
        signIn.email = "maya@example.com"
        signIn.password = "not my password"
        await signIn.signInWithPassword()
      },
      Screen("unlock.words", scenario: "unlockPasswordOnly"),
      Screen("unlock.options", scenario: "unlockWithPasskey"),
      Screen("unlock.entry", scenario: "unlockPasswordOnly", prepare: step(.unlockEntry)),
      Screen("unlock.unlocking", scenario: "unlockPasswordOnly", prepare: step(.unlockUnlocking)),
      Screen("unlock.welcomeBack", scenario: "unlockPasswordOnly", prepare: step(.unlockWelcomeBack)),
      Screen("unlock.honestEnd", scenario: "unlockPasswordOnly", prepare: step(.unlockHonestEnd)),
      Screen("forgot.email", scenario: "signInPassword", prepare: { graph in
        graph.onboarding.signIn.email = MockAccountService.existingEmail
        graph.onboarding.signIn.startReset()
        graph.onboarding.signup.path = [.signIn, .forgotEmail]
      }),
      Screen("forgot.code", scenario: "signInPassword") { await forgot($0, to: .forgotCode) },
      Screen("forgot.check", scenario: "signInPassword") { await forgot($0, to: .forgotCheck) },
      Screen("forgot.newPassword", scenario: "signInPassword") { await forgot($0, to: .forgotNewPassword) },
      Screen("forgot.waiting", scenario: "signInPassword") { graph in
        await forgot(graph, to: .forgotWaiting)
        mock(graph)?.delay = .seconds(3600)
      },
      Screen("forgot.locked", scenario: "signInPassword") { graph in
        await forgot(graph, to: .forgotWaiting)
        await graph.onboarding.signIn.waitForApproval(interval: .milliseconds(10), limit: .seconds(5))
      },
      Screen("approval.sheet", scenario: "resetApproval"),
      Screen("recover.intro", scenario: "signInPassword",
             prepare: { $0.onboarding.signup.path = [.signIn, .recoverIntro] }),
      Screen("recover.words", scenario: "signInPassword") { graph in
        graph.onboarding.signup.path = [.signIn, .recoverIntro, .recoverWords]
        graph.onboarding.signIn.phraseText = MockAccountService.phraseWords.prefix(6).joined(separator: " ") + " cat"
      },
      Screen("recover.code", scenario: "signInPassword") { await recover($0, to: .recoverCode) },
      Screen("recover.method", scenario: "signInPassword") { await recover($0, to: .recoverMethod) },
      Screen("recover.backIn", scenario: "signInPassword") { graph in
        await recover(graph, to: .recoverMethod)
        _ = await graph.onboarding.signIn.finishRecovery(.passkey)
      },
      Screen("recover.honestEnd", scenario: "signInPassword",
             prepare: { $0.onboarding.signup.path = [.signIn, .recoverIntro, .honestEnd] }),
      Screen("security", scenario: "passkeyUser", prepare: profile([.security])),
      Screen("security.passwordOnly", scenario: "passwordOnly", prepare: profile([.security])),
      Screen("security.removePasskey", scenario: "passkeyUser",
             prepare: step(.alertRemovePasskey, profile([.security]))),
      Screen("security.removeDevice", scenario: "passkeyUser", prepare: step(.alertRemoveDevice, profile([.security]))),
      Screen("security.removeThisIPhone", scenario: "passkeyUser", prepare: step(.alertRemoveThisIPhone) { graph in
        var status = CoreSync.SyncStatus()
        status.latch = .sealerFault
        graph.app.syncNotices.update(status)
        profile([.security])(graph)
      }),
      Screen("security.signOut", scenario: "passkeyUser", prepare: step(.alertSignOut, profile([.security]))),
      Screen("security.signOutAll", scenario: "passkeyUser", prepare: step(.alertSignOutAll, profile([.security]))),
      Screen("security.viewWords", scenario: "passkeyUser", prepare: step(.viewWords, profile([.security]))),
      Screen("security.lockdown", scenario: "passkeyUser", prepare: step(.lockdown, profile([.security]))),
      Screen("security.delete", scenario: "passkeyUser", prepare: profile([.security, .deleteAccount])),
      Screen("security.changeEmail", scenario: "passkeyUser", prepare: step(.changeEmail, profile([.security]))),
      Screen("security.changeEmailCodes", scenario: "passkeyUser",
             prepare: step(.changeEmailCodes, profile([.security]))),
      Screen("confirm.faceID", scenario: "passkeyUser", prepare: step(.confirmFaceID, profile([.security]))),
      Screen("confirm.password", scenario: "passwordOnly", prepare: step(.confirmPassword, profile([.security]))),
      Screen("confirm.noKey", scenario: "passwordOnly", prepare: step(.confirmNoKey, profile([.security]))),
      Screen("frozen", scenario: "frozen"),
      Screen("unfreeze", scenario: "frozen", prepare: step(.unfreeze)),
      Screen("security.frozen", scenario: "frozen", prepare: { graph in
        graph.session.leaveFrozen()
        profile([.security])(graph)
      }),
    ]

    static func mock(_ graph: MockGraph) -> MockAccountService? { graph.session.account as? MockAccountService }

    static func step(
      _ s: SignInLaunchStep, _ then: @escaping @MainActor (MockGraph) -> Void = { _ in }
    ) -> @MainActor (MockGraph) -> Void {
      { graph in
        then(graph)
        mock(graph)?.launchStep = s
      }
    }

    static func forgot(_ graph: MockGraph, to stop: WelcomeRoute) async {
      let signIn = graph.onboarding.signIn
      let signup = graph.onboarding.signup
      signIn.email = MockAccountService.existingEmail
      signIn.startReset()
      signup.path = [.signIn, .forgotEmail]
      guard await signIn.submitResetEmail() else { return }
      signup.go(.forgotCode)
      guard stop != .forgotCode else { return }
      signIn.resetCodeText = MockAccountService.emailCode
      guard await signIn.submitResetCode() else { return }
      signup.go(.forgotCheck)
      guard stop != .forgotCheck else { return }
      signup.go(.forgotNewPassword)
      signIn.newPassword = "harbor lights at dawn 7"
      signIn.confirmPassword = "harbor lights at dawn 7"
      guard stop != .forgotNewPassword else { return }
      guard await signIn.requestApproval() else { return }
      signup.go(.forgotWaiting)
    }

    static func recover(_ graph: MockGraph, to stop: WelcomeRoute) async {
      let signIn = graph.onboarding.signIn
      let signup = graph.onboarding.signup
      signup.path = [.signIn, .recoverIntro, .recoverWords]
      signIn.phraseText = MockAccountService.phraseWords.joined(separator: " ")
      guard await signIn.submitRecoveryWords() else { return }
      signup.go(.recoverCode)
      guard stop != .recoverCode else { return }
      signIn.recoverCode = MockAccountService.emailCode
      guard await signIn.submitRecoveryCode() else { return }
      signup.go(.recoverMethod)
    }

    static func applyUnlockLaunch(_ model: UnlockModel) async {
      guard let account = model.account as? MockAccountService, let s = account.takeLaunchStep() else { return }
      let words = MockAccountService.phraseWords
      switch s {
      case .unlockEntry:
        model.enterWords()
        model.phraseText = words.prefix(6).joined(separator: " ") + " cat"
      case .unlockUnlocking:
        model.phraseText = words.joined(separator: " ")
        account.delay = .seconds(3600)
        Task { await model.unlockWithWords() }
      case .unlockWelcomeBack:
        model.phraseText = words.joined(separator: " ")
        await model.unlockWithWords()
      case .unlockHonestEnd:
        model.noWords()
      default:
        break
      }
    }

    static func applySecurityLaunch(
      _ model: SecurityModel, alert: Binding<SecurityView.PendingAlert?>, lockingDown: Binding<Bool>
    ) async {
      guard let account = model.accountForEmailChange as? MockAccountService, let s = account.takeLaunchStep(),
        let state = model.state
      else { return }
      func settle() async { try? await Task.sleep(for: .milliseconds(700)) }
      switch s {
      case .alertRemovePasskey:
        if let p = state.passkeys.first(where: { !$0.isThisCredential }) { alert.wrappedValue = .removePasskey(p) }
      case .alertRemoveDevice:
        if let d = state.devices.first(where: { !$0.isThisDevice }) { alert.wrappedValue = .removeDevice(d) }
      case .alertRemoveThisIPhone:
        alert.wrappedValue = .removeThisIPhone
      case .alertSignOut:
        alert.wrappedValue = .signOut
      case .alertSignOutAll:
        alert.wrappedValue = .signOutEverywhere
      case .viewWords:
        await settle()
        model.requestPhrase()
        await settle()
        await model.confirm()
        await settle()
        model.phraseRevealed = true
      case .lockdown:
        lockingDown.wrappedValue = true
      case .changeEmail, .changeEmailCodes:
        account.launchStep = s == .changeEmail ? .emailNewAddress : .emailCodes
        await settle()
        model.requestEmailChange()
        await settle()
        await model.confirm()
      case .confirmFaceID:
        await settle()
        if let p = state.passkeys.first(where: { !$0.isThisCredential }) {
          await model.request(.removePasskey(id: p.id))
        }
      case .confirmPassword, .confirmNoKey:
        account.deviceKeyMissing = s == .confirmNoKey
        model.editingPassword = true
        await settle()
        model.newPassword = "harbor lights at dawn 7"
        model.confirmNewPassword = "harbor lights at dawn 7"
        await model.savePassword()
        await settle()
        model.confirmPassword = MockAccountService.existingPassword
        if s == .confirmNoKey { await model.confirm() }
      default:
        break
      }
    }

    static func applyEmailChangeLaunch(_ model: ChangeEmailModel) async {
      guard let account = model.account as? MockAccountService, let s = account.takeLaunchStep() else { return }
      model.newEmail = "maya.rahman@example.com"
      guard s == .emailCodes, await model.sendCodes() else { return }
      model.path = [.codes]
      model.currentCode = "318206"
      model.newCode = "594"
    }
  }
#endif
