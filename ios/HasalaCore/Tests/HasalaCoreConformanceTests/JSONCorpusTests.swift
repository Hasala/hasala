import CoreJSON
import HasalaText
import Foundation
import Testing

@Suite("JSON corpus cross-check")
struct JSONCorpusTests {
  static let publicFiles = Fixtures.jsonFiles(under: Fixtures.conformanceRoot)

  @Test("the public corpus is what this suite expects to read")
  func publicCorpusSize() {
    #expect(Self.publicFiles.count >= 39)
  }

  @Test("a leading U+FEFF in a string value: CoreJSON keeps it, the comparison forgives only Foundation's drop")
  func leadingBOMInString() throws {
    let data = Data("[\"\\ufeffab\", \"a\\ufeffb\"]".utf8)
    let ours = try JSONParser.parse([UInt8](data))
    #expect(ours == .array([.string("\u{FEFF}ab"), .string("a\u{FEFF}b")]))
    let theirs = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    #expect(Self.firstMismatch(ours, theirs, path: "$") == nil)
    #expect(Self.firstMismatch(.string("ab"), "\u{FEFF}ab", path: "$") == "$")
    #expect(Self.firstMismatch(.string("\u{FEFF}\u{FEFF}ab"), "ab", path: "$") == "$")
    #expect(Self.firstMismatch(.string("\u{FEFF}ab"), "ac", path: "$") == "$")
  }

  @Test("CoreJSON agrees with JSONSerialization on every public conformance file", arguments: publicFiles)
  func publicFile(_ relative: String) throws {
    try Self.check(root: Fixtures.conformanceRoot, relative)
  }

  @Test(
    "CoreJSON agrees with JSONSerialization on every private conformance file",
    .enabled(if: Fixtures.hasPrivate, "HASALA_PRIVATE_FIXTURES is unset"))
  func privateFiles() throws {
    let root = try #require(Fixtures.privateConformanceRoot)
    let files = Fixtures.jsonFiles(under: root)
    #expect(!files.isEmpty, "no JSON under HASALA_PRIVATE_FIXTURES/conformance")
    for f in files { try Self.check(root: root, f) }
  }

  static func check(root: URL, _ relative: String) throws {
    let data = try Data(contentsOf: root.appendingPathComponent(relative))
    let ours = try JSONParser.parse([UInt8](data))
    let theirs = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    let mismatch = firstMismatch(ours, theirs, path: "$")
    #expect(mismatch == nil, "\(relative): values differ at \(mismatch ?? "")")
    let literal = JSONWriter(numbers: .literal, keyOrder: .insertion).bytes(ours)
    let reparsed = try JSONParser.parse(literal)
    let stable = reparsed == ours
    #expect(stable, "\(relative): literal round trip changed the value")
  }

  static func firstMismatch(_ a: JSONValue, _ b: Any, path: String) -> String? {
    switch a {
    case .null:
      return b is NSNull ? nil : path
    case .bool(let x):
      guard let n = b as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return path }
      return n.boolValue == x ? nil : path
    case .number(let x):
      guard let n = b as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return path }
      if let i = x.int64Value, CFNumberIsFloatType(n) == false, !(n is NSDecimalNumber) {
        return n.int64Value == i ? nil : path
      }
      return Double(x.literal) == n.doubleValue ? nil : path
    case .string(let x):
      guard let s = b as? String else { return path }
      if utf8Equal(x, s) { return nil }
      if x.unicodeScalars.first == "\u{FEFF}", utf8Equal(String(x.unicodeScalars.dropFirst()), s) { return nil }
      return path
    case .array(let xs):
      guard let ys = b as? [Any], ys.count == xs.count else { return path }
      for (i, (x, y)) in zip(xs, ys).enumerated() {
        if let m = firstMismatch(x, y, path: "\(path)[\(i)]") { return m }
      }
      return nil
    case .object(let o):
      guard let d = b as? [String: Any], d.count == o.count else { return path }
      for m in o.members {
        guard let y = d[m.key] else { return "\(path).<key \(m.key.utf8.count) bytes>" }
        if let r = firstMismatch(m.value, y, path: "\(path).\(Self.safeKey(m.key))") { return r }
      }
      return nil
    }
  }

  static func safeKey(_ k: String) -> String {
    k.utf8.allSatisfy { ASCII.isLower($0) || ASCII.isDigit($0) || $0 == 0x5f } && k.utf8.count <= 40
      ? k : "<key>"
  }
}
