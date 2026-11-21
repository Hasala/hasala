import HasalaDesign
import HasalaModels
import SwiftUI

struct MailboxDetailPage: View {
  @Bindable var app: AppModel
  let mailboxID: String
  @State private var choosing = false
  @State private var impact: MailboxDisconnectImpact?
  @State private var confirming: MailboxSnapshot?
  @State private var confirmingPlain = false
  @State private var work = MailboxPageWork.idle
  @State private var failure: MailConnectFailure?
  @State private var signIn: MailConnectCoordinator?
  @State private var signedIn = 0
  @State private var importingPast = false
  @Environment(\.hMotion) private var motion

  init(app: AppModel, mailboxID: String) {
    self.app = app
    self.mailboxID = mailboxID
    _signIn = State(initialValue: Self.signInAttempt(app, mailboxID))
  }

  private static func signInAttempt(_ app: AppModel, _ mailboxID: String) -> MailConnectCoordinator? {
    app.mailbox.map { MailConnectCoordinator(mailbox: $0, context: .signInAgain(mailboxID: mailboxID)) }
  }

  private var mailbox: MailboxSnapshot? { app.mailbox?.mailboxes.first { $0.id == mailboxID } }

  var body: some View {
    ScrollView {
      Group {
        if let m = mailbox {
          VStack(alignment: .leading, spacing: 24) {
            if m.state == .needsSignIn {
              needsSignIn(m)
            } else {
              working(m)
            }
            if let message = failure?.message(for: m.provider) {
              InlineStatus(tone: .error, text: message, size: .regular)
                .padding(.horizontal, 16)
                .hTransition(.rise)
            }
          }
          .hAnimation(.stateSwap, value: m.state)
        } else {
          EmptyStateCard(icon: .envelope, tone: .neutral, title: "This mailbox is no longer here",
                         message: "It was disconnected. Past transactions stay.")
        }
      }
      .padding(.horizontal, HSpacing.insetPage)
      .padding(.top, 8)
      .padding(.bottom, 48)
    }
    .background(HColor.surfaceSecondary)
    .navigationTitle(mailbox?.provider.appName ?? "Mailbox")
    .navigationBarTitleDisplayMode(.inline)
    .navigationDestination(isPresented: $choosing) {
      if let m = confirming, let impact {
        MailboxDisconnectPage(
          mailbox: m, impact: impact, textsNote: textsNote, busy: work == .disconnecting,
          failure: failure?.message(for: m.provider)
        ) { removing in
          Task { await disconnect(removing: removing) }
        }
      }
    }
    .onChange(of: mailbox == nil) { _, gone in
      if gone, !work.isBusy { choosing = false }
    }
    .alert("Disconnect \(mailbox?.address ?? "this mailbox")?", isPresented: $confirmingPlain) {
      Button("Cancel", role: .cancel) {}
      Button("Disconnect", role: .destructive) { Task { await disconnect(removing: false) } }
    } message: {
      Text(withTextsNote(MailCopy.disconnectPlainMessage))
    }
    .mailSwitchQuestion(signIn)
    .hHaptic(.success, trigger: signedIn) { old, new in new > old }
    #if HASALA_MOCKS
      .task { if MailLaunch.takeDisconnect(mailboxID) { await askToDisconnect() } }
    #endif
  }

  @ViewBuilder private func working(_ m: MailboxSnapshot) -> some View {
    HListCard {
      MailboxRow(m)
      ForEach(details(m, signInLayout: false), id: \.key) { row in
        HDivider(inset: .text16)
        MailboxFactRow(fact: row)
      }
    }
    .accessibilityIdentifier("mailbox.card")
    if m.state == .readingStopped, !m.readElsewhere {
      VStack(alignment: .leading, spacing: 10) {
        InlineStatus(tone: .warning, text: MailCopy.readingStopped, size: .regular)
        if app.mailbox?.capabilities.contains(.tryAgain) == true {
          Button("Try again") { Task { await tryAgain(m) } }
            .buttonStyle(.pill(.primary, size: .large, fill: true, loading: work.tryAgainLoads))
            .disabled(work.isBusy)
            .accessibilityIdentifier("mailbox.tryAgain")
        }
      }
      .padding(.horizontal, 16)
    }
    if m.pastMailSkipped, !m.readElsewhere, m.state == .connected {
      pastMailCard(m)
    }
    banksCard(m)
    #if DEBUG
      if m.provider == .outlook, BuildSurface.showsUnfinished, let live = app.mailbox as? LiveMailboxConnecting {
        NavigationLink {
          OutlookHeaderOrderPage(mailbox: live)
        } label: {
          Text("Header order check (Debug)")
            .hType(.body).foregroundStyle(HColor.textLink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
        }
        .accessibilityIdentifier("mailbox.headerOrderCheck")
      }
    #endif
    disconnect(m, footnote: m.state == .disconnected ? nil : Self.disconnectFootnote,
               tip: Self.providerSettingsTip(m.provider))
    if m.state == .disconnected {
      Text("No longer read. Past transactions stay.")
        .hType(.footnote).foregroundStyle(HColor.textSecondary)
        .padding(.horizontal, 16)
    }
  }

  private func pastMailCard(_ m: MailboxSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Past email isn't imported")
          .hType(.headline).foregroundStyle(HColor.textPrimary)
          .accessibilityAddTraits(.isHeader)
        Text(MailCopy.pastMailSkippedDetail(days: app.mailbox?.pastMailDays ?? 90))
          .hType(.subheadline).foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Button("Import past email") { Task { await importPast(m) } }
        .buttonStyle(.pill(.tertiary, size: .large, fill: true, loading: importingPast))
        .disabled(importingPast)
        .accessibilityIdentifier("mailbox.importPast")
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
    .accessibilityElement(children: .contain)
  }

  private func importPast(_ m: MailboxSnapshot) async {
    guard let mailbox = app.mailbox, !importingPast else { return }
    importingPast = true
    defer { importingPast = false }
    switch await mailbox.importPastMail(m.id) {
    case .finished(let count): app.say(MailCopy.pastImported(count))
    case .later: app.say(MailCopy.pastImportLater)
    case .notStarted: app.say(SourceSwitch.checking, icon: .info)
    }
  }

  private func tryAgain(_ m: MailboxSnapshot) async {
    guard let mailbox = app.mailbox, work.begin(.tryingAgain, clearing: &failure, signIn: signIn) else { return }
    await mailbox.tryAgain(m.id)
    work = .idle
  }

  @ViewBuilder private func needsSignIn(_ m: MailboxSnapshot) -> some View {
    VStack(spacing: 10) {
      ProviderMark(m.provider, size: .large64)
      Text(m.address)
        .hType(HType(size: 22, leading: 28, weight: .bold, textStyle: .title2))
        .foregroundStyle(HColor.textPrimary)
        .multilineTextAlignment(.center)
      MailboxStatusChip(m.state)
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 8)
    .accessibilityElement(children: .combine)
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 4) {
        Text(Self.signInHeading(m))
          .hType(.headline).foregroundStyle(HColor.textPrimary)
          .accessibilityAddTraits(.isHeader)
          .infoTip(m.note == nil ? Self.signInCause : nil, about: "why access ends")
        Text(Self.signInBody(m))
          .hType(.subheadline).foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      if app.mailbox?.capabilities.contains(.signInAgain) == true {
        ProviderButton(provider: m.provider, loading: work.signInLoads) { signInAgain(m.provider) }
          .disabled(work.isBusy)
          .accessibilityIdentifier("mailbox.signInAgain")
        if let line = signIn?.failureLine {
          InlineStatus(tone: .warning, text: line, size: .regular).hTransition(.rise)
        }
      }
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
    .accessibilityElement(children: .contain)
    HListCard {
      ForEach(Array(details(m, signInLayout: true).enumerated()), id: \.element.key) { i, row in
        if i > 0 { HDivider(inset: .text16) }
        MailboxFactRow(fact: row, style: .details)
      }
    }
    .accessibilityIdentifier("mailbox.details")
    disconnect(m, footnote: "No new alerts from this mailbox. You choose whether its transactions stay.")
  }

  static func signInBody(_ m: MailboxSnapshot) -> String {
    if let note = m.note { return note }
    var lines: [String] = []
    if let day = m.lastChecked?.split(separator: ",").first {
      lines.append("No new \(m.provider.appName) alerts since \(day).")
    }
    lines.append("Sign in again to catch up.")
    return lines.joined(separator: " ")
  }

  static let signInCause = "Usually after a password change, a long time signed out, or a work policy."

  static func signInHeading(_ m: MailboxSnapshot) -> String {
    m.note == nil ? "\(m.provider.company) ended Hasala's access" : "Sign in with another account"
  }

  struct Fact: Hashable {
    let key: String
    let value: String
  }

  private func details(_ m: MailboxSnapshot, signInLayout: Bool) -> [Fact] {
    var rows: [Fact] = []
    if let kind = m.accountKind { rows.append(Fact(key: "Account", value: kind)) }
    if signInLayout, !m.banks.isEmpty {
      rows.append(Fact(key: "Banks found here", value: m.banks.formatted(.list(type: .and))))
    }
    if let checked = m.lastChecked { rows.append(Fact(key: "Last checked", value: checked)) }
    rows.append(Fact(key: "Access", value: m.provider.access))
    if !signInLayout, let on = m.connectedOn { rows.append(Fact(key: "Connected", value: on)) }
    return rows
  }

  @ViewBuilder private func banksCard(_ m: MailboxSnapshot) -> some View {
    let banks = SupportedBank.allCases.filter(m.reads)
    if !banks.isEmpty {
      VStack(alignment: .leading, spacing: 12) {
        HSectionHeader("Banks in this mailbox")
        HListCard {
          ForEach(Array(banks.enumerated()), id: \.element) { i, bank in
            if i > 0 { HDivider(inset: .disc68) }
            BankAlertsBankRow(
              bank: bank,
              detail: BankAlertsPage.bankDetail(
                bank, lastEmail: (app.mailbox as? BankAlertsReporting)?.lastEmail(bank),
                checking: m.state == .syncing))
          }
        }
      }
    }
  }

  @ViewBuilder private func disconnect(_ m: MailboxSnapshot, footnote: String?, tip: String? = nil) -> some View {
    if m.readElsewhere {
      Text(Self.readElsewhereFootnote(m.provider))
        .hType(.footnote).foregroundStyle(HColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16)
        .accessibilityIdentifier("mailbox.readElsewhere")
    } else if m.state != .disconnected, app.mailbox?.capabilities.contains(.disconnect) == true {
      VStack(alignment: .leading, spacing: 10) {
        Button("Disconnect this mailbox") { Task { await askToDisconnect() } }
          .buttonStyle(.pill(.destructiveQuiet, size: .large, fill: true, loading: work.disconnectLoads))
          .disabled(work.isBusy)
          .accessibilityIdentifier("mailbox.disconnect")
        if let footnote {
          Text(footnote).hType(.footnote).foregroundStyle(HColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .infoTip(tip, about: "access in your \(m.provider.company) account")
            .padding(.horizontal, 16)
        }
      }
    }
  }

  static let disconnectFootnote = "Stops alerts and deletes its sign-in from this iPhone. You choose whether its transactions stay."

  static func providerSettingsTip(_ provider: MailProviderKind) -> String {
    "You can also remove Hasala in your \(provider.company) account settings."
  }

  static func readElsewhereFootnote(_ provider: MailProviderKind) -> String {
    "Your other iPhone reads this mailbox. Disconnect it there, or remove Hasala at \(MailCopy.consentPage(provider))."
  }

  private func signInAgain(_ provider: MailProviderKind) {
    guard let signIn, work.begin(.signingIn, clearing: &failure, signIn: signIn) else { return }
    let policy = motion
    Task {
      await signIn.connect(provider)
      work = .idle
      if signIn.failedWithNoMailbox {
        MailConnectCoordinator.hand(signIn, to: app.router)
        self.signIn = Self.signInAttempt(app, mailboxID)
      } else if let line = signIn.signedInAgainLine {
        app.say(line)
        signIn.reset()
        try? await Task.sleep(for: policy.settleDelay(.stateSwap))
        signedIn += 1
      }
    }
  }

  private var textsNote: String? {
    BankTexts.disconnectNote(app.bankTexts, mailbox: app.mailbox, disconnecting: mailboxID)
  }

  private func withTextsNote(_ message: String) -> String {
    guard let note = textsNote else { return message }
    return "\(message) \(note)"
  }

  private func askToDisconnect() async {
    guard let lane = app.mailbox, work.begin(.askingToDisconnect, clearing: &failure, signIn: signIn) else { return }
    impact = await lane.disconnectImpact(mailboxID)
    work = .idle
    confirming = mailbox
    if impact == nil { confirmingPlain = true } else { choosing = true }
  }

  private func disconnect(removing: Bool) async {
    guard let lane = app.mailbox, let m = mailbox, work.begin(.disconnecting, clearing: &failure, signIn: signIn) else { return }
    let removed = removing ? impact?.transactions : nil
    defer { work = .idle }
    var refused: MailConnectFailure?
    do {
      try await lane.disconnect(mailboxID, removeTransactions: removing)
    } catch {
      refused = error
    }
    switch MailboxDisconnectEnding.after(refused, mailboxRemains: mailbox != nil, provider: m.provider, removed: removed) {
    case .left(let line, let partly):
      failure = nil
      choosing = false
      app.say(line, icon: partly ? .info : nil)
      app.router.backToBankAlerts()
    case .stayed(let reason):
      failure = reason
    }
  }
}

private struct MailboxFactRow: View {
  enum Style {
    case mailbox
    case details
  }

  let fact: MailboxDetailPage.Fact
  var style = Style.mailbox

  private var key: some View {
    Text(fact.key)
      .hType(style == .details ? .callout : .subheadline)
      .foregroundStyle(style == .details ? HColor.textPrimary : HColor.textSecondary)
  }

  private var row: some View {
    ReflowingRow(spacing: 12) {
      key
    } trailing: {
      FactValue(text: fact.value, style: style)
    }
  }

  var body: some View {
    row
      .padding(.horizontal, 16)
      .padding(.vertical, style == .details ? 10 : 14)
      .frame(minHeight: style == .details ? 52 : nil)
      .accessibilityElement(children: .combine)
  }
}

private struct FactValue: View {
  let text: String
  let style: MailboxFactRow.Style
  @Environment(\.reflowingRowStacked) private var stacked

  var body: some View {
    Text(text).hType(.subheadline)
      .foregroundStyle(style == .details ? HColor.textSecondary : HColor.textPrimary)
      .multilineTextAlignment(stacked ? .leading : .trailing)
  }
}

enum MailboxPageWork: Equatable {
  case idle
  case tryingAgain
  case askingToDisconnect
  case disconnecting
  case signingIn

  var isBusy: Bool { self != .idle }
  var tryAgainLoads: Bool { self == .tryingAgain }
  var disconnectLoads: Bool { self == .askingToDisconnect || self == .disconnecting }
  var signInLoads: Bool { self == .signingIn }

  mutating func begin(_ next: MailboxPageWork) -> Bool {
    guard self == .idle else { return false }
    self = next
    return true
  }

  @MainActor
  mutating func begin(
    _ next: MailboxPageWork, clearing failure: inout MailConnectFailure?, signIn: MailConnectCoordinator?
  ) -> Bool {
    guard begin(next) else { return false }
    failure = nil
    signIn?.reset()
    return true
  }
}

enum MailboxDisconnectEnding: Equatable {
  case left(line: String, partly: Bool)
  case stayed(MailConnectFailure)

  static func after(
    _ failure: MailConnectFailure?, mailboxRemains: Bool, provider: MailProviderKind, removed: Int?
  ) -> MailboxDisconnectEnding {
    guard let failure else { return .left(line: MailCopy.disconnected(provider, removed: removed), partly: false) }
    if mailboxRemains { return .stayed(failure) }
    return .left(line: failure.message(for: provider) ?? MailCopy.disconnected(provider, removed: nil), partly: true)
  }
}

enum MailboxDisconnectChoice: Hashable, CaseIterable {
  case keep
  case remove

  static let initial = MailboxDisconnectChoice.keep

  var removesTransactions: Bool { self == .remove }
}

struct MailboxDisconnectPage: View {
  let mailbox: MailboxSnapshot
  let impact: MailboxDisconnectImpact
  let textsNote: String?
  let busy: Bool
  let failure: String?
  var disconnect: (Bool) -> Void
  @State private var choice = MailboxDisconnectChoice.initial
  @Environment(\.openURL) private var openURL

  static let title = "Disconnect this mailbox"

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        Text(MailCopy.disconnectLead(mailbox.address))
          .hType(.subheadline)
          .foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 4)
        VStack(spacing: 0) {
          row(.keep, title: MailCopy.keepTransactions(impact), detail: nil)
          HDivider(inset: .text16)
          row(.remove, title: MailCopy.removeTransactions(impact), detail: MailCopy.removeDetail(impact))
        }
        .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
        permissionsLink
        if let textsNote {
          Text(textsNote)
            .hType(.footnote)
            .foregroundStyle(HColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .accessibilityIdentifier("mailbox.disconnect.textsNote")
        }
        if let failure {
          InlineStatus(tone: .error, text: failure, size: .regular)
            .padding(.horizontal, 16)
        }
      }
      .padding(.horizontal, HSpacing.insetPage)
      .padding(.top, 8)
      .padding(.bottom, 24)
    }
    .accessibilityIdentifier("mailbox.disconnectPage")
    .background(HColor.surfaceSecondary)
    .navigationTitle(Self.title)
    .navigationBarTitleDisplayMode(.inline)
    .safeAreaInset(edge: .bottom) {
      Button("Disconnect") { disconnect(choice.removesTransactions) }
        .buttonStyle(.pill(.destructive, size: .large, fill: true, loading: busy))
        .disabled(busy)
        .accessibilityIdentifier("mailbox.disconnect.confirm")
        .padding(.horizontal, HSpacing.insetPage)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(HColor.surfaceSecondary)
    }
  }

  private func row(_ option: MailboxDisconnectChoice, title: String, detail: String?) -> some View {
    let on = choice == option
    return Button { choice = option } label: {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          Text(title).hType(.rowTitle).foregroundStyle(HColor.textPrimary)
          if let detail {
            Text(detail).hType(.footnote).foregroundStyle(HColor.textSecondary)
          }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        HIconView(.check, size: 18, color: HColor.textLink, strokeWidth: 2.6)
          .frame(width: 24, height: 24)
          .opacity(on ? 1 : 0)
          .accessibilityHidden(true)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      .frame(minHeight: detail == nil ? 52 : 64)
      .contentShape(Rectangle())
    }
    .buttonStyle(HRowPressStyle())
    .disabled(busy)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    .accessibilityIdentifier("mailbox.disconnect.\(option == .keep ? "keep" : "remove")")
  }

  private var permissionsLink: some View {
    Button { openURL(MailCopy.consentURL(mailbox.provider)) } label: {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          Text(MailCopy.permissionsTitle(mailbox.provider)).hType(.rowTitle).foregroundStyle(HColor.textLink)
          Text(MailCopy.consentPage(mailbox.provider)).hType(.footnote).foregroundStyle(HColor.textSecondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        Image(systemName: "arrow.up.right")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(HColor.textLink)
          .accessibilityHidden(true)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      .frame(minHeight: 64)
      .contentShape(Rectangle())
    }
    .buttonStyle(HRowPressStyle())
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isLink)
    .accessibilityIdentifier("mailbox.disconnect.permissions")
  }
}
