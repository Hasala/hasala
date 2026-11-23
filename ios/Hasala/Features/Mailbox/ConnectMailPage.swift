import HasalaDesign
import HasalaModels
import SwiftUI

struct ConnectMailPage: View {
  @Bindable var app: AppModel
  let provider: MailProviderKind
  @State private var coordinator: MailConnectCoordinator?
  @State private var banks: [SupportedBank]
  @Environment(AccountSession.self) private var session: AccountSession?

  init(app: AppModel, provider: MailProviderKind) {
    self.app = app
    self.provider = provider
    let context = Self.context(provider, offer: app.mailOffer)
    let handed = MailConnectCoordinator.handed(provider)
    _coordinator = State(initialValue: handed ?? app.mailbox.map { MailConnectCoordinator(mailbox: $0, context: context) })
    _banks = State(initialValue: app.mailbox?.chosenBanks() ?? [])
  }

  static func context(_ provider: MailProviderKind, offer: MailOffer?) -> MailConnectCoordinator.Context {
    if case .signInAgain(let id, let p)? = offer, p == provider { return .signInAgain(mailboxID: id) }
    return .addMailbox
  }

  var body: some View {
    if let coordinator, let mailbox = app.mailbox {
      Group {
        if banks.isEmpty {
          MailBanksStep(provider: provider, setup: session?.services.setup) { banks = $0 }
        } else if let failure = coordinator.errorScreen {
          MailConnectErrorView(
            failure: failure, provider: provider,
            onRetry: { retry(coordinator, mailbox) },
            onChooseDifferent: chooseDifferent)
        } else {
          ConnectProviderView(
            provider: provider, coordinator: coordinator, banks: banks,
            onConnected: { id in connected(id, mailbox, coordinator.context) },
            onChooseDifferent: chooseDifferent, choiceIsBack: choiceIsBack)
        }
      }
      .hAnimation(.stateSwap, value: coordinator.errorScreen)
      #if HASALA_MOCKS
        .task { if !banks.isEmpty, MailLaunch.takeConnect(provider) { await run(coordinator, mailbox) } }
      #endif
    }
  }

  private func retry(_ coordinator: MailConnectCoordinator, _ mailbox: MailboxConnecting) {
    coordinator.reset()
    Task {
      await coordinator.retry(provider)
      finish(coordinator, mailbox)
    }
  }

  private func run(_ coordinator: MailConnectCoordinator, _ mailbox: MailboxConnecting) async {
    await coordinator.connect(provider)
    finish(coordinator, mailbox)
  }

  private func finish(_ coordinator: MailConnectCoordinator, _ mailbox: MailboxConnecting) {
    if case .connected(let id)? = coordinator.outcome { connected(id, mailbox, coordinator.context) }
  }

  private var choiceIsBack: Bool {
    let path = app.router.profile
    guard let i = path.lastIndex(of: .connectMail(provider)), i > 0 else { return false }
    return path[i - 1] == .addMailbox
  }

  private func chooseDifferent() {
    var path = app.router.profile
    if path.last == .connectMail(provider) { path.removeLast() }
    if path.last != .addMailbox { path.append(.addMailbox) }
    app.router.profile = path
  }

  private func connected(_ id: String, _ mailbox: MailboxConnecting, _ context: MailConnectCoordinator.Context) {
    if context == .addMailbox {
      app.say(coordinator?.addedLine ?? MailCopy.added(provider))
      MailboxMoment.hand(.added(mailboxID: id), to: app.router)
      Task {
        guard await mailbox.linkState() == .scanning else { return }
        for await _ in mailbox.firstScan() {}
      }
    } else {
      app.say(coordinator?.signedInAgainLine ?? MailCopy.signedInAgain(provider))
      MailboxMoment.hand(.signedInAgain(mailboxID: id), to: app.router)
    }
    app.router.backToBankAlerts()
  }
}

private struct MailBanksStep: View {
  let provider: MailProviderKind
  let setup: SetupAuthoring?
  var onChosen: ([SupportedBank]) -> Void

  @State private var chosen = Set(SupportedBank.allCases)
  @State private var busy = false
  @State private var failure: SetupFailure?

  private var ordered: [SupportedBank] { SupportedBank.allCases.filter { chosen.contains($0) } }

  var body: some View {
    AccountScreen(
      title: "Which bank do you use?",
      subtitle: "Hasala reads only your banks' transaction alerts.",
      back: .system
    ) {
      VStack(alignment: .leading, spacing: 12) {
        Text("Available now").hType(.overline).foregroundStyle(HColor.textSecondary).padding(.leading, 16)
        VStack(spacing: 0) {
          ForEach(Array(SupportedBank.allCases.enumerated()), id: \.element) { i, bank in
            if i > 0 { HDivider(inset: .disc68) }
            BankChoiceRow(bank: bank, on: chosen.contains(bank)) {
              if chosen.contains(bank) { chosen.remove(bank) } else { chosen.insert(bank) }
            }
          }
        }
        .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.listGroup, style: .continuous))
        if let message = failure?.message {
          FailureBanner(failure: .badPhrase(message))
        }
      }
    } footer: {
      LockNote(text: "Next you'll connect \(provider.appName), read-only, on this iPhone.")
        .padding(.bottom, 8)
      BusyButton(title: chosen.count == 1 ? "Continue with 1 bank" : "Continue with \(chosen.count) banks",
                 busy: busy, enabled: !chosen.isEmpty && setup != nil, identifier: "bank.continue") {
        Task { await choose() }
      }
      .dockPill()
    }
  }

  private func choose() async {
    guard let setup, !chosen.isEmpty, !busy else { return }
    busy = true
    defer { busy = false }
    let banks = ordered
    do {
      try await setup.chooseBanks(banks)
      failure = nil
      onChosen(banks)
    } catch {
      failure = error
    }
  }
}
