import Foundation
import HasalaDesign
import HasalaModels
import Observation

struct AuthoredSetup: Equatable, Sendable {
  var banks: [SupportedBank]?
}

struct SetupDraft: Equatable, Sendable {
  var chosenBanks: Set<SupportedBank>?
  var bankRequestSent = false
  var provider: MailProviderKind?
  var source: PaymentSource?
  var authored = AuthoredSetup()
}

@MainActor
@Observable
final class SetupModel {
  private let services: AccountServices
  private let onFinished: () -> Void
  @ObservationIgnored private let firstScan: FirstScanRun
  var path: [SetupRoute] = []
  var navigationPath: [SetupRoute] {
    get { path }
    set {
      if newValue.count < path.count { failure = nil }
      path = newValue
    }
  }
  private(set) var facts: OnboardingStep.Facts
  private(set) var draft = SetupDraft()

  var choosingEmail = false
  @ObservationIgnored private let mailLink: SetupMailLink
  @ObservationIgnored private var coordinators: [MailProviderKind: MailConnectCoordinator] = [:]

  private var importStarted = false
  private var didResume = false
  private var left = false

  var busy = false
  private(set) var connecting = false
  var connectRequest: MailProviderKind?
  @ObservationIgnored private var connectAfterChoosing: MailProviderKind?
  var failure: SetupFailure?
  var displayName: String

  init(services: AccountServices, displayName: String, facts: OnboardingStep.Facts,
       firstScan: FirstScanRun = FirstScanRun(), onFinished: @escaping () -> Void) {
    self.services = services
    self.firstScan = firstScan
    self.displayName = displayName
    self.facts = facts
    self.onFinished = onFinished
    mailLink = SetupMailLink(base: services.mailbox)
    mailLink.isLinked = { [weak self] in self?.mailConnected ?? false }
  }

  var step: OnboardingStep { OnboardingStep.derive(facts) }

  var chosenBanks: Set<SupportedBank> {
    get { draft.chosenBanks ?? Set(SupportedBank.allCases) }
    set { draft.chosenBanks = newValue }
  }
  var bankRequestSent: Bool { draft.bankRequestSent }

  var provider: MailProviderKind {
    draft.provider ?? readingMailbox?.provider ?? services.mailbox.linkedProvider ?? services.mailbox.connectable.first
      ?? .gmail
  }

  var connectable: [MailProviderKind] { services.mailbox.connectable }

  private var readingMailbox: MailboxSnapshot? {
    let reading = services.mailbox.mailboxes.filter { $0.state != .disconnected }
    if let provider = draft.provider, let m = reading.first(where: { $0.provider == provider }) { return m }
    return reading.first
  }

  func reconcile(facts new: OnboardingStep.Facts, banks: [SupportedBank]) {
    facts.hasPasscode = new.hasPasscode
    facts.hasSession = facts.hasSession || new.hasSession
    facts.keysReady = facts.keysReady || new.keysReady
    facts.banksChosen = facts.banksChosen || new.banksChosen || draft.authored.banks != nil
    facts.sampleLoaded = facts.sampleLoaded || new.sampleLoaded
    facts.textsChosen = facts.textsChosen || new.textsChosen
    facts.mailbox = new.mailbox
    if draft.chosenBanks == nil, !banks.isEmpty { draft.chosenBanks = Set(banks) }
    if draft.authored.banks == nil, new.banksChosen, !banks.isEmpty { draft.authored.banks = banks }
  }

  func resume() {
    if facts.mailbox == .scanning, !facts.sampleLoaded { startImport() }
    guard !didResume, step == .finished else { return }
    didResume = true
    finish()
  }

  func back() {
    failure = nil
    if !path.isEmpty { path.removeLast() }
  }

  private func go(_ r: SetupRoute) {
    failure = nil
    path.append(r)
  }

  var orderedBanks: [SupportedBank] { SupportedBank.allCases.filter { chosenBanks.contains($0) } }

  var bankList: String { orderedBanks.map(\.shortName).formatted(.list(type: .and)) }

  static func banksSummary(_ count: Int) -> String {
    count == 0 ? "None picked" : "\(count) picked"
  }

  func toggle(_ bank: SupportedBank) {
    var banks = chosenBanks
    if banks.contains(bank) { banks.remove(bank) } else { banks.insert(bank) }
    chosenBanks = banks
  }

  func saveBanks() async -> Bool {
    guard !chosenBanks.isEmpty, !busy else { return false }
    didResume = true
    let banks = orderedBanks
    if draft.authored.banks != banks {
      busy = true
      defer { busy = false }
      do {
        if draft.authored.banks == nil {
          try await services.setup.chooseBanks(banks)
        } else {
          try await services.setup.setBanks(banks)
        }
        draft.authored.banks = banks
      } catch {
        failure = error
        return false
      }
    }
    facts.banksChosen = true
    return true
  }

  func continueWithBanks() async {
    guard await saveBanks() else { return }
    if mailConnected {
      continueConnected()
    } else {
      await connectMail(provider)
    }
  }

  func skipBanks() {
    guard !busy, !connectBusy else { return }
    facts.bankSkipped = true
    finish()
  }

  var bankRequests: SetupAuthoring { services.setup }

  func noteBankRequestSent() { draft.bankRequestSent = true }

  var bankTexts: (any BankTextsConnecting)? { services.bankTexts }

  var offersBankTexts: Bool { bankTexts != nil && !offersSampleData && !mailConnected && bankTexts?.readsEmail != true }

  var readsBankEmailNote: String? {
    guard bankTexts?.readsEmail == true, source != .email else { return nil }
    return SourceSwitch.textsBlocker(services.mailbox, texts: bankTexts) == nil
      ? BankTexts.setupReadsEmail : BankTexts.setupReadsEmailElsewhere
  }

  var bankStepSubtitle: String {
    let reads = "Hasala reads your banks' alert emails"
    return bankTexts == nil ? "\(reads), not SMS." : "\(reads)."
  }

  var connectBusy: Bool { connecting || coordinators.values.contains(where: \.busy) }

  var asksSource: Bool { offersBankTexts && draft.source != .email }

  var source: PaymentSource? { draft.source }

  private(set) var lastPickedSource: PaymentSource?

  func chooseSource(_ source: PaymentSource) {
    guard !busy, !connectBusy, bankTexts != nil else { return }
    didResume = true
    failure = nil
    lastPickedSource = source
    draft.source = source
    switch source {
    case .email:
      path = []
    case .texts:
      path = []
      go(.textsSetUp)
    }
  }

  func backToSourceChoice() {
    guard !busy, !connectBusy else { return }
    failure = nil
    draft.source = nil
  }

  func skipSource() {
    guard !busy, !connectBusy else { return }
    draft.source = nil
    skipBanks()
  }

  func sendTestText() {
    guard path.last != .textsTest else { return }
    do {
      try bankTexts?.startTest()
    } catch {
      failure = .failed(error.message)
      return
    }
    go(.textsTest)
  }

  func finishTexts() async {
    guard !busy, let lane = bankTexts else { return }
    didResume = true
    failure = nil
    busy = true
    defer { busy = false }
    do {
      try await lane.finishSetUp()
    } catch {
      failure = .failed(error.message)
      return
    }
    facts.textsChosen = true
    finish()
  }

  var offersSampleData: Bool { services.mailbox.offersSampleData }

  var mailConnected: Bool { facts.mailbox != .unlinked }

  var connectedMailbox: MailboxSnapshot? { mailConnected ? readingMailbox : nil }

  var mailbox: MailboxConnecting { services.mailbox }

  var canChooseEmail: Bool { connectable.count > 1 }

  func chooseEmail() {
    guard canChooseEmail else { return }
    choosingEmail = true
  }

  func pickProvider(_ provider: MailProviderKind) {
    draft.provider = provider
    choosingEmail = false
    failure = nil
    if case .failed? = coordinators[provider]?.outcome { coordinators[provider]?.reset() }
    path = Array(path.prefix { !$0.isEmailStep })
  }

  func swapProvider(_ provider: MailProviderKind) {
    guard !busy, !connectBusy, !mailConnected, connectable.contains(provider) else { return }
    draft.provider = provider
    failure = nil
  }

  func useBankTextsInstead() {
    guard offersBankTexts, !busy, !connectBusy else { return }
    path = []
    backToSourceChoice()
  }

  func choose(_ provider: MailProviderKind) {
    pickProvider(provider)
    connectAfterChoosing = provider
  }

  func choosingEnded() {
    guard let provider = connectAfterChoosing else { return }
    connectAfterChoosing = nil
    connectRequest = provider
  }

  func coordinator(_ provider: MailProviderKind) -> MailConnectCoordinator {
    if let c = coordinators[provider] { return c }
    let c = MailConnectCoordinator(mailbox: mailLink, context: .setup(stepOf: nil))
    coordinators[provider] = c
    return c
  }

  func connectFailure(_ provider: MailProviderKind) -> MailConnectFailure? {
    if case .failed(let f)? = coordinators[provider]?.outcome { return f }
    return nil
  }

  func connectMail(_ provider: MailProviderKind, replacing: Bool = false, removingOld: Bool = false) async {
    await runConnect(provider, again: false, replacing: replacing, removingOld: removingOld)
  }

  private func runConnect(_ provider: MailProviderKind, again: Bool, replacing: Bool = false,
                          removingOld: Bool = false) async {
    guard !connecting else { return }
    connecting = true
    defer { connecting = false }
    let before = connectedMailbox
    draft.provider = provider
    failure = nil
    if again {
      await coordinator(provider).retry(provider)
    } else {
      await coordinator(provider).connect(provider, replacing: replacing, removingOld: removingOld)
    }
    switch coordinators[provider]?.outcome {
    case .connected(let id)?:
      let now = coordinators[provider]?.nowReading ?? connectedMailbox?.address
      emailConnected(provider, fresh: before.map { $0.id != id || $0.address != now } ?? false)
    case .failed?: connectFailed(provider)
    case nil: break
    }
  }

  func retryConnect(_ provider: MailProviderKind) async {
    await runConnect(provider, again: true)
  }

  func continueConnected() {
    guard path.isEmpty else { return }
    emailConnected(provider)
  }

  private func emailConnected(_ provider: MailProviderKind, fresh: Bool = false) {
    if path.last == .connectError(provider) { path.removeLast() }
    if fresh {
      importStarted = false
      facts.mailbox = .unlinked
    }
    if facts.mailbox == .unlinked {
      draft.provider = provider
      facts.mailSkipped = false
      facts.mailbox = .scanning
      startImport(again: fresh)
    }
    if let line = coordinators[provider]?.takeRemovalFailure() {
      failure = .failed(line)
      return
    }
    finish()
  }

  func connectFailed(_ provider: MailProviderKind) {
    guard let f = connectFailure(provider) else { return }
    if Self.showsErrorScreen(f), path.last != .connectError(provider) { go(.connectError(provider)) }
    failure = Self.setupFailure(f, provider)
  }

  static func showsErrorScreen(_ f: MailConnectFailure) -> Bool { f.hasScreen }

  static func setupFailure(_ f: MailConnectFailure, _ provider: MailProviderKind) -> SetupFailure {
    switch f {
    case .cancelled: .cancelled
    default: .failed(f.message(for: provider) ?? "")
    }
  }

  func skipMail() {
    facts.mailSkipped = true
    finish()
  }

  func useSampleData() async {
    guard !busy else { return }
    didResume = true
    busy = true
    defer { busy = false }
    do {
      try await services.mailbox.loadSampleData()
      facts.sampleLoaded = true
      finish()
    } catch {
      failure = error
    }
  }

  private func startImport(again: Bool = false) {
    guard !importStarted else { return }
    importStarted = true
    firstScan.start(services.mailbox, again: again)
  }

  func finish() {
    guard !left else { return }
    left = true
    didResume = true
    onFinished()
  }
}

extension SetupRoute {
  var isEmailStep: Bool {
    if case .connectError = self { return true }
    return false
  }
}
