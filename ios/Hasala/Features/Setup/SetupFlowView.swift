import HasalaDesign
import HasalaModels
import SwiftUI

struct SetupFlowView: View {
  @State private var model: SetupModel

  init(model: SetupModel) {
    _model = State(initialValue: model)
  }

  var body: some View {
    NavigationStack(path: $model.navigationPath) {
      Group {
        if model.asksSource {
          SourceStep(model: model)
        } else {
          BankStep(model: model)
        }
      }
      .navigationDestination(for: SetupRoute.self) { route in
        switch route {
        case .connectError(let provider): EmailErrorStep(model: model, provider: provider)
        case .textsSetUp: TextsSetUpStep(model: model)
        case .textsTest: TextsTestStep(model: model)
        }
      }
    }
    .sheet(isPresented: $model.choosingEmail, onDismiss: model.choosingEnded) {
      ChooseEmailSheet(mailbox: model.mailbox, title: .setup) { model.choose($0) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup.chooseEmail")
    }
    .onAppear { model.resume() }
    .onChange(of: model.step) { model.resume() }
  }
}

private struct EmailErrorStep: View {
  var model: SetupModel
  let provider: MailProviderKind
  @State private var shown: MailConnectFailure?
  @Environment(\.openURL) private var openURL

  var body: some View {
    let coordinator = model.coordinator(provider)
    MailConnectErrorView(
      failure: model.connectFailure(provider) ?? shown ?? .cancelled, provider: provider,
      busy: coordinator.busy,
      onRetry: { Task { await model.retryConnect(provider) } },
      onChooseDifferent: {
        if model.canChooseEmail { model.chooseEmail() } else { openURL(BuildSurface.supportMail) }
      },
      onUseTexts: model.offersBankTexts ? { model.useBankTextsInstead() } : nil,
      steps: nil)
      .mailSwitchQuestion(coordinator)
      .onChange(of: model.connectFailure(provider), initial: true) { _, failure in
        if let failure { shown = failure }
      }
  }
}
