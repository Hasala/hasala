import CoreAuth
import CoreStore
import Foundation

public struct SessionHTTPExchange: HTTPExchange {
  let transport: any Transport
  let secrets: Secrets

  public init(transport: any Transport, secrets: Secrets) {
    self.transport = transport
    self.secrets = secrets
  }

  public func send(_ request: HTTPRequest) async throws(HTTPExchangeError) -> HTTPResponse {
    guard let parts = URLComponents(url: request.url, resolvingAgainstBaseURL: false) else { throw .offline }
    var path = parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath
    guard Self.isOriginPath(path) else { throw .offline }
    if let q = parts.percentEncodedQuery, !q.isEmpty { path += "?" + q }
    let bearer: String?
    do {
      bearer = try secrets.activeSession()?.token
    } catch {
      throw .offline
    }
    let method: APIRequest.Method
    switch request.method {
    case .get: method = .get
    case .post: method = .post
    case .put: method = .put
    case .delete: method = .delete
    case .patch: throw .offline
    }
    do {
      let r = try await transport.send(APIRequest(method: method, path: path, body: request.body, bearer: bearer))
      return HTTPResponse(status: r.status, body: r.body)
    } catch {
      if error == .cancelled { throw .cancelled }
      throw .offline
    }
  }

  static func isOriginPath(_ path: String) -> Bool {
    let b = Array(path.utf8.prefix(2))
    return b.first == 0x2F && (b.count == 1 || b[1] != 0x2F)
  }
}
