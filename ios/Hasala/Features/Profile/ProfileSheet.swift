import HasalaDesign
import HasalaModels
import SwiftUI

#if HASALA_MOCKS
  import HasalaMocks
#endif

struct ProfileSheet: View {
  @Bindable var app: AppModel
  @State private var model: ProfileViewModel
  @State private var confirmSignOut = false
  @State private var security: SecurityState?
  @Environment(\.dismiss) private var dismiss
  @Environment(AccountSession.self) private var session: AccountSession?

  private var unfinished: Bool { BuildSurface.showsUnfinished }

  private func can(_ action: AccountCapabilities) -> Bool {
    session?.capabilities.contains(action) ?? false
  }

  init(app: AppModel) {
    self.app = app
    _model = State(initialValue: ProfileViewModel(app: app))
  }

  private var snap: ProfileSnapshot { model.snapshot }

  private func push(_ route: ProfileRoute) { app.router.profile.append(route) }

  var body: some View {
    NavigationStack(path: Bindable(app.router).profile) {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          ProfileIdentity(name: snap.displayName, initial: snap.initial, email: app.avatarEmail, address: snap.email, status: snap.emailStatus)
          if let texts = app.bankTexts, texts.usesTexts {
            TimelineView(.periodic(from: .now, by: 60)) { context in
              BankAlertsCard(summary: .texts(texts.status, now: context.date)) { push(.bankAlerts) }
            }
          } else {
            BankAlertsCard(summary: summary) { push(.bankAlerts) }
          }
          money
          settings
          GravatarSection()
          if BuildSurface.showsCloudSuggestions { CloudSuggestionsSection(app: app) }
          footer
        }
        .padding(.horizontal, HSpacing.sheetPadding)
        .padding(.top, 8)
        .padding(.bottom, 48)
      }
      .scrollEdgeEffectStyle(.soft, for: .bottom)
      .background(HColor.sheetSurfaceLarge)
      .navigationTitle("Your profile")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { SheetCloseButton(identifier: "profile.close") { dismiss() } }
      .navigationDestination(for: ProfileRoute.self) { route in
        ProfilePage(app: app, model: model, route: route)
      }
      .task(id: app.router.profile.isEmpty) {
        guard app.router.profile.isEmpty else { return }
        security = try? await session?.account.securityState()
      }
      .alert("Sign out of this iPhone?", isPresented: $confirmSignOut) {
        Button("Sign out", role: .destructive) { signOut() }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(AccountCopy.signOutMessage)
      }
    }
    .environment(\.inProfileSheet, true)
    .environment(\.accountExport, CSVFile(rows: model.exportRows, name: CSVExport.fileName(model.today)))
    .overlay(alignment: .bottom) { ToastHost(app: app, placement: .bottom) }
    .sheet(item: Bindable(app.router).overProfile) { route in
      switch route {
      case .budget(let id):
        BudgetHost(app: app, category: id)
          .presentationDetents([.large])
      case .moveMoney(let id):
        MoveMoneyHost(app: app, category: id)
      default:
        EmptyView()
      }
    }
    .presentationDragIndicator(.visible)
    .presentationCornerRadius(HRadius.sheetLarge)
  }

  private func signOut() {
    guard let session else { return }
    Task { await session.signOut() }
  }

  private var summary: MailboxesSummary {
    MailboxesSummary(
      app.mailbox?.mailboxes ?? [], health: snap.mailbox, offer: app.mailOffer, known: app.mailbox?.mailboxesKnown ?? true,
      reading: app.store.state.reading)
  }

  private var money: some View {
    VStack(alignment: .leading, spacing: 12) {
      HSectionHeader("Your money")
      ProfileListCard(inset: .disc68) {
        if unfinished || snap.accountsKnown {
          row(.accounts, id: "profile.accounts") {
            MoneyThingRow(plate: Self.tile(.bank, square: true), title: "Accounts",
                          detail: snap.accounts, hidden: model.hidden)
          }
        }
        row(.bills, id: "profile.bills") {
          MoneyThingRow(plate: Self.tile(.receipt), title: "Recurring",
                        detail: MoneyPhrase(stringLiteral: snap.bills), hidden: model.hidden, badge: snap.newBills,
                        badgeSpoken: "\(snap.newBills) \(snap.newBills == 1 ? "item needs" : "items need") a look")
        }
        row(.rules, id: "profile.rules") {
          MoneyThingRow(plate: Self.tile(.tag), title: "Categories and rules",
                        detail: MoneyPhrase(stringLiteral: snap.categoriesAndRules), hidden: model.hidden)
        }
        if snap.archivedTxns > 0 {
          Button { app.router.showActivity(TxnFilter(kind: .archived)) } label: {
            MoneyThingRow(plate: Self.tile(.archive), title: "Archived transactions",
                          detail: MoneyPhrase(stringLiteral: Self.archivedLine(snap.archivedTxns)), hidden: model.hidden)
          }
          .buttonStyle(HRowPressStyle())
          .accessibilityHint("Opens Activity on Archived")
          .accessibilityIdentifier("profile.archived")
        }
        if BuildSurface.showsPlanTab {
          row(.projects, id: "profile.projects") {
            MoneyThingRow(plate: Self.tile(.project), title: "Projects", detail: snap.projects,
                          hidden: model.hidden)
          }
        } else {
          row(.plan, id: "profile.plan") {
            MoneyThingRow(plate: Self.tile(.tabPlan), title: "Plan", detail: model.planLine,
                          hidden: model.hidden)
          }
        }
      }
    }
  }

  static func tile(_ icon: HIcon, square: Bool = false) -> HuePlate {
    HuePlate(icon: icon, square: square)
  }

  private func row(_ route: ProfileRoute, id: String, @ViewBuilder label: () -> some View) -> some View {
    Button { push(route) } label: { label() }
      .buttonStyle(HRowPressStyle())
      .accessibilityIdentifier(id)
  }

  private var settings: some View {
    VStack(alignment: .leading, spacing: 12) {
      HSectionHeader("Settings")
      ProfileListCard(inset: .icon52) {
        if session != nil, can(.changeName) {
          row(.editName, id: "profile.editName") {
            SettingRow(icon: .pencil, title: "Name", trailing: .value(snap.displayName))
          }
        }
        if session != nil || unfinished {
          row(.security, id: "profile.security") {
            SettingRow(icon: .shieldCheck, title: "Sign-in & security",
                       trailing: security.map { let status = Self.securityStatus($0); return .status(status.text, status.tone) }
                         ?? .none)
          }
        }
        if let lane = app.mailbox {
          let value = Self.mailboxesValue(lane.mailboxes, known: lane.mailboxesKnown)
          row(.bankAlerts, id: "profile.mailboxes") {
            SettingRow(icon: .envelope, title: Self.bankAlertsTitle,
                       trailing: value.tone.map { .status(value.text, $0) } ?? .value(value.text))
          }
        }
        row(.exchangeRates, id: "profile.currency") {
          SettingRow(icon: .globe, title: Self.exchangeRatesTitle, trailing: Self.currencyTrailing(app.store.state))
        }
        if unfinished {
          row(.notifications, id: "profile.notifications") {
            SettingRow(icon: .bell, title: "Notifications", trailing: .value(snap.prefs.notifications.label))
          }
        }
        ShareLink(item: CSVFile(rows: model.exportRows, name: CSVExport.fileName(model.today)),
                  preview: SharePreview(CSVExport.fileName(model.today))) {
          SettingRow(icon: .download, title: "Export your data", trailing: .value("CSV"))
        }
        .buttonStyle(HRowPressStyle())
        .accessibilityIdentifier("profile.export")
        row(.help, id: "profile.help") {
          SettingRow(icon: .help, title: "Get help")
        }
      }
    }
  }

  static let bankAlertsTitle = "Bank alerts"
  static let exchangeRatesTitle = "Exchange rates"

  static func mailboxesValue(_ mailboxes: [MailboxSnapshot], known: Bool) -> (text: String, tone: StatusTone?) {
    guard known else { return ("Checking", nil) }
    let live = mailboxes.filter { $0.state != .disconnected }
    if live.isEmpty { return ("Not connected", nil) }
    if live.contains(where: { $0.state == .needsSignIn }) { return ("Sign in again", .warning) }
    return (live.map(\.provider.appName).formatted(.list(type: .and)), nil)
  }

  static func archivedLine(_ n: Int) -> String {
    "\(n) kept out of your plan"
  }

  static func currencyTrailing(_ s: LedgerState) -> SettingRow.Trailing {
    let missing = ExchangeRates.page(s).missing.reduce(0) { $0 + $1.notCounted }
    return missing > 0 ? .status(ExchangeRatesPage.notCountedLine(missing), .warning) : .value(Money.home)
  }

  static func securityStatus(_ s: SecurityState) -> (text: String, tone: StatusTone) {
    if s.frozen != nil { return ("Frozen", .accent) }
    return s.hasPasskey ? ("Protected", .success) : ("Password only", .warning)
  }

  private var footer: some View {
    VStack(spacing: 8) {
      if can(.signOut) {
        Button("Sign out") { confirmSignOut = true }
          .buttonStyle(.pill(.destructiveQuiet, fill: true))
          .pillHeight()
          .accessibilityIdentifier("profile.signOut")
      }
      if can(.deleteAccount) {
        if session?.deleteWaitsForUnfreeze == true {
          Text(AccountCopy.unfreezeToDelete)
            .hType(.subheadline.weight(.semibold))
            .foregroundStyle(HColor.textSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: HSpacing.targetMinimum)
            .accessibilityIdentifier("profile.deleteFrozen")
        } else {
          Button { push(.deleteAccount) } label: {
            Text("Delete your account")
              .hType(.subheadline.weight(.medium))
              .foregroundStyle(HColor.actionDestructive)
              .frame(maxWidth: .infinity, minHeight: HSpacing.targetMinimum)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("profile.delete")
        }
      }
      Text(Self.footer(BuildInfo.current))
        .hType(.footnote)
        .foregroundStyle(HColor.textSecondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("profile.buildFooter")
    }
    .padding(.top, 4)
  }

  static func footer(_ build: BuildInfo) -> String {
    "\(build.footer) · End\u{2011}to\u{2011}end encrypted, never sold"
  }
}

private struct ProfilePage: View {
  @Bindable var app: AppModel
  let model: any ProfileModel
  let route: ProfileRoute
  @Environment(AccountSession.self) private var session: AccountSession?

  var body: some View {
    switch route {
    case .bills:
      BillsScreen(app: app)
    case .bill(let id):
      BillDetailView(app: app, bill: id)
    case .project(let id):
      ProjectDetailView(app: app, project: id)
    case .projects:
      ProjectsListView(app: app)
    case .addToProject(let id):
      ProjectAddTransactionsView(app: app, project: id)
    case .editProject(let id):
      ProjectEditorView(app: app, project: id)
    case .newProject(let starter):
      ProjectEditorView(app: app, project: nil, starter: starter)
    case .plan:
      PlanPage(app: app)
    case .category(let id):
      CategoryDetailView(app: app, category: id)
    case .rules:
      RulesPage(app: app, model: model)
    case .categories:
      RulesPage(app: app, model: model, startOn: .categories)
    case .categoryEditor(let id):
      CategoryEditorPage(app: app, category: id)
    case .categoryMove(let id):
      CategoryMovePage(app: app, category: id)
    case .notifications:
      NotificationSettingsPage(model: model)
    case .exchangeRates:
      ExchangeRatesPage(app: app)
    case .editRate(let currency):
      RateEditorPage(app: app, currency: currency)
    case .bankAlerts:
      BankAlertsPage(app: app)
    case .mailbox(let id):
      MailboxDetailPage(app: app, mailboxID: id)
    case .addMailbox:
      AddMailboxPage(app: app)
    case .connectMail(let provider):
      ConnectMailPage(app: app, provider: provider)
    case .accounts:
      AccountsView(app: app)
    case .security:
      if let session { SecurityView(session: session, app: app) }
    case .editName:
      if let session { NameEditPage(app: app, session: session) }
    case .privacy, .help:
      HelpPage()
    case .deleteAccount:
      if let session { DeleteAccountView(session: session) }
    }
  }
}

#if HASALA_MOCKS
  #Preview("Profile") {
    ProfileSheet(app: AppModel(store: InMemoryLedger()))
  }
#endif
