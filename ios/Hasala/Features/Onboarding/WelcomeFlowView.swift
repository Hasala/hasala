import HasalaDesign
import SwiftUI

struct WelcomeFlowView: View {
  let store: OnboardingStore

  init(store: OnboardingStore) {
    self.store = store
  }

  private var session: AccountSession { store.session() }

  var body: some View {
    NavigationStack(path: Bindable(store.signup).navigationPath) {
      StoriesView(store: store)
        .navigationDestination(for: WelcomeRoute.self) { route in
          destination(route)
        }
    }
    .onAppear { store.consumeInvite() }
    .onChange(of: session.pendingInvite) { _, _ in store.consumeInvite() }
  }

  @ViewBuilder private func destination(_ route: WelcomeRoute) -> some View {
    switch route {
    case .invite: InviteCodeView(store: store)
    case .inviteReady: InviteReadyView(store: store)
    case .aboutYou: AboutYouView(store: store)
    case .verifyEmail: VerifyEmailView(store: store)
    case .method: SignInMethodView(store: store)
    case .password: CreatePasswordView(store: store)
    case .phraseIntro: PhraseIntroView(store: store)
    case .phraseShow: PhraseShowView(store: store)
    case .accountReady: AccountReadyView(store: store).navigationBarBackButtonHidden()
    case .signIn: SignInView(store: store)
    case .forgotEmail: ForgotEmailView(store: store)
    case .forgotCode: ForgotCodeView(store: store)
    case .forgotCheck: ForgotCheckView(store: store)
    case .forgotNewPassword: ForgotNewPasswordView(store: store)
    case .forgotWaiting: ForgotWaitingView(store: store)
    case .recoverIntro: RecoverIntroView(store: store)
    case .recoverWords: RecoverWordsView(store: store)
    case .recoverCode: RecoverCodeView(store: store)
    case .recoverMethod: RecoverMethodView(store: store)
    case .recoverPassword: RecoverPasswordView(store: store)
    case .honestEnd: HonestEndView(store: store)
    }
  }
}
