import HasalaDesign
import SwiftUI

struct BootCheckView: View {
  let session: AccountSession
  @State private var signingOut = false

  var body: some View {
    NavigationStack {
      AccountScreen(
        title: session.resumeFailure == nil ? "Opening Hasala" : "Can't reach Hasala",
        subtitle: session.resumeFailure == nil
          ? "Checking your account."
          : "You're signed in. Go online to open your account."
      ) {
        if session.resumeFailure == nil || session.resuming || signingOut {
          ProgressView().frame(maxWidth: .infinity).padding(.top, 24)
        }
      } actions: {
        if session.resumeFailure != nil, !session.resuming, !signingOut {
          Button("Try again") { Task { await session.resume() } }
            .buttonStyle(.pill(.primary, fill: true))
            .accessibilityIdentifier("boot.retry")
          LinkButton(title: "Sign out", identifier: "boot.signOut") {
            signingOut = true
            Task { await session.signOut() }
          }
        }
      }
    }
    .task { await session.resume() }
  }
}

struct InterruptedSetupFlowView: View {
  let store: OnboardingStore

  init(store: OnboardingStore) {
    self.store = store
  }

  private var session: AccountSession { store.session() }

  var body: some View {
    let model = store.replacementModel()
    NavigationStack(path: Bindable(model).navigationPath) {
      AccountScreen(
        title: "Let's finish setting up",
        subtitle: "Setup stopped before your keys were saved, so we'll make new ones."
      ) {
        VStack(alignment: .leading, spacing: 12) {
          WarningCallout(icon: .paper, text: "New recovery phrase. Throw away any words you wrote before.")
          InfoCard(icon: .faceID, hue: .sky, title: "Then Face ID",
                   detail: "Your passkey confirms it's you, then the new words lock your data.",
                   radius: HRadius.tile)
          FailureBanner(failure: model.failure)
        }
      } actions: {
        Button("Show my new words") { model.showReplacementWords() }
          .buttonStyle(.pill(.primary, fill: true))
          .accessibilityIdentifier("resume.start")
        LinkButton(title: "Sign out", identifier: "resume.signOut") {
          Task { await session.signOut() }
        }
      }
      .navigationDestination(for: WelcomeRoute.self) { route in
        switch route {
        case .phraseShow:
          PhraseShowView(signup: model)
        case .accountReady:
          AccountReadyView(store: store, signup: model)
            .navigationBarBackButtonHidden()
        default:
          EmptyView()
        }
      }
    }
  }
}
