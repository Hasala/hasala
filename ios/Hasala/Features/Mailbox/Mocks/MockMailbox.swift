#if HASALA_MOCKS
  import Foundation
  import HasalaModels
  import Observation

  @MainActor
  @Observable
  final class MockMailbox: MailboxConnecting, UnreadableMailReporting, BankAlertsReporting, OtherBankProbing,
    SenderAddressAdding
  {
    var connectable: [MailProviderKind] = MailProviderKind.allCases {
      didSet { mailboxes.removeAll { !connectable.contains($0.provider) } }
    }
    var capabilities: MailboxCapabilities = .all
    private(set) var mailboxes: [MailboxSnapshot] = []
    var offersSampleData: Bool
    var banks: [SupportedBank] = SupportedBank.allCases
    var sortsWithModel = true
    var total = 268
    var step: Duration = .milliseconds(120)
    var connectDelay: Duration = .milliseconds(600)
    var outlookAdmin = false
    var outlookCancelled = false
    var connectRefusal: MailConnectRefusal?
    var outlookNoMailbox = false
    var gmailNoMailbox = false
    var gmailPermissionMissing = false
    var signInAgainReads: String? = MockAccountService.identity.signInAgainReads
    var switchRemoveFails = false
    var heldRemoval: MailHeldRemoval?
    var heldRemoveFails = false
    var disconnectFails = false
    var disconnectFailsFor: Set<String> = []
    private(set) var questions: [MailSwitchQuestion] = []
    var alreadyConnected = false
    var offline = false
    private(set) var connectCalls = 0
    private(set) var replacingCalls: [Bool] = []
    private(set) var signInCalls = 0
    private(set) var tryAgainCalls = 0
    private(set) var sampleLoaded = false
    var unreadableMail: [UnreadableMail] = []
    var importing: MailImport?
    @ObservationIgnored private var scanWatchers: [AsyncStream<ScanProgress>.Continuation] = []

    var firstScanFinished: Bool {
      !sampleLoaded && importing == nil && !mailboxes.contains(where: \.pastMailSkipped)
        && mailboxes.contains { $0.state == .connected }
    }

    init(offersSampleData: Bool = false, mailboxes: [MailboxSnapshot] = []) {
      self.offersSampleData = offersSampleData
      self.mailboxes = mailboxes
      if mailboxes.contains(where: { $0.id == Self.gmail.id }) { unreadableMail = MockAccountService.identity.unreadable }
    }

    func holdOneLink() {
      capabilities.remove(.addSecond)
      capabilities.insert(.replace)
      if let first = mailboxes.first(where: { $0.state != .disconnected }) {
        mailboxes.removeAll { $0.state != .disconnected && $0.id != first.id }
      }
    }

    static var gmailAddress: String { MockAccountService.identity.person.gmailAddress }
    static var outlookAddress: String { MockAccountService.identity.person.outlookAddress }
    static let workAddress = "maya@contoso.com"
    static let workAccountLine = "Couldn't connect Outlook. Only personal Microsoft accounts work. Try again."

    static var gmail: MailboxSnapshot {
      let id = MockAccountService.identity
      return MailboxSnapshot(
        id: "gmail-1", provider: .gmail, address: gmailAddress, state: .connected, meta: id.gmailMeta,
        banks: ["Emirates NBD", "Dubai Islamic Bank"], lastChecked: id.gmailLastChecked, connectedOn: "11 Sep")
    }
    static var outlook: MailboxSnapshot {
      let id = MockAccountService.identity
      return MailboxSnapshot(
        id: "outlook-1", provider: .outlook, address: outlookAddress, state: .connected, meta: id.outlookMeta,
        accountKind: id.outlookKind, banks: ["Dubai Islamic Bank"], lastChecked: "Sat 10 Oct, 12:40",
        connectedOn: id.outlookConnectedOn, note: id.outlookNote)
    }

    static let unreadable = UnreadableMail(kind: "Debit card alert", provider: .gmail, day: "Thu 8 Oct")

    static func needingSignIn(_ m: MailboxSnapshot) -> MailboxSnapshot {
      var m = m
      m.state = .needsSignIn
      m.meta = "Checked Wed"
      m.lastChecked = "Wed 7 Oct, 09:14"
      return m
    }

    private func nextAddress(_ provider: MailProviderKind) -> String? {
      let addresses = provider == .gmail ? [Self.gmailAddress, "maya.home@example.com"] : [Self.outlookAddress]
      let taken = Set(mailboxes.filter { $0.state != .disconnected }.map(\.address))
      return addresses.first { !taken.contains($0) }
    }

    var offer: MailOffer? {
      guard !sampleLoaded, connectRefusal == nil else { return nil }
      if let m = mailboxes.first(where: { $0.state == .needsSignIn }) {
        return .signInAgain(mailboxID: m.id, provider: m.provider)
      }
      return mailboxes.contains { $0.state != .disconnected } ? nil : .connect
    }

    var linkedProvider: MailProviderKind? { mailboxes.first { $0.state != .disconnected }?.provider }

    func chosenBanks() -> [SupportedBank] { banks }

    func linkState() async -> OnboardingStep.Facts.Mailbox {
      if mailboxes.contains(where: { $0.state == .syncing }) { return .scanning }
      return mailboxes.contains { $0.state == .connected || $0.state == .needsSignIn } ? .linked : .unlinked
    }

    private(set) var pastMailChoices: [MailPastChoice] = []
    private(set) var pastImports = 0

    func importPastMail(_ mailboxID: String) async -> MailPastImport {
      pastImports += 1
      guard let i = mailboxes.firstIndex(where: { $0.id == mailboxID }) else { return .notStarted }
      mailboxes[i].pastMailSkipped = false
      return .finished(total)
    }

    func connect(
      _ provider: MailProviderKind, replacing: Bool, removingOld: Bool, pastMail: MailPastChoice,
      ask: @escaping MailSwitchAsk
    ) async throws(MailConnectFailure) -> MailLinked {
      connectCalls += 1
      replacingCalls.append(replacing)
      pastMailChoices.append(pastMail)
      let linked = try await link(provider, replacing: replacing, removingOld: removingOld, ask: ask)
      if pastMail == .newOnly, let i = mailboxes.firstIndex(where: { $0.id == linked.mailboxID }) {
        mailboxes[i].pastMailSkipped = true
        mailboxes[i].state = .connected
        mailboxes[i].meta = "Checked just now"
      }
      return linked
    }

    private func link(_ provider: MailProviderKind, replacing: Bool, removingOld: Bool, ask: @escaping MailSwitchAsk)
      async throws(MailConnectFailure) -> MailLinked
    {
      var removal: MailSwitchRemoval?
      try? await Task.sleep(for: connectDelay)
      if offline { throw .offline }
      if provider == .outlook, outlookAdmin { throw .failed(Self.workAccountLine) }
      if provider == .outlook, outlookCancelled { throw .cancelled }
      if provider == .gmail, gmailPermissionMissing {
        gmailPermissionMissing = false
        throw .permissionMissing(.gmail)
      }
      if holdsOneLink {
        let live = mailboxes.filter { $0.state != .disconnected }
        if let i = mailboxes.firstIndex(where: { $0.provider == provider && $0.state == .needsSignIn }) {
          try failNoMailbox(provider)
          return try await readAgain(mailboxes[i].id, ask: ask)
        }
        if let same = live.first(where: { $0.provider == provider }) {
          throw .alreadyConnected(address: same.address)
        }
        if let other = live.first(where: { $0.provider != provider }) {
          guard replacing else {
            throw .failed("Disconnect \(other.provider.appName) first, then connect \(provider.appName).")
          }
          try failNoMailbox(provider)
          mailboxes.removeAll { $0.id == other.id }
          if removingOld { removal = remove(other.id, old: other.address) }
        }
      }
      try failNoMailbox(provider)
      guard !alreadyConnected, let address = nextAddress(provider) else {
        throw .alreadyConnected(address: provider == .gmail ? Self.gmailAddress : Self.outlookAddress)
      }
      if let i = mailboxes.firstIndex(where: { $0.provider == provider && $0.address == address && $0.state == .disconnected }) {
        mailboxes[i].state = .syncing
        mailboxes[i].meta = "Checking now"
        mailboxes[i].banks = banks.map(\.name)
        mailboxes[i].connectedOn = "10 Oct"
        mailboxes[i].pastMailSkipped = false
        mailboxes[i].note = nil
        return MailLinked(mailboxID: mailboxes[i].id, removal: removal)
      }
      let n = mailboxes.filter { $0.provider == provider }.count + 1
      let id = "\(provider.rawValue)-\(n)"
      mailboxes.append(MailboxSnapshot(
        id: id, provider: provider, address: address, state: .syncing, meta: "Checking now",
        accountKind: provider == .outlook ? "Personal Microsoft" : nil,
        banks: banks.map(\.name), connectedOn: "10 Oct"))
      return MailLinked(mailboxID: id, removal: removal)
    }

    private func remove(_ id: String, old: String) -> MailSwitchRemoval? {
      guard let impact = imported[id], impact.transactions > 0 else { return nil }
      if switchRemoveFails {
        heldRemoval = MailHeldRemoval(address: old, transactions: impact.transactions)
        heldRemovalID = id
        return .failed(from: old)
      }
      removed.append(id)
      imported[id] = nil
      return .removed(impact.transactions)
    }

    private func readAgain(_ id: String, ask: MailSwitchAsk) async throws(MailConnectFailure) -> MailLinked {
      guard let i = mailboxes.firstIndex(where: { $0.id == id }) else { throw .failed("That mailbox is gone.") }
      let old = mailboxes[i]
      var removal: MailSwitchRemoval?
      if let address = signInAgainReads, address != old.address {
        let impact = imported[id].flatMap { $0.transactions > 0 ? $0 : nil }
        let noMailbox = old.note != nil
        if !noMailbox || impact != nil {
          let question = MailSwitchQuestion(
            provider: old.provider, oldAddress: old.address, newAddress: address, impact: impact,
            oldHasNoMailbox: noMailbox)
          questions.append(question)
          switch await ask(question) {
          case .cancel: throw .switchDeclined
          case .keep: imported[id] = nil
          case .remove: removal = remove(id, old: old.address)
          }
        }
        imported[id] = nil
      }
      guard let j = mailboxes.firstIndex(where: { $0.id == id }) else { throw .failed("That mailbox is gone.") }
      mailboxes[j].state = .connected
      mailboxes[j].meta = "Checked just now"
      mailboxes[j].lastChecked = "Sat 10 Oct, 13:40"
      guard let address = signInAgainReads, address != old.address else { return MailLinked(mailboxID: id) }
      mailboxes[j].address = address
      return MailLinked(mailboxID: id, nowReading: address, removal: removal)
    }

    private func failNoMailbox(_ provider: MailProviderKind) throws(MailConnectFailure) {
      switch provider {
      case .outlook where outlookNoMailbox:
        outlookNoMailbox = false
      case .gmail where gmailNoMailbox:
        gmailNoMailbox = false
      default:
        return
      }
      throw .noMailbox(provider)
    }

    func tryAgain(_ mailboxID: String) async {
      tryAgainCalls += 1
      if let i = mailboxes.firstIndex(where: { $0.id == mailboxID }) {
        mailboxes[i].note = nil
        if mailboxes[i].state == .readingStopped { mailboxes[i].state = .connected }
      }
    }

    func signInAgain(_ mailboxID: String, ask: @escaping MailSwitchAsk) async throws(MailConnectFailure) -> MailLinked {
      signInCalls += 1
      try? await Task.sleep(for: connectDelay)
      if offline { throw .offline }
      guard let i = mailboxes.firstIndex(where: { $0.id == mailboxID }) else { throw .failed("That mailbox is gone.") }
      if mailboxes[i].provider == .outlook, outlookCancelled { throw .cancelled }
      try failNoMailbox(mailboxes[i].provider)
      return try await readAgain(mailboxID, ask: ask)
    }

    var imported: [String: MailboxDisconnectImpact] = MockAccountService.identity.impacts
    private(set) var removed: [String] = []

    @ObservationIgnored private var heldRemovalID: String?

    func removeHeld() async -> MailHeldRemovalOutcome {
      guard let held = heldRemoval, !heldRemoveFails else { return .failed }
      if let id = heldRemovalID { removed.append(id) }
      heldRemoval = nil
      heldRemovalID = nil
      return .removed(held.transactions)
    }

    func keepHeld() async {
      heldRemoval = nil
      heldRemovalID = nil
    }

    func disconnectImpact(_ mailboxID: String) async -> MailboxDisconnectImpact? {
      guard let impact = imported[mailboxID], impact.transactions > 0 else { return nil }
      return impact
    }

    func disconnect(_ mailboxID: String, removeTransactions: Bool) async throws(MailConnectFailure) {
      try? await Task.sleep(for: connectDelay)
      if disconnectFails || disconnectFailsFor.contains(mailboxID) { throw .offline }
      guard let i = mailboxes.firstIndex(where: { $0.id == mailboxID }) else { return }
      mailboxes[i].state = .disconnected
      mailboxes[i].meta = "Off since 10 Oct"
      if removeTransactions {
        removed.append(mailboxID)
        imported[mailboxID] = nil
      }
    }

    func firstScan() -> AsyncStream<ScanProgress> {
      if !mailboxes.contains(where: { $0.state == .syncing }), mailboxes.contains(where: \.pastMailSkipped) {
        return AsyncStream { continuation in
          continuation.yield(ScanProgress(phase: .finished, read: 0, total: 0))
          continuation.finish()
        }
      }
      let total = total
      let step = step
      let unproven = holdsOneLink && mailboxes.contains { $0.state == .syncing && $0.provider == .outlook }
      let dictionary = unproven ? 0 : Int(Double(total) * 0.65)
      let model = sortsWithModel && !unproven ? Int(Double(total) * 0.21) : 0
      let summary = SortSummary(
        total: total, byRules: 0, byDictionary: dictionary, byModel: model, toReview: total - dictionary - model)
      return AsyncStream { continuation in
        self.scanWatchers.append(continuation)
        guard self.scanWatchers.count == 1 else { return }
        Task {
          var read = 0
          self.importing = MailImport(state: .reading, read: 0, total: total)
          while read < total {
            try? await Task.sleep(for: step)
            read = min(total, read + 24)
            self.importing = MailImport(state: .reading, read: read, total: total)
            self.tellScanWatchers(ScanProgress(phase: read < total / 3 ? .downloading : .sorting, read: read, total: total))
          }
          self.importing = nil
          self.scanFinished()
          self.tellScanWatchers(ScanProgress(phase: .finished, read: total, total: total, summary: summary))
          self.scanWatchers.forEach { $0.finish() }
          self.scanWatchers = []
        }
      }
    }

    private func tellScanWatchers(_ progress: ScanProgress) {
      for watcher in scanWatchers { watcher.yield(progress) }
    }

    private func scanFinished() {
      for i in mailboxes.indices where mailboxes[i].state == .syncing {
        mailboxes[i].state = .connected
        mailboxes[i].meta = "Checked just now"
        mailboxes[i].lastChecked = "Sat 10 Oct, 13:40"
      }
    }

    func loadSampleData() async throws(SetupFailure) {
      try? await Task.sleep(for: .milliseconds(300))
      sampleLoaded = true
    }

    func probeOtherBanks(_ candidates: [BankCandidate]) async -> OtherBankProbe {
      guard mailboxes.contains(where: { $0.state == .connected }) else { return .notReading }
      try? await Task.sleep(for: .milliseconds(300))
      return .found(candidates.filter { $0.slug == "fab" }.map { BankHint(candidate: $0, domain: $0.domains[0]) })
    }

    var lastEmails: [SupportedBank: String] = MockAccountService.identity.lastEmails
    var monthRead = MockAccountService.identity.monthRead

    func lastEmail(_ bank: SupportedBank) -> String? {
      let read = mailboxes.contains { m in
        (m.state == .connected || m.state == .needsSignIn) && m.reads(bank)
      }
      return read ? lastEmails[bank] : nil
    }

    var readThisMonth: MonthRead? {
      mailboxes.contains { $0.state == .connected || $0.state == .needsSignIn } ? monthRead : nil
    }

    var unlistedSenders: [String] = MockAccountService.identity.unlistedSenders

    func addSenderAddress(_ typed: String, for domain: String) async -> SenderAddressOutcome {
      if offline { return .offline }
      unlistedSenders.removeAll { $0 == domain }
      return .added(typed)
    }
  }
#endif
