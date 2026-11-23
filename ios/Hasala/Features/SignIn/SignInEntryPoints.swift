import SwiftUI

extension SignInView {
  init(store: OnboardingStore) {
    self.init(
      model: store.signIn, capabilities: store.session().capabilities,
      onForgot: {
        store.signIn.startReset()
        store.signup.go(.forgotEmail)
      },
      onRecover: { store.signup.go(.recoverIntro) },
      onJoin: { store.signup.path = [.invite] })
  }
}

extension ForgotEmailView {
  init(store: OnboardingStore) {
    self.init(model: store.signIn, onBack: { store.signup.back() }) { store.signup.go(.forgotCode) }
  }
}

struct ForgotCodeView: View {
  let store: OnboardingStore

  init(store: OnboardingStore) {
    self.store = store
  }

  var body: some View {
    let signIn = store.signIn
    CodeStepScreen(
      title: "Check your email",
      subtitle: "We sent a reset code to \(signIn.resetEmail). It works for 10 minutes.",
      steps: (2, 4), code: Bindable(signIn).resetCodeText, busy: signIn.busy,
      failure: signIn.failure(on: .forgotCode), sentAt: signIn.resetCodeSentAt,
      expired: { signIn.resetCodeExpired(now: $0) },
      trailing: (title: "Change email", identifier: "code.changeEmail", action: { store.signup.back() }),
      onSubmit: { Task { if await signIn.submitResetCode() { store.signup.go(.forgotCheck) } } },
      onResend: { Task { _ = await signIn.submitResetEmail() } })
      .onChange(of: signIn.resetCodeText) { _, _ in signIn.resetCodeEdited() }
  }
}

extension ForgotCheckView {
  init(store: OnboardingStore) {
    self.init(
      model: store.signIn, onApprove: { store.signup.go(.forgotNewPassword) },
      onWords: { store.signup.go(.recoverWords) }, onNeither: { store.signup.go(.honestEnd) })
  }
}

extension ForgotNewPasswordView {
  init(store: OnboardingStore) {
    self.init(model: store.signIn, onCancel: { store.signup.path = [.signIn] }) { store.signup.go(.forgotWaiting) }
  }
}

extension ForgotWaitingView {
  init(store: OnboardingStore) {
    self.init(model: store.signIn) { store.signup.go(.recoverWords) }
  }
}

extension RecoverIntroView {
  init(store: OnboardingStore) {
    self.init(setsPasskey: !store.signIn.capabilities.contains(.recoverWithPassword),
              onStart: { store.signup.go(.recoverWords) }, onNoWords: { store.signup.go(.honestEnd) })
  }
}

extension RecoverWordsView {
  init(store: OnboardingStore) {
    self.init(model: store.signIn) { store.signup.go(.recoverCode) }
  }
}

struct RecoverCodeView: View {
  let store: OnboardingStore

  init(store: OnboardingStore) {
    self.store = store
  }

  var body: some View {
    let signIn = store.signIn
    CodeStepScreen(
      title: "Check your email",
      subtitle: "We sent a code to \(signIn.recovery?.emailHint ?? "your account's address"). With your 12 words, it gets you in.",
      steps: (2, 3), code: Bindable(signIn).recoverCode, busy: signIn.busy,
      failure: signIn.failure(on: .recoverCode), sentAt: signIn.recoverCodeSentAt,
      expired: { signIn.recoverCodeExpired(now: $0) },
      trailing: (title: "Change words", identifier: "code.changeWords", action: { store.signup.back() }),
      onSubmit: { Task { if await signIn.submitRecoveryCode() { store.signup.go(.recoverMethod) } } },
      onResend: { Task { _ = await signIn.resendRecoveryCode() } })
  }
}

extension RecoverMethodView {
  init(store: OnboardingStore) {
    self.init(model: store.signIn, onPassword: { store.signup.go(.recoverPassword) },
              onResult: { store.recoveryResult($0) })
  }
}

extension RecoverPasswordView {
  init(store: OnboardingStore) {
    self.init(model: store.signIn, onResult: { store.recoveryResult($0) })
  }
}

struct HonestEndView: View {
  let store: OnboardingStore

  init(store: OnboardingStore) {
    self.store = store
  }

  var body: some View {
    HonestEndScreen(context: .signedOut) {
      if store.signup.path.last == .honestEnd { store.signup.path.removeLast() }
      store.signup.go(.recoverWords)
    }
  }
}

extension OnboardingStore {
  func recoveryResult(_ r: SignInModel.RecoveryResult) {
    switch r {
    case .done, .failed: break
    case .codeRejected:
      if let i = signup.path.lastIndex(of: .recoverCode) { signup.path.removeSubrange((i + 1)...) }
    case .startAgain:
      if let i = signup.path.lastIndex(of: .recoverWords) { signup.path.removeSubrange((i + 1)...) }
    }
  }
}
