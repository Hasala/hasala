import HasalaDesign
import HasalaModels
import SwiftUI

struct BankAlertsPage: View {
  @Bindable var app: AppModel
  @State private var known: Set<String>?
  @State private var arriving: String?
  @State private var visible = false
  @State private var signIn: MailConnectCoordinator?
  @State private var retrying = false
  @State private var successes = 0
  @State private var transition = TransitionEnd()
  @State private var changingBanks = false
  @State private var requestingBank = false
  @State private var bankRequests: [RequestedBank] = []
  @State private var addingSender: UnlistedSender?
  @State private var guidingTexts = false
  @Environment(AccountSession.self) private var session: AccountSession?
  @Environment(\.hMotion) private var motion

  init(app: AppModel) {
    self.app = app
    _arriving = State(initialValue: MailboxMoment.pendingAddition)
  }

  private var lane: (any MailboxConnecting)? { app.mailbox }
  private var mailboxes: [MailboxSnapshot] { lane?.mailboxes ?? [] }
  private var reporting: BankAlertsReporting? { lane as? BankAlertsReporting }
  private var stateKnown: Bool { lane?.mailboxesKnown ?? true }

  var body: some View {
    Group {
      if let texts = app.bankTexts, texts.usesTexts {
        BankTextsAlertsPage(app: app, lane: texts, guiding: $guidingTexts)
      } else {
        mailBody
      }
    }
    .sheet(isPresented: $guidingTexts) { ShortcutsGuideSheet(install: BankTexts.offeredInstall(app.bankTexts)) }
  }

  @ViewBuilder private var mailBody: some View {
    let health = app.store.state.mailbox
    let summary = MailboxesSummary(
      mailboxes, health: health, offer: app.mailOffer, known: stateKnown, reading: app.store.state.reading)
    let hero = Hero(
      summary: summary, health: health, mailboxes: mailboxes, offer: app.mailOffer, read: reporting?.readThisMonth,
      known: stateKnown, reading: app.store.state.reading)
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        heroCard(hero)
        mailboxesSection
        banksSection
        unlistedSection
        needsALook
        howItReads
        if let texts = app.bankTexts {
          UseBankTextsSection(app: app, lane: texts, guiding: $guidingTexts)
        }
      }
      .padding(.horizontal, HSpacing.insetPage)
      .padding(.top, 8)
      .padding(.bottom, 48)
      .hAnimation(.stateSwap, value: hero)
    }
    .background(HColor.surfaceSecondary)
    .background(TransitionProbe(signal: transition))
    .navigationTitle("Bank alerts")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      visible = true
      noteRows(mailboxes.map(\.id))
      takeMoment()
      if let arriving { land(arriving) }
    }
    .onDisappear {
      visible = false
      transition.left()
    }
    .sheet(isPresented: $changingBanks) {
      ManageBanksSheet(current: lane?.chosenBanks() ?? []) { app.say("Banks updated") }
    }
    .sheet(isPresented: $requestingBank, onDismiss: { Task { await loadBankRequests() } }) {
      RequestBankSheet(setup: session?.services.setup, prober: lane as? OtherBankProbing) { _ in app.say("Request sent") }
    }
    .sheet(item: $addingSender) { sender in
      if let adder = lane as? SenderAddressAdding {
        AddSenderAddressSheet(domain: sender.domain, adder: adder) { app.say("Hasala now reads \($0)") }
      }
    }
    .task { await loadBankRequests() }
    .onChange(of: mailboxes.map(\.id)) { _, ids in noteRows(ids) }
    .hHaptic(.success, trigger: successes) { old, new in new > old }
  }

  struct Hero: Equatable {
    enum Kind: Equatable {
      case working, importing, needsYou, notConnected
      case checking
      case signInAgain(mailboxID: String, provider: MailProviderKind)
      case stopped(mailboxID: String)
    }

    let kind: Kind
    let detail: String

    init(
      summary: MailboxesSummary, health: MailboxHealth, mailboxes: [MailboxSnapshot], offer: MailOffer?,
      read: MonthRead? = nil, known: Bool = true, reading: ReadingState? = nil
    ) {
      let live = mailboxes.filter { $0.state != .disconnected }
      if !known {
        kind = .checking
      } else if case .signInAgain(let id, let provider)? = offer {
        kind = .signInAgain(mailboxID: id, provider: provider)
      } else if let broken = live.first(where: { $0.state == .needsSignIn }) {
        kind = .signInAgain(mailboxID: broken.id, provider: broken.provider)
      } else if live.isEmpty {
        kind = .notConnected
      } else if let stopped = live.first(where: { $0.state == .readingStopped && !$0.readElsewhere }) {
        kind = .stopped(mailboxID: stopped.id)
      } else if summary.needsYou {
        kind = .needsYou
      } else if live.allSatisfy({ $0.state == .syncing }) || health.status == .importing {
        kind = .importing
      } else {
        kind = .working
      }
      switch kind {
      case .notConnected:
        detail = "Add a mailbox for your bank alerts."
      case .checking:
        detail = summary.detail
      case .signInAgain(let id, _):
        detail = Self.signInDetail(live.first { $0.id == id }, live: live) ?? summary.detail
      case .stopped(let id):
        detail = Self.stoppedDetail(live.first { $0.id == id }, live: live, reading: reading) ?? summary.detail
      case .working where !health.lastEmail.isEmpty:
        detail = ["Last email \(health.lastEmail)", read?.line ?? (health.banks.isEmpty ? nil : health.banks)]
          .compactMap { $0 }.joined(separator: "\n")
      default:
        detail = summary.detail
      }
    }

    static func signInDetail(_ broken: MailboxSnapshot?, live: [MailboxSnapshot]) -> String? {
      guard let broken else { return nil }
      if let note = broken.note { return note }
      var detail = "\(broken.provider.company) ended access to \(broken.address)"
      if let day = broken.lastChecked?.split(separator: ",").first {
        detail += " on " + day.replacingOccurrences(of: " ", with: "\u{00A0}")
      }
      detail += "."
      let working = live.first { $0.id != broken.id && ($0.state == .connected || $0.state == .syncing) }
      if let working { detail += " Your \(working.provider.appName) still works." }
      return detail
    }

    static func stoppedDetail(_ stopped: MailboxSnapshot?, live: [MailboxSnapshot], reading: ReadingState?) -> String? {
      guard let stopped else { return nil }
      var detail = "Hasala stopped reading \(stopped.address)"
      if let reading, case .stopped(_, let since?) = reading.kind {
        detail += since == reading.today
          ? " today" : " on " + ReadingOnScreen.named(since, today: reading.today).replacingOccurrences(of: " ", with: "\u{00A0}")
      }
      detail += "."
      let working = live.first { $0.id != stopped.id && ($0.state == .connected || $0.state == .syncing) }
      if let working { detail += " Your \(working.provider.appName) still works." }
      return detail
    }

    static let stoppedTotals =
      "Payments since then aren't counted, and a new sign-in won't fix it. If Try again doesn't help, email support@hasala.app."

    var totalsLine: String? {
      if case .stopped = kind { return Self.stoppedTotals }
      return nil
    }

    var title: String {
      switch kind {
      case .working: "Working"
      case .importing: "Importing"
      case .needsYou: "Needs you"
      case .notConnected: "Not connected"
      case .checking: "Checking"
      case .signInAgain: "Sign in again"
      case .stopped: "Bank alerts stopped"
      }
    }

    var hue: Hue {
      switch kind {
      case .working, .importing: .mint
      case .needsYou, .signInAgain, .stopped: .sand
      case .notConnected, .checking: .sky
      }
    }

    var glyph: [PaperGlyph.Part]? {
      switch kind {
      case .working, .importing: PaperGlyph.check
      case .needsYou, .signInAgain, .stopped: PaperGlyph.alert
      case .notConnected, .checking: nil
      }
    }
  }

  @Environment(\.dynamicTypeSize) private var typeSize

  private func heroCard(_ hero: Hero) -> some View {
    let layout = typeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
      : AnyLayout(HStackLayout(alignment: .center, spacing: 16))
    return VStack(alignment: .leading, spacing: 16) {
      layout {
        Circle().fill(HColor.posterGlyph).frame(width: 56, height: 56)
          .overlay {
            if let glyph = hero.glyph {
              PaperGlyph(glyph, size: 26, color: hero.hue.ink, lineWidth: 2.4)
            } else {
              HIconView(.envelope, size: 26, color: hero.hue.ink, strokeWidth: 2.2)
            }
          }
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(hero.title).hType(.title1).foregroundStyle(hero.hue.ink)
          Text(hero.detail).hType(.subheadline).foregroundStyle(HColor.textOnHueSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Bank alerts: \(hero.title). \(hero.detail.replacingOccurrences(of: "\n", with: ". "))")
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("bankAlerts.status")
      }
      if let totals = hero.totalsLine {
        Text(totals).hType(.subheadline).foregroundStyle(HColor.textOnHueSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("bankAlerts.totals")
      }
      if case .signInAgain(let id, let provider) = hero.kind, lane?.capabilities.contains(.signInAgain) == true,
         lane?.connectRefused != true {
        ProviderButton(provider: provider, loading: signIn?.busy ?? false) { signInAgain(id, provider) }
          .accessibilityIdentifier("bankAlerts.signInAgain")
        if let message = signIn?.failureLine {
          InlineStatus(tone: .warning, text: message, size: .regular)
            .hTransition(.rise)
        }
      }
      if case .stopped(let id) = hero.kind, lane?.capabilities.contains(.tryAgain) == true {
        Button("Try again") { tryAgain(id) }
          .buttonStyle(.pill(.primary, size: .large, fill: true, loading: retrying))
          .disabled(retrying)
          .accessibilityIdentifier("bankAlerts.tryAgain")
      }
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(hero.hue.perceptualGradient, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("bankAlerts.hero")
    .mailSwitchQuestion(signIn)
  }

  private func tryAgain(_ id: String) {
    guard let lane, !retrying else { return }
    retrying = true
    Task {
      await lane.tryAgain(id)
      retrying = false
    }
  }

  private func signInAgain(_ id: String, _ provider: MailProviderKind) {
    guard let lane else { return }
    let attempt = MailConnectCoordinator(mailbox: lane, context: .signInAgain(mailboxID: id))
    let policy = motion
    signIn = attempt
    Task {
      await attempt.connect(provider)
      if attempt.failedWithNoMailbox {
        signIn = nil
        MailConnectCoordinator.hand(attempt, to: app.router)
      } else if let line = attempt.signedInAgainLine {
        app.say(line)
        signIn = nil
        try? await Task.sleep(for: policy.settleDelay(.stateSwap))
        successes += 1
      }
    }
  }

  private var mailboxesSection: some View {
    VStack(alignment: .leading, spacing: 12) {
      HSectionHeader("Mailboxes")
      if !stateKnown {
        HListCard {
          HStack(spacing: HSpacing.listRowGap) {
            ProgressView()
              .frame(width: 40, height: 40)
            Text("Checking your mailbox")
              .hType(.rowTitle).foregroundStyle(HColor.textSecondary)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .padding(.horizontal, HSpacing.listRowInsetInline)
          .padding(.vertical, HSpacing.listRowInsetBlock)
          .frame(minHeight: HSpacing.listRowMinHeightTwoLine)
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier("bankAlerts.mailboxes.checking")
        }
      } else if !mailboxes.isEmpty || offersAdd || offersChange {
        HListCard {
          ForEach(Array(mailboxes.enumerated()), id: \.element.id) { i, m in
            if i > 0 { HDivider(inset: .disc68) }
            Button { app.router.profile.append(.mailbox(m.id)) } label: { landing(m) }
              .buttonStyle(HRowPressStyle())
              .accessibilityIdentifier("bankAlerts.mailbox.\(m.id)")
          }
          if offersAdd {
            if !mailboxes.isEmpty { HDivider(inset: .disc68) }
            MailActionRow(title: "Add a mailbox", identifier: "bankAlerts.addMailbox") {
              app.router.profile.append(.addMailbox)
            }
          } else if offersChange {
            HDivider(inset: .disc68)
            MailActionRow(title: "Use another email", identifier: "bankAlerts.changeMailbox", icon: .envelope) {
              app.router.profile.append(.addMailbox)
            }
          }
        }
        .hAnimation(.stateSwap, value: mailboxes.map(\.state))
      } else if let refusal = lane?.connectRefusal {
        InlineStatus(tone: .warning, text: refusal.message, size: .regular)
          .accessibilityIdentifier("bankAlerts.connectRefused")
      } else {
        HListCard {
          Text("No mailbox connected")
            .hType(.rowTitle).foregroundStyle(HColor.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, HSpacing.listRowInsetInline)
            .padding(.vertical, HSpacing.listRowInsetBlock)
            .frame(minHeight: HSpacing.listRowMinHeightTwoLine)
            .accessibilityIdentifier("bankAlerts.mailboxes.none")
        }
      }
      Text(MailCopy.mailboxesFootnote)
        .hType(.footnote)
        .foregroundStyle(HColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .infoTip(MailCopy.mailboxesFootnoteDetail, about: "what our server sees")
        .padding(.horizontal, 16)
    }
  }

  private func landing(_ m: MailboxSnapshot) -> some View {
    let pending = arriving == m.id
    return MailboxRow(m)
      .opacity(pending ? 0 : 1)
      .offset(y: pending && !motion.isStill ? HMotion.travelRise : 0)
      .scaleEffect(pending && !motion.isStill ? HMotion.dealScale : 1)
  }

  private var offersAdd: Bool {
    guard let lane, stateKnown, !lane.connectRefused, lane.capabilities.contains(.connect), !lane.connectable.isEmpty
    else { return false }
    return lane.capabilities.contains(.addSecond) || !mailboxes.contains { $0.state != .disconnected }
  }

  private var offersChange: Bool {
    guard let lane, !lane.connectRefused, !offersAdd, lane.holdsOneLink, lane.capabilities.contains(.connect) else {
      return false
    }
    guard !mailboxes.contains(where: \.readElsewhere) else { return false }
    let linked = Set(mailboxes.filter { $0.state != .disconnected }.map(\.provider))
    return !linked.isEmpty && lane.connectable.contains { !linked.contains($0) }
  }

  private func noteRows(_ ids: [String]) {
    defer { known = Set(ids) }
    guard let known, let new = ids.first(where: { !known.contains($0) }) else { return }
    arriving = new
    if visible { land(new) }
  }

  private func land(_ id: String) {
    let policy = motion
    transition.afterArrival(immediately: policy.settled) {
      guard arriving == id else { return }
      withHMotion(.celebrate, policy) { arriving = nil }
      Task {
        try? await Task.sleep(for: policy.settleDelay(.celebrate))
        successes += 1
      }
    }
  }

  private func takeMoment() {
    switch MailboxMoment.take() {
    case .added(let id)?:
      if mailboxes.contains(where: { $0.id == id }) {
        arriving = id
      } else if arriving == id {
        arriving = nil
      }
    case .signedInAgain?:
      transition.afterArrival(immediately: motion.settled) { successes += 1 }
    case nil:
      break
    }
  }

  @ViewBuilder private var banksSection: some View {
    let banks = lane?.chosenBanks() ?? []
    if lane != nil {
      VStack(alignment: .leading, spacing: 12) {
        HSectionHeader("Banks")
        HListCard {
          let checking = mailboxes.contains { $0.state == .syncing }
          ForEach(Array(banks.enumerated()), id: \.element) { i, bank in
            if i > 0 { HDivider(inset: .disc68) }
            BankAlertsBankRow(
              bank: bank, detail: Self.bankDetail(bank, lastEmail: reporting?.lastEmail(bank), checking: checking))
              .accessibilityIdentifier("bankAlerts.bank.\(bank.rawValue)")
          }
          if !banks.isEmpty { HDivider(inset: .disc68) }
          MailActionRow(
            title: banks.isEmpty ? "Choose your banks" : "Change banks", identifier: "bankAlerts.changeBanks",
            icon: banks.isEmpty ? nil : .pencil
          ) { changingBanks = true }
          if session != nil {
            HDivider(inset: .disc68)
            MailActionRow(title: "My bank isn't listed", identifier: "bankAlerts.requestBank") { requestingBank = true }
          }
        }
        if !bankRequests.isEmpty { RequestedBanksCard(requests: bankRequests).padding(.top, 12) }
      }
    }
  }

  private func loadBankRequests() async {
    guard let setup = session?.services.setup, let s = try? await setup.bankRequests() else { return }
    bankRequests = s.requests
  }

  static func bankDetail(_ bank: SupportedBank, lastEmail: String?, checking: Bool) -> String {
    let when = lastEmail.map { "Last email \($0)" } ?? (checking ? "Checking now" : "No alerts read yet")
    return bank == .dib ? "\(when) · Arabic alerts" : when
  }

  struct UnlistedSender: Identifiable, Hashable {
    let domain: String
    var id: String { domain }
  }

  static let unlistedDetail = "Add the address it sends from."

  @ViewBuilder private var unlistedSection: some View {
    let domains = (lane as? SenderAddressAdding)?.unlistedSenders ?? []
    if !domains.isEmpty {
      VStack(alignment: .leading, spacing: 12) {
        HSectionHeader("Not read on Outlook")
        HListCard {
          ForEach(Array(domains.enumerated()), id: \.element) { i, domain in
            if i > 0 { HDivider(inset: .disc68) }
            Button { addingSender = UnlistedSender(domain: domain) } label: { unlistedRow(domain) }
              .buttonStyle(HRowPressStyle())
              .accessibilityIdentifier("bankAlerts.unlisted.\(domain)")
          }
        }
      }
    }
  }

  private var warningDisc: some View {
    Circle().fill(HColor.statusWarningSurface).frame(width: 40, height: 40)
      .overlay { HIconView(.envelope, size: 20, color: HColor.statusWarningForeground, strokeWidth: 1.9) }
  }

  private func unlistedRow(_ domain: String) -> some View {
    HStack(spacing: HSpacing.listRowGap) {
      warningDisc
      VStack(alignment: .leading, spacing: 2) {
        Text(domain).hType(.rowTitle).foregroundStyle(HColor.textPrimary)
        Text(Self.unlistedDetail).hType(.footnote).foregroundStyle(HColor.listRowSupporting)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      HIconView(.chevronRight, size: HSpacing.iconSmall, color: HColor.listRowChevron)
    }
    .padding(.horizontal, HSpacing.listRowInsetInline)
    .padding(.vertical, HSpacing.listRowInsetBlock)
    .frame(minHeight: HSpacing.listRowMinHeightTwoLine)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder private var needsALook: some View {
    let unreadable = (lane as? UnreadableMailReporting)?.unreadableMail ?? []
    let count = max(unreadable.count, app.store.state.mailbox.unreadable)
    let held = lane?.heldRemoval
    if count > 0 || held != nil {
      let target = Self.unreadableTarget(listed: !app.store.state.unreadMail.isEmpty)
      VStack(alignment: .leading, spacing: 12) {
        HSectionHeader("Needs a look")
        HListCard {
          if let held, let lane {
            HeldRemovalRow(app: app, lane: lane, held: held)
            if count > 0 { HDivider(inset: .disc68) }
          }
          if count > 0 {
            Button {
              open(target)
            } label: {
              unreadableRow(count, detail: target.detail, chevron: true)
            }
            .buttonStyle(HRowPressStyle())
            .accessibilityHint(target == .addTransaction ? "Opens Add a transaction" : "")
            .accessibilityIdentifier("bankAlerts.unreadable")
          }
        }
      }
    }
  }

  enum UnreadableTarget: Equatable {
    case bankEmails
    case addTransaction

    var detail: String {
      switch self {
      case .bankEmails: "Add each one by hand or dismiss it"
      case .addTransaction: "Add it yourself from your bank app"
      }
    }
  }

  static func unreadableTarget(listed: Bool) -> UnreadableTarget { listed ? .bankEmails : .addTransaction }

  private func open(_ target: UnreadableTarget) {
    let router = app.router
    switch target {
    case .bankEmails:
      router.sheet = nil
      router.tab = .review
      router.review = [.unreadMail]
    case .addTransaction:
      router.open(.addTransaction)
    }
  }

  static func unreadableLine(_ n: Int) -> String {
    n == 1 ? "1 email Hasala couldn't read" : "\(MoneyFormat.count(n)) emails Hasala couldn't read"
  }

  private func unreadableRow(_ count: Int, detail: String, chevron: Bool) -> some View {
    HStack(spacing: HSpacing.listRowGap) {
      warningDisc
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 7) {
          Circle().fill(HColor.paceFillOverPace).frame(width: 8, height: 8)
          Text(Self.unreadableLine(count))
            .hType(.rowTitle).foregroundStyle(HColor.textPrimary)
        }
        Text(detail)
          .hType(.footnote).foregroundStyle(HColor.listRowSupporting)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if chevron {
        HIconView(.chevronRight, size: HSpacing.iconSmall, color: HColor.listRowChevron)
      }
    }
    .padding(.horizontal, HSpacing.listRowInsetInline)
    .padding(.vertical, HSpacing.listRowInsetBlock)
    .frame(minHeight: HSpacing.listRowMinHeightTwoLine)
    .contentShape(Rectangle())
  }

  private var howItReads: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("How Hasala reads your email").hType(.body.weight(.semibold)).foregroundStyle(HColor.textPrimary)
        .accessibilityAddTraits(.isHeader)
      readsRow(icon: .envelope, "Your iPhone asks your mail provider only for your banks' alerts.")
      readsRow(PaperGlyph.eyeOff, "The rest of your inbox, headers included, is never downloaded.")
      readsRow(PaperGlyph.link, "Alert text stays with each transaction and syncs only end\u{2011}to\u{2011}end encrypted.")
    }
    .padding(.top, 18)
    .padding([.horizontal, .bottom], 20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.tile, style: .continuous))
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("bankAlerts.howItReads")
  }

  private func readsRow(icon: HIcon, _ text: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      HIconView(icon, size: 22, color: HColor.iconPrimary, strokeWidth: 1.8).accessibilityHidden(true)
      Text(text).hType(.subheadline).foregroundStyle(HColor.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func readsRow(_ glyph: [PaperGlyph.Part], _ text: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      PaperGlyph(glyph, size: 22, color: HColor.iconPrimary, lineWidth: 1.8)
      Text(text).hType(.subheadline).foregroundStyle(HColor.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

@MainActor
protocol UnreadableMailReporting {
  var unreadableMail: [UnreadableMail] { get }
}

@MainActor
protocol BankAlertsReporting {
  func lastEmail(_ bank: SupportedBank) -> String?
  var readThisMonth: MonthRead? { get }
}

struct MonthRead: Hashable, Sendable {
  var count: Int
  var month: String

  var line: String { "\(MoneyFormat.count(count)) read in \(month)" }
}

struct UnreadableMail: Hashable, Sendable {
  var kind: String
  var provider: MailProviderKind
  var day: String
}

extension MailConnectCoordinator {
  var failureLine: String? {
    guard case .failed(let failure)? = outcome, let provider else { return nil }
    if case .cancelled = failure { return "\(provider.company) sign-in didn't finish. Nothing changed." }
    return failure.message(for: provider)
  }
}
