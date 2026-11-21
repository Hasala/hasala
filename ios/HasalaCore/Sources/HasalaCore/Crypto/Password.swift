import CorePrimitives
import Foundation

public enum PasswordStretch {
  public static let iterations: UInt32 = 600_000

  public enum Failure: Error, Equatable, Sendable {
    case badSalt
    case addressNotNormalized
    case primitive(PrimitivesError)
  }

  public static func salt(serverSalt: Data, emailNorm: String) throws(Failure) -> Data {
    guard serverSalt.count == 32 else { throw .badSalt }
    guard (try? EmailNorm.normalize(emailNorm)) == emailNorm else { throw .addressNotNormalized }
    return Domain.password.prefix + serverSalt + Data(emailNorm.utf8)
  }

  public static func stretch(password: String, serverSalt: Data, emailNorm: String) throws(Failure) -> SecureBytes {
    let saltC = try salt(serverSalt: serverSalt, emailNorm: emailNorm)
    let nfc = password.precomposedStringWithCanonicalMapping
    let pw = SecureBytes(count: nfc.utf8.count)
    pw.withUnsafeMutableBytes { $0.copyBytes(from: nfc.utf8) }
    defer { pw.wipe() }
    do {
      return try PBKDF2.sha256(password: pw, salt: saltC, iterations: iterations)
    } catch {
      throw .primitive(error)
    }
  }
}

public enum PasswordPolicy {
  public static let minScalars = 12
  public static let maxScalars = 128

  public enum Violation: Error, Equatable, Sendable {
    case tooShort
    case tooLong
    case tooCommon
  }

  public struct Blocklist: Sendable {
    let entries: Set<[UInt8]>

    public init(entries: some Sequence<String>) {
      var s = Set<[UInt8]>()
      for e in entries where !e.isEmpty { s.insert(Array(e.precomposedStringWithCanonicalMapping.utf8)) }
      self.entries = s
    }

    public init(text: String) {
      self.init(
        entries: text.utf8.split(separator: 0x0a, omittingEmptySubsequences: true).map { line in
          String(decoding: line.last == 0x0d ? line.dropLast() : line, as: UTF8.self)
        })
    }

    public var count: Int { entries.count }

    func contains(_ bytes: [UInt8]) -> Bool { entries.contains(bytes) }
  }

  public static func check(_ candidate: String, blocklist: Blocklist) -> Violation? {
    let nfc = candidate.precomposedStringWithCanonicalMapping
    let n = nfc.unicodeScalars.count
    if n < minScalars { return .tooShort }
    if n > maxScalars { return .tooLong }
    var c = Array(nfc.utf8)
    defer { for i in c.indices { c[i] = 0 } }
    for i in c.indices where (0x41...0x5a).contains(c[i]) { c[i] += 0x20 }
    var end = c.count
    while end > 0, isStrippable(c[end - 1]) { end -= 1 }
    if blocklist.contains(c) || blocklist.contains(Array(c[0..<end])) { return .tooCommon }
    return nil
  }

  static func isStrippable(_ b: UInt8) -> Bool {
    (0x30...0x39).contains(b) || b == 0x21 || b == 0x2e || b == 0x3f || b == 0x23 || b == 0x2a
  }
}

public enum ResetCode {
  public static func code80(ephemeralPublicKey: Data) throws(SigningMessageError) -> Data {
    Data(sha256(Domain.resetCode.prefix + (try SigningMessage.check(ephemeralPublicKey, 32, "ek_pub"))).prefix(10))
  }

  public static func text(ephemeralPublicKey: Data) throws(SigningMessageError) -> String {
    Base32.encode(try code80(ephemeralPublicKey: ephemeralPublicKey))
  }

  public static func matches(_ typed: String, ephemeralPublicKey: Data) -> Bool {
    var u: [UInt8] = []
    for b in typed.utf8 where b != 0x20 && b != 0x2d {
      u.append((0x61...0x7a).contains(b) ? b - 0x20 : b)
    }
    guard let want = try? text(ephemeralPublicKey: ephemeralPublicKey) else { return false }
    return constantTimeEquals(u, Array(want.utf8))
  }
}
