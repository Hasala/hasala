public enum MailProviderKind: String, CaseIterable, Sendable, Identifiable, Codable {
  case gmail
  case outlook

  public var id: String { rawValue }

  public var appName: String {
    switch self {
    case .gmail: "Gmail"
    case .outlook: "Outlook"
    }
  }

  public var company: String {
    switch self {
    case .gmail: "Google"
    case .outlook: "Microsoft"
    }
  }

  public var continueTitle: String { "Continue with \(company)" }

  public var chooserSubtitle: String {
    switch self {
    case .gmail: "Any Google account"
    case .outlook: "Outlook.com, Hotmail or Live"
    }
  }

  public var access: String {
    switch self {
    case .gmail: "Read-only mail"
    case .outlook: "Read-only, through Microsoft"
    }
  }
}

public enum MailboxState: Hashable, Sendable {
  case syncing
  case connected
  case needsSignIn
  case readingStopped
  case disconnected
}

public struct MailboxSnapshot: Identifiable, Hashable, Sendable {
  public var id: String
  public var provider: MailProviderKind
  public var address: String
  public var state: MailboxState
  public var meta: String
  public var accountKind: String?
  public var banks: [String]
  public var lastChecked: String?
  public var connectedOn: String?
  public var note: String?
  public var readElsewhere: Bool
  public var pastMailSkipped: Bool

  public init(
    id: String, provider: MailProviderKind, address: String, state: MailboxState, meta: String,
    accountKind: String? = nil, banks: [String] = [], lastChecked: String? = nil, connectedOn: String? = nil,
    note: String? = nil, readElsewhere: Bool = false, pastMailSkipped: Bool = false
  ) {
    self.id = id
    self.provider = provider
    self.address = address
    self.state = state
    self.meta = meta
    self.accountKind = accountKind
    self.banks = banks
    self.lastChecked = lastChecked
    self.connectedOn = connectedOn
    self.note = note
    self.readElsewhere = readElsewhere
    self.pastMailSkipped = pastMailSkipped
  }
}
