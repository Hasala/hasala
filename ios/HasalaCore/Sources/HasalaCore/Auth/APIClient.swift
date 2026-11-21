import Foundation

public struct APIFailure: Error, Sendable, Hashable {
  public let status: Int
  public let code: String
  public let detail: String
  public let retryAfterSeconds: Int?
  public let requestID: String?

  public init(status: Int, code: String, detail: String = "", retryAfterSeconds: Int? = nil, requestID: String? = nil) {
    self.status = status
    self.code = code
    self.detail = detail
    self.retryAfterSeconds = retryAfterSeconds
    self.requestID = requestID
  }

  public static func from(_ r: APIResponse) -> APIFailure {
    struct Body: Decodable {
      let error: String?
      let detail: String?
    }
    let b = try? JSONDecoder().decode(Body.self, from: r.body)
    return APIFailure(
      status: r.status, code: b?.error ?? "http_\(r.status)", detail: b?.detail ?? "",
      retryAfterSeconds: r.retryAfterSeconds, requestID: r.requestID)
  }
}

public enum APIError: Error, Sendable, Hashable {
  case transport(TransportError)
  case refused(APIFailure)
  case malformed(String)

  public var failure: APIFailure? {
    if case .refused(let f) = self { return f }
    return nil
  }

  public func `is`(_ status: Int, _ code: String) -> Bool {
    failure.map { $0.status == status && $0.code == code } ?? false
  }
}

public struct Empty: Codable, Sendable, Hashable {
  public init() {}
}

public struct APIClient: Sendable {
  public let transport: any Transport

  public init(transport: any Transport) { self.transport = transport }

  public func send(_ request: APIRequest) async throws(APIError) -> APIResponse {
    do {
      return try await transport.send(request)
    } catch {
      throw .transport(error)
    }
  }

  public func call<Res: Decodable>(
    _ method: APIRequest.Method, _ path: String, body: Data? = nil, bearer: String? = nil, as: Res.Type = Res.self
  ) async throws(APIError) -> Res {
    let r = try await send(APIRequest(method: method, path: path, body: body, bearer: bearer))
    guard (200..<300).contains(r.status) else { throw .refused(APIFailure.from(r)) }
    if Res.self == Empty.self, r.body.isEmpty || r.status == 204 { return Empty() as! Res }
    do {
      return try JSONDecoder().decode(Res.self, from: r.body)
    } catch {
      throw .malformed("\(method.rawValue) \(Self.routeName(path)): unexpected body")
    }
  }

  public func call<Req: Encodable, Res: Decodable>(
    _ method: APIRequest.Method, _ path: String, json: Req, bearer: String? = nil, as: Res.Type = Res.self
  ) async throws(APIError) -> Res {
    try await call(method, path, body: try Self.encode(json), bearer: bearer, as: Res.self)
  }

  public static func encode(_ v: some Encodable) throws(APIError) -> Data {
    do {
      let e = JSONEncoder()
      e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      return try e.encode(v)
    } catch {
      throw .malformed("request body did not encode")
    }
  }

  static func routeName(_ path: String) -> String {
    String(path.split(separator: "?", maxSplits: 1).first ?? "")
  }
}
