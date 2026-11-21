import Foundation
import HasalaModels
import Observation

@MainActor
@Observable
final class SetupMailLink: MailboxConnecting {
  @ObservationIgnored let base: MailboxConnecting
  @ObservationIgnored var isLinked: () -> Bool = { false }
  @ObservationIgnored private var made: [MailProviderKind: String] = [:]

  init(base: MailboxConnecting) {
    self.base = base
  }

  func existing(_ provider: MailProviderKind) -> String? {
    if let id = made[provider] { return id }
    let reading = base.mailboxes.filter { $0.state != .disconnected }
    if let mailbox = reading.first(where: { $0.provider == provider }) { return mailbox.id }
    if isLinked(), reading.isEmpty, provider == (base.linkedProvider ?? base.connectable.first ?? .gmail) {
      return provider.rawValue
    }
    return nil
  }

  var connectable: [MailProviderKind] { base.connectable }
  var capabilities: MailboxCapabilities { base.capabilities }
  var mailboxes: [MailboxSnapshot] { base.mailboxes }
  var offer: MailOffer? { base.offer }
  var offerKnown: Bool { base.offerKnown }
  var linkedProvider: MailProviderKind? { base.linkedProvider }
  var heldElsewhere: MailProviderKind? { base.heldElsewhere }
  var offersSampleData: Bool { base.offersSampleData }
  var connectRefusal: MailConnectRefusal? { base.connectRefusal }
  var importing: MailImport? { base.importing }
  var firstScanFinished: Bool { base.firstScanFinished }

  func chosenBanks() -> [SupportedBank] { base.chosenBanks() }
  func linkState() async -> OnboardingStep.Facts.Mailbox { await base.linkState() }

  var pastMailDays: Int { base.pastMailDays }
  func importPastMail(_ mailboxID: String) async -> MailPastImport { await base.importPastMail(mailboxID) }

  func connect(
    _ provider: MailProviderKind, replacing: Bool, removingOld: Bool, pastMail: MailPastChoice,
    ask: @escaping MailSwitchAsk
  ) async throws(MailConnectFailure) -> MailLinked {
    if let id = existing(provider) { return MailLinked(mailboxID: id) }
    let linked = try await base.connect(
      provider, replacing: replacing, removingOld: removingOld, pastMail: pastMail, ask: ask)
    made[provider] = linked.mailboxID
    return linked
  }

  func signInAgain(_ mailboxID: String, ask: @escaping MailSwitchAsk) async throws(MailConnectFailure) -> MailLinked {
    try await base.signInAgain(mailboxID, ask: ask)
  }
  func tryAgain(_ mailboxID: String) async {
    await base.tryAgain(mailboxID)
  }
  func disconnect(_ mailboxID: String, removeTransactions: Bool) async throws(MailConnectFailure) {
    try await base.disconnect(mailboxID, removeTransactions: removeTransactions)
  }
  func disconnectImpact(_ mailboxID: String) async -> MailboxDisconnectImpact? { await base.disconnectImpact(mailboxID) }
  func firstScan() -> AsyncStream<ScanProgress> { base.firstScan() }
  func loadSampleData() async throws(SetupFailure) { try await base.loadSampleData() }
}
