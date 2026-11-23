import Foundation

public struct APIRequest: Sendable, Hashable {
  public enum Method: String, Sendable, Hashable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
  }

  public let method: Method
  public let path: String
  public let body: Data?
  public let bearer: String?

  public init(method: Method, path: String, body: Data? = nil, bearer: String? = nil) {
    self.method = method
    self.path = path
    self.body = body
    self.bearer = bearer
  }
}

public struct APIResponse: Sendable, Hashable {
  public let status: Int
  public let headers: [String: String]
  public let body: Data

  public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
    self.status = status
    var h: [String: String] = [:]
    for (k, v) in headers { h[asciiLower(k)] = v }
    self.headers = h
    self.body = body
  }

  public var requestID: String? { headers["hasala-request-id"] }

  public var retryAfterSeconds: Int? { headers["retry-after"].flatMap { Int($0) } }

  public var date: String? { headers["date"] }
}

public enum TransportError: Error, Sendable, Hashable {
  case offline(URLError.Code)
  case cancelled
  case tls
}

public protocol Transport: Sendable {
  func send(_ request: APIRequest) async throws(TransportError) -> APIResponse
}

func asciiLower(_ s: String) -> String {
  String(decoding: s.utf8.map { (0x41...0x5a).contains($0) ? $0 + 0x20 : $0 }, as: UTF8.self)
}
