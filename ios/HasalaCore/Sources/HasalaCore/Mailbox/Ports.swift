import CoreJSON
import Foundation

public enum FlushOutcome: Sendable, Equatable {
  case flushed
  case accountFull
  case failed
}

public struct MailboxLedgerError: Error, Sendable, Equatable {
  public let detail: String
  public init(_ detail: String) { self.detail = detail }
}

public struct MailboxRetirePlan: Sendable, Equatable {
  public var grantID: String
  public var provider: String
  public var legacy: Bool
  public var total: Int
  public var edited: Int
  public var countKnown: Bool
  public var address: String?

  public init(
    grantID: String, provider: String, legacy: Bool, total: Int, edited: Int, countKnown: Bool = true,
    address: String? = nil
  ) {
    self.grantID = grantID
    self.provider = provider
    self.legacy = legacy
    self.total = total
    self.edited = edited
    self.countKnown = countKnown
    self.address = address
  }
}

public protocol MailboxLedger: Sendable {
  func syncToHead() async throws(MailboxLedgerError)
  func senderTrust() async -> [String: Bool]
  func projectedMessageIDs(among ids: [String]) async -> Set<String>
  func isIngested(_ ingestID: String) async -> Bool
  func textOverlap() async throws(MailboxLedgerError) -> TextOverlap?
  func authorSenderTrust(domain: String, trusted: Bool) async throws(MailboxLedgerError)
  func retirePlan(grantID: String, provider: String) async -> MailboxRetirePlan
  func authorRetire(_ plan: MailboxRetirePlan) async throws(MailboxLedgerError)
  func flush() async -> FlushOutcome
}

public enum MailboxLinkStatus: Sendable, Equatable {
  case noLink
  case holder(isThisDevice: Bool, watchExpiresAtMs: Int64?)
}

public struct MailboxLinkResult: Sendable, Equatable {
  public var status: MailboxLinkStatus
  public var clientState: String?
  public init(status: MailboxLinkStatus, clientState: String? = nil) {
    self.status = status
    self.clientState = clientState
  }
}

public enum MailboxPushConfig: Sendable, Equatable {
  case gmail(topic: String)
  case outlook(notificationURL: String, lifecycleURL: String)
  case none
}

public enum MailboxServerError: Error, Sendable, Equatable {
  case offline
  case notHolder
  case noLink
  case noWatchTopic
  case otherProvider
  case refused(Int, String)
}

public protocol MailboxServer: Sendable {
  func linkStatus() async throws(MailboxServerError) -> MailboxLinkStatus
  func linkChallenge() async throws(MailboxServerError) -> String
  func putLink(provider: MailProviderID, idToken: String, stepUp: JSONValue) async throws(MailboxServerError)
    -> MailboxLinkResult
  func putWatch(expiresAtMs: Int64) async throws(MailboxServerError)
  func deleteLink(stepUp: JSONValue) async throws(MailboxServerError)
  func pushConfig(provider: MailProviderID) async throws(MailboxServerError) -> MailboxPushConfig
  func linkStatus(provider: MailProviderID) async throws(MailboxServerError) -> MailboxLinkStatus
}

extension MailboxServer {
  public func linkStatus(provider: MailProviderID) async throws(MailboxServerError) -> MailboxLinkStatus {
    try await linkStatus()
  }
}

public enum MailboxStepUpError: Error, Sendable, Equatable {
  case cancelled, unavailable, failed
}

public protocol MailboxStepUp: Sendable {
  func proof(kind: String, payloadHash: Data?) async throws(MailboxStepUpError) -> JSONValue
}

public enum MailboxTrigger: String, Sendable {
  case launch, foreground, refresh, silentPush = "silent_push", appRefresh = "app_refresh"
  case processing, timer, retry
}
