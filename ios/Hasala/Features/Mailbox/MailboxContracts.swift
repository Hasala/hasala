import Foundation
import HasalaModels

enum MailPastChoice: Equatable, Sendable {
  case importPast, newOnly
}

enum MailPastImport: Equatable, Sendable {
  case finished(Int)
  case later
  case notStarted
}

enum MailOffer: Hashable, Identifiable {
  case connect
  case signInAgain(mailboxID: String, provider: MailProviderKind)

  var id: String {
    switch self {
    case .connect: "connect"
    case .signInAgain(let mailboxID, _): "signIn.\(mailboxID)"
    }
  }
}

enum MailConnectRefusal: Equatable, Sendable {
  case reviewAccount
  case sampleData

  var message: String {
    switch self {
    case .reviewAccount: MailCopy.reviewAccountRefusal
    case .sampleData: MailCopy.sampleDataRefusal
    }
  }
}

enum MailConnectFailure: Error, Equatable {
  case cancelled
  case alreadyConnected(address: String)
  case takenByOtherIPhone
  case offline
  case noMailbox(MailProviderKind)
  case permissionMissing(MailProviderKind)
  case switchDeclined
  case failed(String)

  func message(for provider: MailProviderKind) -> String? {
    switch self {
    case .cancelled, .switchDeclined: nil
    case .alreadyConnected(let address): "\(address) is already connected."
    case .takenByOtherIPhone: Self.readOnOtherIPhone
    case .offline: "You're offline. Connect \(provider.appName) when you're back online."
    case .noMailbox(let account): Self.noMailboxLine(account)
    case .permissionMissing(let account): Self.permissionMissingLine(account)
    case .failed(let message): message
    }
  }

  var hasScreen: Bool {
    switch self {
    case .cancelled, .noMailbox, .permissionMissing: true
    case .alreadyConnected, .takenByOtherIPhone, .offline, .switchDeclined, .failed: false
    }
  }

  static let readOnOtherIPhone = "Your email is read on your other iPhone."

  static func permissionMissingLine(_ provider: MailProviderKind) -> String {
    switch provider {
    case .gmail: "\u{201C}View your email messages and settings\u{201D} wasn't ticked. Try again and tick it."
    case .outlook: "Mail access wasn't allowed. Try again and allow it."
    }
  }

  static func noMailboxLine(_ provider: MailProviderKind) -> String {
    switch provider {
    case .outlook:
      "This Microsoft account has no Outlook mailbox. Use the one your alerts go to, like you@outlook.com or you@hotmail.com."
    case .gmail:
      "This Google account has no Gmail. Use the one your alerts go to."
    }
  }
}

struct MailboxCapabilities: OptionSet, Sendable {
  let rawValue: Int

  static let connect = MailboxCapabilities(rawValue: 1 << 0)
  static let signInAgain = MailboxCapabilities(rawValue: 1 << 1)
  static let disconnect = MailboxCapabilities(rawValue: 1 << 2)
  static let addSecond = MailboxCapabilities(rawValue: 1 << 3)
  static let replace = MailboxCapabilities(rawValue: 1 << 4)
  static let tryAgain = MailboxCapabilities(rawValue: 1 << 5)

  static let all: MailboxCapabilities = [.connect, .signInAgain, .disconnect, .addSecond, .tryAgain]
}

@MainActor
protocol MailboxConnecting: AnyObject, Observable {
  var connectable: [MailProviderKind] { get }
  var capabilities: MailboxCapabilities { get }
  var mailboxes: [MailboxSnapshot] { get }
  var mailboxesKnown: Bool { get }
  var offer: MailOffer? { get }
  var offerKnown: Bool { get }
  var connectRefusal: MailConnectRefusal? { get }
  func chosenBanks() -> [SupportedBank]
  var linkedProvider: MailProviderKind? { get }
  var heldElsewhere: MailProviderKind? { get }
  func linkState() async -> OnboardingStep.Facts.Mailbox
  func connect(
    _ provider: MailProviderKind, replacing: Bool, removingOld: Bool, pastMail: MailPastChoice,
    ask: @escaping MailSwitchAsk
  ) async throws(MailConnectFailure) -> MailLinked
  var pastMailDays: Int { get }
  func importPastMail(_ mailboxID: String) async -> MailPastImport
  func signInAgain(_ mailboxID: String, ask: @escaping MailSwitchAsk) async throws(MailConnectFailure) -> MailLinked
  func tryAgain(_ mailboxID: String) async
  func disconnect(_ mailboxID: String, removeTransactions: Bool) async throws(MailConnectFailure)
  func disconnectImpact(_ mailboxID: String) async -> MailboxDisconnectImpact?
  var heldRemoval: MailHeldRemoval? { get }
  func removeHeld() async -> MailHeldRemovalOutcome
  func keepHeld() async
  func firstScan() -> AsyncStream<ScanProgress>
  var importing: MailImport? { get }
  var firstScanFinished: Bool { get }
  var offersSampleData: Bool { get }
  func loadSampleData() async throws(SetupFailure)
}

struct MailHeldRemoval: Equatable, Sendable {
  var address: String
  var transactions: Int?
}

enum MailHeldRemovalOutcome: Equatable, Sendable {
  case removed(Int?)
  case failed
  case readElsewhere
  case ended
}

struct MailboxDisconnectImpact: Equatable, Sendable {
  var transactions: Int
  var edited: Int
}

struct MailSwitchQuestion: Equatable, Sendable {
  var provider: MailProviderKind
  var oldAddress: String
  var newAddress: String
  var impact: MailboxDisconnectImpact?
  var oldHasNoMailbox = false
  var countUnknown = false

  var offersRemove: Bool { impact != nil || countUnknown }
}

enum MailSwitchChoice: Equatable, Sendable {
  case keep, remove, cancel
}

typealias MailSwitchAsk = @MainActor @Sendable (MailSwitchQuestion) async -> MailSwitchChoice

enum MailSwitchRemoval: Equatable, Sendable {
  case removed(Int?)
  case failed(from: String)
}

struct MailLinked: Equatable, Sendable {
  var mailboxID: String
  var nowReading: String?
  var removal: MailSwitchRemoval?

  init(mailboxID: String, nowReading: String? = nil, removal: MailSwitchRemoval? = nil) {
    self.mailboxID = mailboxID
    self.nowReading = nowReading
    self.removal = removal
  }
}

struct MailImport: Equatable, Sendable {
  enum State: Equatable, Sendable {
    case reading
    case paused
    case offline
    case stopped(String)
  }

  var state: State
  var read: Int
  var total: Int

  var label: String {
    switch state {
    case .reading: "Reading your alerts"
    case .paused: "Reading paused"
    case .offline: "Offline"
    case .stopped(let message): message
    }
  }

  var count: String? {
    guard state != .offline, total > 0 else { return nil }
    if case .stopped = state { return nil }
    return "\(MoneyFormat.count(min(read, total))) of \(MoneyFormat.count(total))"
  }

  var busy: Bool { state == .reading }

  var opensBankAlerts: Bool {
    if case .stopped = state { return true }
    return false
  }
}

extension MailboxConnecting {
  var pastMailDays: Int { 90 }

  func importPastMail(_ mailboxID: String) async -> MailPastImport { .notStarted }

  var defaultPastMail: MailPastChoice { heldElsewhere == nil ? .importPast : .newOnly }

  func connect(_ provider: MailProviderKind, replacing: Bool, removingOld: Bool, ask: @escaping MailSwitchAsk)
    async throws(MailConnectFailure) -> MailLinked
  {
    try await connect(provider, replacing: replacing, removingOld: removingOld, pastMail: defaultPastMail, ask: ask)
  }

  var importing: MailImport? { nil }

  var firstScanFinished: Bool { false }

  var heldRemoval: MailHeldRemoval? { nil }

  func removeHeld() async -> MailHeldRemovalOutcome { .failed }

  func keepHeld() async {}

  func disconnect(_ mailboxID: String) async throws(MailConnectFailure) {
    try await disconnect(mailboxID, removeTransactions: false)
  }

  var mailboxesKnown: Bool { true }

  var offerKnown: Bool { true }

  var heldElsewhere: MailProviderKind? { nil }

  var connectRefusal: MailConnectRefusal? { nil }

  var connectRefused: Bool { connectRefusal != nil }

  @discardableResult
  func connect(_ provider: MailProviderKind) async throws(MailConnectFailure) -> String {
    try await connect(provider, replacing: false)
  }

  @discardableResult
  func connect(_ provider: MailProviderKind, replacing: Bool) async throws(MailConnectFailure) -> String {
    try await connect(provider, replacing: replacing, removingOld: false, ask: { _ in .cancel }).mailboxID
  }

  @discardableResult
  func signInAgain(_ mailboxID: String) async throws(MailConnectFailure) -> MailLinked {
    try await signInAgain(mailboxID, ask: { _ in .cancel })
  }

  var holdsOneLink: Bool { capabilities.contains(.replace) && !capabilities.contains(.addSecond) }

  func replaced(by provider: MailProviderKind) -> MailboxSnapshot? {
    guard holdsOneLink else { return nil }
    return mailboxes.first { $0.state != .disconnected && !$0.readElsewhere && $0.provider != provider }
  }
}

struct MailboxesSummary: Equatable {
  var title: String
  var detail: String
  var hue: Hue
  var needsYou: Bool

  init(
    _ mailboxes: [MailboxSnapshot], health: MailboxHealth, offer: MailOffer?, known: Bool = true,
    reading: ReadingState? = nil
  ) {
    let live = mailboxes.filter { $0.state != .disconnected }
    let quietElsewhere = ReadingOnScreen.quietElsewhereLine(reading)
    let broken = live.first { $0.state == .needsSignIn }
    if !known {
      self.init(title: "Checking your email", detail: "Reading your mailbox's state.", hue: .sky, needsYou: false)
    } else if broken != nil || offer?.isSignInAgain == true {
      let working = live.filter { $0.state == .connected || $0.state == .syncing }
      var detail = broken.map { $0.note ?? "\($0.provider.company) ended access to \($0.address)." }
        ?? "Your email provider ended Hasala's access."
      if let other = working.first { detail += " Your \(other.provider.appName) still works." }
      self.init(title: "Sign in again", detail: detail, hue: .sand, needsYou: true)
    } else if live.isEmpty {
      self.init(
        title: "Your email isn't connected", detail: "Connect it to read your bank alerts.", hue: .sky,
        needsYou: offer == .connect)
    } else if health.status == .reconnect {
      let stopped = live.first { $0.state == .readingStopped } ?? live[0]
      let working = live.filter { $0.id != stopped.id && ($0.state == .connected || $0.state == .syncing) }
      var detail = "Hasala stopped reading \(stopped.address)."
      if let other = working.first { detail += " Your \(other.provider.appName) still works." }
      self.init(title: "Bank alerts stopped", detail: detail, hue: .sand, needsYou: true)
    } else if live.allSatisfy({ $0.state == .syncing }) || health.status == .importing {
      self.init(title: "Importing your bank alerts", detail: Self.lines(health) ?? "Checking now", hue: .mint,
                needsYou: false)
    } else if let quietElsewhere {
      self.init(title: "Bank alerts went quiet", detail: quietElsewhere, hue: .sand, needsYou: true)
    } else {
      self.init(title: "Bank alerts are working", detail: Self.lines(health) ?? live[0].meta, hue: .mint,
                needsYou: false)
    }
  }

  init(title: String, detail: String, hue: Hue, needsYou: Bool) {
    self.title = title
    self.detail = detail
    self.hue = hue
    self.needsYou = needsYou
  }

  private static func lines(_ health: MailboxHealth) -> String? {
    let lines = [health.lastEmail.isEmpty ? nil : "Last email \(health.lastEmail)", health.banks.isEmpty ? nil : health.banks]
      .compactMap { $0 }
    return lines.isEmpty ? nil : lines.joined(separator: "\n")
  }
}

extension MailOffer {
  var isSignInAgain: Bool {
    if case .signInAgain = self { return true }
    return false
  }
}
