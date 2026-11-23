import CoreJSON
import CorePrimitives
import Foundation

enum Fixtures {
  static let conformanceRoot: URL = {
    if let dir = ProcessInfo.processInfo.environment["HASALA_CONFORMANCE_DIR"], !dir.isEmpty {
      return URL(fileURLWithPath: dir, isDirectory: true)
    }
    var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while dir.path != "/" {
      let candidate = dir.appendingPathComponent("conformance", isDirectory: true)
      if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("op/manifest.json").path) {
        return candidate
      }
      dir.deleteLastPathComponent()
    }
    fatalError("conformance/ not found above \(#filePath); set HASALA_CONFORMANCE_DIR")
  }()

  static let privateConformanceRoot: URL? = {
    guard let dir = ProcessInfo.processInfo.environment["HASALA_PRIVATE_FIXTURES"], !dir.isEmpty else { return nil }
    return URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent("conformance", isDirectory: true)
  }()

  static var hasPrivate: Bool { privateConformanceRoot != nil }

  static func data(_ relative: String) throws -> Data {
    try Data(contentsOf: conformanceRoot.appendingPathComponent(relative))
  }

  static func json(_ relative: String) throws -> JSONValue {
    try JSONParser.parse(Array(try data(relative)))
  }

  static func jsonFiles(under root: URL) -> [String] {
    guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
    var out: [String] = []
    for case let url as URL in e where url.pathExtension == "json" {
      out.append(String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1)))
    }
    return out.sorted()
  }
}

enum FixtureError: Error, CustomStringConvertible {
  case missing(String)
  var description: String {
    switch self {
    case .missing(let f): "fixture field missing or mistyped: \(f)"
    }
  }
}

extension JSONValue {
  func string(_ key: String) throws -> String {
    guard let s = self[key]?.stringValue else { throw FixtureError.missing(key) }
    return s
  }

  func int(_ key: String) throws -> Int {
    guard let n = self[key]?.numberValue?.int64Value else { throw FixtureError.missing(key) }
    return Int(n)
  }

  func array(_ key: String) throws -> [JSONValue] {
    guard let a = self[key]?.arrayValue else { throw FixtureError.missing(key) }
    return a
  }

  func base64(_ key: String) throws -> Data { try Base64.decode(try string(key)) }
}

struct FrameV1 {
  let version: UInt8
  let aad: Data
  let nonce: Data
  let gzip: Data
  let tag: Data
  let prePadLength: Int

  init(_ b: Data) throws {
    let b = [UInt8](b)
    func be(_ at: Int, _ n: Int) throws -> Int {
      guard at + n <= b.count else { throw FixtureError.missing("frame truncated at \(at)") }
      return b[at..<(at + n)].reduce(0) { $0 << 8 | Int($1) }
    }
    version = b[0]
    let aadLength = try be(1, 2)
    aad = Data(b[3..<(3 + aadLength)])
    nonce = Data(b[(3 + aadLength)..<(15 + aadLength)])
    let payloadAt = 15 + aadLength
    let payloadLength = try be(payloadAt, 4)
    gzip = Data(b[(payloadAt + 4)..<(payloadAt + 4 + payloadLength)])
    tag = Data(b[(b.count - 16)...])
    prePadLength = payloadAt + 4 + payloadLength + 16
  }
}
