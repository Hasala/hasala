import Foundation

public struct HTTPRequest: Sendable, Equatable {
  public enum Method: String, Sendable {
    case get = "GET", post = "POST", put = "PUT", patch = "PATCH", delete = "DELETE"
  }
  public var method: Method
  public var url: URL
  public var headers: [(String, String)]
  public var body: Data?

  public init(method: Method, url: URL, headers: [(String, String)] = [], body: Data? = nil) {
    self.method = method
    self.url = url
    self.headers = headers
    self.body = body
  }

  public func header(_ name: String) -> String? { headerValue(headers, name) }

  public static func == (a: HTTPRequest, b: HTTPRequest) -> Bool {
    a.method == b.method && a.url == b.url && a.body == b.body
      && a.headers.elementsEqual(b.headers) { $0.0 == $1.0 && $0.1 == $1.1 }
  }
}

public struct HTTPResponse: Sendable, Equatable {
  public var status: Int
  public var body: Data
  public var headers: [(String, String)]
  public init(status: Int, body: Data = Data(), headers: [(String, String)] = []) {
    self.status = status
    self.body = body
    self.headers = headers
  }
  public var ok: Bool { (200..<300).contains(status) }

  public func header(_ name: String) -> String? { headerValue(headers, name) }

  public static func == (a: HTTPResponse, b: HTTPResponse) -> Bool {
    a.status == b.status && a.body == b.body && a.headers.elementsEqual(b.headers) { $0.0 == $1.0 && $0.1 == $1.1 }
  }
}

public enum HTTPExchangeError: Error, Sendable, Equatable {
  case offline
  case cancelled
  case tooLarge
}

public protocol HTTPExchange: Sendable {
  func send(_ request: HTTPRequest) async throws(HTTPExchangeError) -> HTTPResponse
}

public final class URLSessionHTTPExchange: HTTPExchange {
  let session: URLSession
  let maxResponseBytes: Int?

  public init(configuration: URLSessionConfiguration, maxResponseBytes: Int? = nil) {
    session = URLSession(configuration: configuration)
    self.maxResponseBytes = maxResponseBytes
  }

  public static func ephemeral(timeout: TimeInterval = 30, maxResponseBytes: Int? = nil) -> URLSessionHTTPExchange {
    let c = URLSessionConfiguration.ephemeral
    c.httpCookieStorage = nil
    c.httpShouldSetCookies = false
    c.urlCache = nil
    c.urlCredentialStorage = nil
    c.requestCachePolicy = .reloadIgnoringLocalCacheData
    c.timeoutIntervalForRequest = timeout
    c.waitsForConnectivity = false
    return URLSessionHTTPExchange(configuration: c, maxResponseBytes: maxResponseBytes)
  }

  public func send(_ request: HTTPRequest) async throws(HTTPExchangeError) -> HTTPResponse {
    var r = URLRequest(url: request.url)
    r.httpMethod = request.method.rawValue
    for (k, v) in request.headers { r.addValue(v, forHTTPHeaderField: k) }
    r.httpBody = request.body
    do {
      let (data, response) = try await load(r)
      guard let http = response as? HTTPURLResponse else { throw HTTPExchangeError.offline }
      var headers: [(String, String)] = []
      if let retry = http.value(forHTTPHeaderField: "Retry-After") { headers.append(("Retry-After", retry)) }
      return HTTPResponse(status: http.statusCode, body: data, headers: headers)
    } catch let e as HTTPExchangeError {
      throw e
    } catch is CancellationError {
      throw .cancelled
    } catch let e as URLError where e.code == .cancelled {
      throw .cancelled
    } catch {
      throw .offline
    }
  }

  func load(_ r: URLRequest) async throws -> (Data, URLResponse) {
    guard let cap = maxResponseBytes else { return try await session.data(for: r) }
    let (stream, response) = try await session.bytes(for: r)
    if response.expectedContentLength > Int64(cap) {
      stream.task.cancel()
      throw HTTPExchangeError.tooLarge
    }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(min(cap, max(0, Int(clamping: response.expectedContentLength))))
    for try await b in stream {
      if bytes.count >= cap {
        stream.task.cancel()
        throw HTTPExchangeError.tooLarge
      }
      bytes.append(b)
    }
    return (Data(bytes), response)
  }
}

@inline(__always) func asciiLower(_ b: UInt8) -> UInt8 { (b >= 0x41 && b <= 0x5a) ? b + 0x20 : b }

func asciiLowered(_ s: String) -> String { String(decoding: s.utf8.map(asciiLower), as: UTF8.self) }

private func headerValue(_ headers: [(String, String)], _ name: String) -> String? {
  let want = Array(name.utf8).map(asciiLower)
  return headers.first { Array($0.0.utf8).map(asciiLower) == want }?.1
}

public enum FormEncoding {
  static let unreserved: Set<UInt8> = Set(
    Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8))

  public static func escape(_ s: String) -> String {
    var out = ""
    for b in s.utf8 {
      if unreserved.contains(b) {
        out.unicodeScalars.append(Unicode.Scalar(b))
      } else {
        out += "%" + String(b, radix: 16, uppercase: true).leftPadded(2)
      }
    }
    return out
  }

  public static func encode(_ pairs: [(String, String)]) -> String {
    pairs.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&")
  }

  public static func decode(_ s: String) -> [(String, String)] {
    guard !s.isEmpty else { return [] }
    return s.split(separator: "&", omittingEmptySubsequences: true).map { part in
      let kv = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      let k = unescape(String(kv[0]))
      let v = kv.count > 1 ? unescape(String(kv[1])) : ""
      return (k, v)
    }
  }

  static func unescape(_ s: String) -> String {
    let plus = s.replacingOccurrences(of: "+", with: " ")
    return plus.removingPercentEncoding ?? plus
  }
}

extension String {
  fileprivate func leftPadded(_ n: Int) -> String {
    count >= n ? self : String(repeating: "0", count: n - count) + self
  }
}

extension URL {
  static func build(_ base: String, _ path: String, _ query: [(String, String)] = []) -> URL {
    let q = query.isEmpty ? "" : "?" + FormEncoding.encode(query)
    return URL(string: base + path + q)!
  }
}
