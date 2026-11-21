import HasalaDesign
import HasalaModels
import SwiftUI

struct ConnectProviderView: View {
  let provider: MailProviderKind
  @Bindable var coordinator: MailConnectCoordinator
  let banks: [SupportedBank]
  var sample: (() -> Void)?
  var onConnected: (String) -> Void
  var onChooseDifferent: () -> Void
  var choiceIsBack: Bool
  var asksSwitch: Bool
  @State private var asking: MailProviderKind?

  init(
    provider: MailProviderKind, coordinator: MailConnectCoordinator, banks: [SupportedBank],
    sample: (() -> Void)? = nil, onConnected: @escaping (String) -> Void, onChooseDifferent: @escaping () -> Void,
    choiceIsBack: Bool = false, asksSwitch: Bool = true
  ) {
    self.provider = provider
    self.coordinator = coordinator
    self.banks = banks
    self.sample = sample
    self.onConnected = onConnected
    self.onChooseDifferent = onChooseDifferent
    self.choiceIsBack = choiceIsBack
    self.asksSwitch = asksSwitch
  }

  private var steps: (current: Int, of: Int)? {
    if case .setup(let steps) = coordinator.context { return steps.map { ($0.0, $0.1) } }
    return nil
  }

  private var signInAgainID: String? {
    if case .signInAgain(let id) = coordinator.context { return id }
    return nil
  }

  private var isSetup: Bool {
    if case .setup = coordinator.context { return true }
    return false
  }

  var body: some View {
    let connected = coordinator.connectedMailbox(provider)
    AccountScreen(title: title(connected), subtitle: subtitle, steps: steps, back: .system) {
      VStack(alignment: .leading, spacing: 0) {
        Group {
          if let connected {
            HListCard { MailboxRow(connected) }
              .accessibilityIdentifier("mail.connected")
          } else {
            FlowStrip(provider: provider)
          }
        }
        .hTransition(.stateSwap)
        ReadsNeverCard(banks: banks)
          .padding(.top, 16)
        Text(MailCopy.readNote)
          .hType(.footnote)
          .foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 10)
          .padding(.horizontal, 8)
        if connected == nil {
          Text(MailCopy.confirmNote)
            .hType(.footnote)
            .foregroundStyle(HColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
            .padding(.horizontal, 8)
            .accessibilityIdentifier("mail.confirmNote")
        }
        if let message = coordinator.inlineMessage, case .failed(let failure)? = coordinator.outcome {
          InlineStatus(tone: Self.tone(failure), text: message, size: .regular)
            .padding(.top, 16)
            .padding(.horizontal, 8)
            .hTransition(.rise)
            .accessibilityIdentifier("mail.status")
        }
      }
      .padding(.top, -4)
      .hAnimation(.stateSwap, value: connected?.id)
      .hAnimation(.rise, value: coordinator.inlineMessage)
    } footer: {
      if let connected {
        BusyButton(title: "Continue", busy: false, identifier: "mail.continue") { onConnected(connected.id) }
          .dockPill()
      } else if let sample {
        BusyButton(title: "Use sample data", busy: false, identifier: "mail.sample", action: sample)
          .dockPill()
        Button(action: connect) {
          HStack(spacing: 10) {
            if !coordinator.busy { ProviderMark(provider, size: .disc26) }
            Text(provider.continueTitle)
          }
        }
        .buttonStyle(.pill(.tertiary, size: .medium, fill: true, loading: coordinator.busy))
        .dockPill()
        .accessibilityIdentifier("mail.connect.\(provider.rawValue)")
      } else {
        ProviderButton(provider: provider, loading: coordinator.busy, action: connect)
          .dockPill()
          .accessibilityIdentifier("mail.connect.\(provider.rawValue)")
        footerLink
      }
    }
    .scrollIndicatorsFlash(onAppear: true)
    .providerConnectQuestions(coordinator, provider: provider, request: $asking, run: run)
    .mailSwitchQuestion(coordinator, asks: asksSwitch)
    .hHaptic(.success, trigger: connectedOutcome) { _, new in isSetup && new != nil }
  }

  private var connectedOutcome: String? {
    if case .connected(let id)? = coordinator.outcome { return id }
    return nil
  }

  private func title(_ connected: MailboxSnapshot?) -> String {
    if connected != nil { return "\(provider.appName) is connected." }
    if signInAgainID != nil { return "Sign in to \(provider.appName) again." }
    return "Read-only \(provider.appName), on your iPhone."
  }

  private var subtitle: String {
    if let id = signInAgainID, coordinator.connectedMailbox(provider) == nil {
      let row = coordinator.mailbox.mailboxes.first { $0.id == id }
      if let note = row?.note { return note }
      let address = row?.address ?? "this mailbox"
      return "\(provider.company) ended Hasala's access to \(address). Sign in again to catch up."
    }
    return "Your iPhone fetches your bank alerts from \(provider.appName)."
  }

  @ViewBuilder private var footerLink: some View {
    if signInAgainID != nil {
      EmptyView()
    } else if coordinator.mailbox.connectable.count <= 1 {
      TellUsWhichLink()
    } else if choiceIsBack {
      if provider == .outlook {
        Text(Self.outlookAccountLine)
          .hType(.subheadline)
          .foregroundStyle(HColor.textSecondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.top, 4)
          .accessibilityIdentifier(BuildSurface.showsUnfinished ? "mail.workAccount" : "mail.personalOnly")
      }
    } else if provider == .outlook {
      TextLinkRow(lead: Self.outlookAccountLine,
                  link: "Choose a different email", identifier: "mail.notYours", action: onChooseDifferent)
    } else {
      TextLinkRow(lead: "Not your email?", link: "Choose a different email", identifier: "mail.notYours",
                  action: onChooseDifferent)
    }
  }

  static var outlookAccountLine: String {
    BuildSurface.showsUnfinished
      ? "Work or school account? Your organisation may need to approve Hasala."
      : "Outlook: personal Microsoft accounts only."
  }

  private func connect() {
    asking = provider
  }

  private func run(replacing: Bool, removingOld: Bool) {
    Task {
      await coordinator.connect(provider, replacing: replacing, removingOld: removingOld)
      if case .connected(let id)? = coordinator.outcome { onConnected(id) }
    }
  }

  static func tone(_ failure: MailConnectFailure) -> InlineStatus.Tone {
    switch failure {
    case .alreadyConnected: .accent
    case .offline, .takenByOtherIPhone, .cancelled, .switchDeclined: .warning
    case .noMailbox, .permissionMissing, .failed: .error
    }
  }
}

private struct ProviderConnectQuestions: ViewModifier {
  let coordinator: MailConnectCoordinator
  let provider: MailProviderKind
  @Binding var request: MailProviderKind?
  let run: (_ replacing: Bool, _ removingOld: Bool) -> Void
  @State private var switching: MailboxSnapshot?
  @State private var switchImpact: MailboxDisconnectImpact?
  @State private var askingImpact = false
  @State private var takingOver: MailProviderKind?
  @State private var askingPastMail = false

  func body(content: Content) -> some View {
    content
      .onChange(of: request) { _, asked in
        guard asked != nil else { return }
        request = nil
        if coordinator.asksPastMail(provider) {
          askingPastMail = true
        } else {
          start()
        }
      }
      .alert(MailCopy.pastMailTitle, isPresented: $askingPastMail) {
        Button("Import past email") { answerPastMail(.importPast) }
          .accessibilityIdentifier("mail.pastMail.import")
        Button("Only new email") { answerPastMail(.newOnly) }
          .accessibilityIdentifier("mail.pastMail.newOnly")
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(MailCopy.pastMailMessage(days: coordinator.mailbox.pastMailDays))
      }
      .alert(MailCopy.switchTitle, isPresented: Binding(get: { switching != nil }, set: { if !$0 { switching = nil } }),
             presenting: switching) { _ in
        if let impact = switchImpact {
          Button(MailCopy.keepOnSwitch("Use \(provider.appName)", impact)) { run(true, false) }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("mail.confirmSwitch")
          Button(MailCopy.removeTitle(impact, lead: "Use \(provider.appName)"), role: .destructive) { run(true, true) }
            .accessibilityIdentifier("mail.confirmSwitch.remove")
          Button("Cancel", role: .cancel) {}
        } else {
          Button("Cancel", role: .cancel) {}
          Button("Use \(provider.appName)") { run(true, false) }
            .accessibilityIdentifier("mail.confirmSwitch")
        }
      } message: { old in
        Text(MailCopy.switchMessage(from: old.provider, to: provider, impact: switchImpact))
      }
      .alert(MailCopy.takeoverTitle, isPresented: Binding(get: { takingOver != nil }, set: { if !$0 { takingOver = nil } }),
             presenting: takingOver) { _ in
        Button("Cancel", role: .cancel) {}
        Button("Read it here") { run(true, false) }
          .accessibilityIdentifier("mail.confirmTakeover")
      } message: { held in
        Text(MailCopy.takeoverMessage(from: held, to: provider))
      }
  }

  private func answerPastMail(_ choice: MailPastChoice) {
    coordinator.pastMail = choice
    start()
  }

  private func start() {
    if let held = coordinator.takesOver {
      takingOver = held
    } else if let old = coordinator.replaced(by: provider) {
      guard !askingImpact else { return }
      askingImpact = true
      Task {
        switchImpact = await coordinator.mailbox.disconnectImpact(old.id)
        askingImpact = false
        switching = old
      }
    } else {
      run(false, false)
    }
  }
}

extension View {
  func providerConnectQuestions(
    _ coordinator: MailConnectCoordinator, provider: MailProviderKind, request: Binding<MailProviderKind?>,
    run: @escaping (_ replacing: Bool, _ removingOld: Bool) -> Void
  ) -> some View {
    modifier(ProviderConnectQuestions(coordinator: coordinator, provider: provider, request: request, run: run))
  }
}
