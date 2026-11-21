import CoreJSON
import CoreMail
import CorePrimitives
import Foundation

public enum MailProviderID: String, Sendable, Hashable, CaseIterable, Codable {
  case gmail
  case outlook

  public var prefersEphemeralSession: Bool { self == .outlook }
}

public protocol MailProvider: Sendable {
  var id: MailProviderID { get }
  var oauth: any MailOAuthClient { get }
  func source(accessToken: AccessToken) -> any MailSource
  func analyzeAuthResults(_ headerBlock: String) -> AuthResults.Analysis
  func analyzeAuthResults(_ headerBlock: String, inInbox: Bool?, senderAddresses: [String]) -> AuthResults.Analysis
  var maxDownloadWidth: Int { get }
  var stopIsDeviceScoped: Bool { get }
  func installLink(_ result: MailboxLinkResult) throws(MailAuthError)
  func forgetLink()
  var listsByAddress: Bool { get }
  func source(accessToken: AccessToken, senderAddresses: [String]) -> any MailSource
  func unlisted(_ trusted: [String], senderAddresses: [String]) -> [String]
}

extension MailProvider {
  public func analyzeAuthResults(_ headerBlock: String, inInbox: Bool?, senderAddresses: [String])
    -> AuthResults.Analysis
  {
    analyzeAuthResults(headerBlock)
  }
  public var listsByAddress: Bool { false }
  public func source(accessToken: AccessToken, senderAddresses: [String]) -> any MailSource {
    source(accessToken: accessToken)
  }
  public func unlisted(_ trusted: [String], senderAddresses: [String]) -> [String] { [] }
  public var maxDownloadWidth: Int { Int.max }
  public var stopIsDeviceScoped: Bool { false }
  public func installLink(_ result: MailboxLinkResult) throws(MailAuthError) {}
  public func forgetLink() {}
}

public struct MailAuthorization: Sendable, Equatable {
  public let url: URL
  public let state: String
  public let codeVerifier: String
  public let nonce: String

  public init(url: URL, state: String, codeVerifier: String, nonce: String) {
    self.url = url
    self.state = state
    self.codeVerifier = codeVerifier
    self.nonce = nonce
  }
}

public enum MailOAuthError: Error, Sendable, Equatable {
  case cancelled
  case stateMismatch
  case denied(String)
  case malformedCallback
  case missingGrant
  case invalidGrant
  case http(Int)
  case offline
  case malformedResponse
  case notConfigured
}

public struct MailTokenGrant: Sendable, Equatable {
  public let accessToken: String
  public let expiresIn: Int64
  public let refreshToken: String?
  public let idToken: String?
  public let scope: String?

  public init(accessToken: String, expiresIn: Int64, refreshToken: String?, idToken: String?, scope: String?) {
    self.accessToken = accessToken
    self.expiresIn = expiresIn
    self.refreshToken = refreshToken
    self.idToken = idToken
    self.scope = scope
  }
}

public struct MailIdentity: Sendable, Equatable {
  public let email: String?
  public let nonce: String?

  public init(email: String?, nonce: String?) {
    self.email = email
    self.nonce = nonce
  }
}

public protocol MailOAuthClient: Sendable {
  var isConfigured: Bool { get }
  var redirectScheme: String { get }
  func begin(nonce: String, random: any RandomSource) throws(MailOAuthError) -> MailAuthorization
  func code(fromCallback callback: URL, for auth: MailAuthorization) throws(MailOAuthError) -> String
  func exchange(code: String, auth: MailAuthorization) async throws(MailOAuthError) -> MailTokenGrant
  func refresh(refreshToken: String) async throws(MailOAuthError) -> MailTokenGrant
  func revoke(token: String) async throws(MailOAuthError)
  func identity(idToken: String) -> MailIdentity?
}

public protocol MailAuthSessionPresenter: Sendable {
  func authorize(url: URL, callbackScheme: String) async throws(MailOAuthError) -> URL
}

public enum MailAPIError: Error, Sendable, Equatable {
  case status(Int, op: String)
  case offline
  case unfilteredListing
  case throttled(retryAfterSec: Int64, op: String)
  case noMailbox
  case filterNotApplied
  case tooLarge(op: String)

  public var status: Int? {
    switch self {
    case .status(let s, _): s
    case .throttled: 429
    default: nil
    }
  }
}

public struct MailListPage: Sendable, Equatable {
  public let ids: [String]
  public let nextPageToken: String?

  public init(ids: [String], nextPageToken: String?) {
    self.ids = ids
    self.nextPageToken = nextPageToken
  }
}

public struct MailMessageMetadata: Sendable, Equatable {
  public let id: String
  public let internalDate: String
  public let sizeEstimate: Int64?
  public let headers: [(name: String, value: String)]

  public init(id: String, internalDate: String, sizeEstimate: Int64?, headers: [(name: String, value: String)]) {
    self.id = id
    self.internalDate = internalDate
    self.sizeEstimate = sizeEstimate
    self.headers = headers
  }

  public static func == (a: Self, b: Self) -> Bool {
    a.id == b.id && a.internalDate == b.internalDate && a.sizeEstimate == b.sizeEstimate
      && a.headers.elementsEqual(b.headers) { $0.name == $1.name && $0.value == $1.value }
  }

  public var headerBlock: String {
    headers.map { "\($0.name): \($0.value)" }.joined(separator: "\r\n")
  }

  public var from: String { headers.first { $0.name.caseInsensitiveCompare("From") == .orderedSame }?.value ?? "" }
}

public struct MailRawMessage: Sendable, Equatable {
  public let id: String
  public let rawBase64URL: String
  public let internalDate: String
  public let spam: Bool
  public let inInbox: Bool?

  public init(id: String, rawBase64URL: String, internalDate: String, spam: Bool = false, inInbox: Bool? = nil) {
    self.id = id
    self.rawBase64URL = rawBase64URL
    self.internalDate = internalDate
    self.spam = spam
    self.inInbox = inInbox
  }
}

public struct MailSubscription: Sendable, Equatable {
  public let expiresAtMs: Int64

  public init(expiresAtMs: Int64) { self.expiresAtMs = expiresAtMs }
}

public protocol MailSource: Sendable {
  var maxSendersPerList: Int { get }
  func changeToken() async throws(MailAPIError) -> String?
  func list(senders: [String], since: Int64, pageToken: String?) async throws(MailAPIError) -> MailListPage
  func metadata(id: String) async throws(MailAPIError) -> MailMessageMetadata
  func raw(id: String) async throws(MailAPIError) -> MailRawMessage
  func subscribe(_ push: MailboxPushConfig) async throws(MailAPIError) -> MailSubscription?
  func renew(_ push: MailboxPushConfig) async throws(MailAPIError) -> MailSubscription?
  func stop() async throws(MailAPIError)
  func checkMailbox() async throws(MailAPIError)
}

extension MailSource {
  public func checkMailbox() async throws(MailAPIError) {}
}

public enum SenderProbeResult: Sendable, Equatable {
  case found([String])
  case notReading
  case reconnectRequired
  case offline
}
