import CorePrimitives
import Foundation

public enum APNsTokenEnvironment: String, Sendable, Hashable, Codable, CaseIterable {
  case production
  case sandbox
}

public struct PutAPNsRequest: Codable, Sendable, Hashable {
  public var token_hex: String
  public var environment: String

  public init(tokenHex: String, environment: APNsTokenEnvironment) {
    token_hex = tokenHex
    self.environment = environment.rawValue
  }
}

public struct APNsDevice: Codable, Sendable, Hashable {
  public var writer_id: String
  public var environment: String
  public var created_at: String
  public var updated_at: String
  public var current: Bool
}

public struct APNsDevicesResponse: Codable, Sendable, Hashable {
  public var devices: [APNsDevice]
}

public struct BankRequestBody: Codable, Sendable, Hashable {
  public var bank: String
  public var otherBank: String?
  public var senderDomain: String?
  public var source: String

  public init(bank: String, otherBank: String?, senderDomain: String? = nil) {
    self.bank = bank
    self.otherBank = otherBank
    self.senderDomain = senderDomain
    source = "app"
  }
}

public struct BankRequestState: Codable, Sendable, Hashable {
  public var bank: String
  public var name: String
  public var state: String
  public var requestedAt: String

  public init(bank: String, name: String, state: String, requestedAt: String) {
    self.bank = bank
    self.name = name
    self.state = state
    self.requestedAt = requestedAt
  }
}

public struct BankCatalogEntry: Codable, Sendable, Hashable {
  public var bank: String
  public var name: String
  public var state: String

  public init(bank: String, name: String, state: String) {
    self.bank = bank
    self.name = name
    self.state = state
  }
}

public struct BankRequestsList: Codable, Sendable, Hashable {
  public var requests: [BankRequestState]
  public var catalog: [BankCatalogEntry]

  public init(requests: [BankRequestState], catalog: [BankCatalogEntry]) {
    self.requests = requests
    self.catalog = catalog
  }
}

public struct BankRequestResponse: Codable, Sendable, Hashable {
  public var status: String
}

public struct DisplayNameRequest: Codable, Sendable, Hashable {
  public var display_name: String
  public init(displayName: String) { display_name = displayName }
}

extension AuthClient {
  public static func tokenHex(_ deviceToken: Data) -> String {
    Hex.encode(deviceToken)
  }

  public func putAPNs(tokenHex: String, environment: APNsTokenEnvironment, bearer: String) async throws(APIError) {
    let _: Empty = try await api.call(
      .put, "/api/v1/push/apns", json: PutAPNsRequest(tokenHex: tokenHex, environment: environment), bearer: bearer)
  }

  public func apnsDevices(bearer: String) async throws(APIError) -> APNsDevicesResponse {
    try await api.call(.get, "/api/v1/push/apns", bearer: bearer)
  }

  public func deleteAPNs(bearer: String) async throws(APIError) {
    let _: Empty = try await api.call(.delete, "/api/v1/push/apns", bearer: bearer)
  }

  @discardableResult
  public func bankRequest(bank: String, otherBank: String? = nil, senderDomain: String? = nil, bearer: String)
    async throws(APIError) -> BankRequestResponse
  {
    try await api.call(
      .post, "/api/v1/bank-requests",
      json: BankRequestBody(bank: bank, otherBank: otherBank, senderDomain: senderDomain), bearer: bearer)
  }

  public func bankRequests(bearer: String) async throws(APIError) -> BankRequestsList {
    try await api.call(.get, "/api/v1/bank-requests", bearer: bearer)
  }

  public func setDisplayName(_ name: String, bearer: String) async throws(APIError) {
    let _: Empty = try await api.call(
      .put, "/api/v1/account/display-name", json: DisplayNameRequest(displayName: name), bearer: bearer)
  }
}
