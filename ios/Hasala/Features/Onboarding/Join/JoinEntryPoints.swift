import SwiftUI
import UIKit

extension StoriesView {
  init(store: OnboardingStore) {
    self.init(
      page: Bindable(store).storyPage, whoSeesOpen: Bindable(store.signup).whoCanSeeOpen,
      outlook: store.services.mailbox.connectable.contains(.outlook),
      onGetStarted: { store.signup.go(.invite) },
      onPasteInvite: { store.signup.usePastedInvite($0, pasteboardChange: UIPasteboard.general.changeCount) },
      onSignIn: { store.signup.go(.signIn) })
  }
}

extension InviteCodeView {
  init(store: OnboardingStore) {
    self.init(model: store.signup, onSignIn: { store.signup.path = [.signIn] })
  }
}

extension AboutYouView {
  init(store: OnboardingStore) {
    self.init(model: store.signup, onSignIn: { store.signup.path = [.signIn] })
  }
}

extension SignInMethodView {
  init(store: OnboardingStore) {
    self.init(model: store.signup)
  }
}

extension CreatePasswordView {
  init(store: OnboardingStore) {
    self.init(model: store.signup)
  }
}

extension PhraseIntroView {
  init(store: OnboardingStore) {
    self.init(model: store.signup)
  }
}

extension PhraseShowView {
  init(store: OnboardingStore) {
    self.init(signup: store.signup)
  }

  init(signup m: SignupModel) {
    self.init(
      revealed: Bindable(m).phraseRevealed, words: m.phrase?.words ?? [], onBack: { m.back() },
      onContinue: { Task { await m.finish() } }, seen: m.phraseSeen, busy: m.busy, failure: m.failure,
      onCapture: { m.phraseMasked = $0 }, canShowAgain: !m.wordsOnlyInSetup)
  }
}

extension AccountReadyView {
  init(store: OnboardingStore) {
    self.init(store: store, signup: store.signup)
  }

  init(store: OnboardingStore, signup m: SignupModel) {
    self.init(profile: m.profile, signupEmail: m.email, outlook: store.services.mailbox.connectable.contains(.outlook),
              capabilities: m.capabilities, passkeyHoldsKeys: !m.passkeyWithoutPRF) {
      store.session().accountCreated()
    }
  }
}
