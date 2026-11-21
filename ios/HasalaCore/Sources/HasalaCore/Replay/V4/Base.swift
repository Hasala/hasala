import CoreJSON
import CoreMoney
import CoreTime
import HasalaText

public struct OpPosition: Sendable, Hashable, Comparable, Codable {
  public let seq: Int64
  public let index: Int

  public init(seq: Int64, index: Int) {
    self.seq = seq
    self.index = index
  }

  public static func < (a: OpPosition, b: OpPosition) -> Bool {
    a.seq != b.seq ? a.seq < b.seq : a.index < b.index
  }
}

public struct Keyed<V: Sendable & Equatable & Codable>: Sendable, Equatable, Codable {
  public var value: V
  public var opID: String

  public init(_ value: V, opID: String) {
    self.value = value
    self.opID = opID
  }
}

public enum Grammar {
  public static func isCategoryID(_ s: String) -> Bool { TextRules.isToken(s) && s.utf8.count >= 2 }

  public static func isIconID(_ s: String) -> Bool { TextRules.isToken(s) }

  public static let categoryParents: [(id: String, kind: String, bucket: String?)] = [
    ("rent", "spending", "need"), ("utilities", "spending", "need"), ("groceries", "spending", "need"), ("transport", "spending", "need"),
    ("healthcare", "spending", "need"), ("insurance", "spending", "need"), ("dining", "spending", "want"),
    ("entertainment", "spending", "want"), ("shopping", "spending", "want"), ("travel", "spending", "want"),
    ("subscriptions", "spending", "want"), ("savings", "spending", "saving"), ("investments", "spending", "saving"),
    ("debt", "spending", "saving"), ("salary", "income", nil), ("freelance", "income", nil),
  ]

  public static let categoryParentIDs = categoryParents.map(\.id)

  public static func isCategoryParent(_ s: String) -> Bool { categoryParentIDs.contains { utf8Equal($0, s) } }

  public static func categoryParentClass(_ s: String) -> (kind: String, bucket: String?)? {
    guard let p = categoryParents.first(where: { utf8Equal($0.id, s) }) else { return nil }
    return (p.kind, p.bucket)
  }

  public static func isULID(_ s: String) -> Bool {
    let u = Array(s.utf8)
    guard u.count == 26, (0x30...0x37).contains(u[0]) else { return false }
    return u.dropFirst().allSatisfy(isCrockford)
  }

  private static func isCrockford(_ b: UInt8) -> Bool {
    if ASCII.isDigit(b) { return true }
    guard ASCII.isUpper(b) else { return false }
    return b != 0x49 && b != 0x4c && b != 0x4f && b != 0x55
  }

  public static func isID(_ s: String) -> Bool {
    let u = Array(s.utf8)
    guard (1...64).contains(u.count) else { return false }
    return u.allSatisfy { ASCII.isDigit($0) || ASCII.isUpper($0) || ASCII.isLower($0) || $0 == 0x2e || $0 == 0x5f || $0 == 0x2d }
  }

  public static func isBank(_ s: String) -> Bool {
    let u = Array(s.utf8)
    guard (2...32).contains(u.count) else { return false }
    return u.allSatisfy { ASCII.isDigit($0) || ASCII.isLower($0) || $0 == 0x5f }
  }

  public static func isPlanRecordID(_ s: String) -> Bool {
    let u = Array(s.utf8)
    guard (1...64).contains(u.count), ASCII.isDigit(u[0]) || ASCII.isLower(u[0]) else { return false }
    return u.allSatisfy { ASCII.isDigit($0) || ASCII.isLower($0) || $0 == 0x5f || $0 == 0x2d }
  }

  public static func isDictBundle(_ s: String) -> Bool {
    let u = Array(s.utf8)
    guard (12...14).contains(u.count), u[4] == 0x2e, u[7] == 0x2e, u[10] == 0x2d else { return false }
    for (i, b) in u.enumerated() where i != 4 && i != 7 && i != 10 {
      guard ASCII.isDigit(b) else { return false }
    }
    return true
  }

  public static func isModelTag(_ s: String) -> Bool {
    let u = Array(s.utf8)
    guard (1...32).contains(u.count), ASCII.isDigit(u[0]) || ASCII.isLower(u[0]) else { return false }
    return u.allSatisfy { ASCII.isDigit($0) || ASCII.isLower($0) || $0 == 0x2e || $0 == 0x2f || $0 == 0x2d }
  }

  public static func isDomain(_ s: String) -> Bool {
    let u = Array(s.utf8)
    guard (1...253).contains(u.count) else { return false }
    let labels = u.split(separator: 0x2e, omittingEmptySubsequences: false)
    guard labels.count >= 2 else { return false }
    for l in labels {
      guard (1...63).contains(l.count), let f = l.first, let z = l.last else { return false }
      guard f != 0x2d, z != 0x2d else { return false }
      guard l.allSatisfy({ ASCII.isDigit($0) || ASCII.isLower($0) || $0 == 0x2d }) else { return false }
    }
    return true
  }

  public static func civilDate(_ s: String) -> CivilDate? { CivilDate(wire: s) }

  public static func civilMonth(_ s: String) -> CivilMonth? { CivilMonth(wire: s) }

  public static func planMinor(_ s: String) -> Int64? {
    let u = Array(s.utf8)
    guard (1...13).contains(u.count), u.allSatisfy(ASCII.isDigit) else { return nil }
    if u[0] == 0x30 { return u.count == 1 ? 0 : nil }
    return Int64(s)
  }

  public static let maxPlanMinor: Int64 = 9_999_999_999_999

  public static func isRulePattern(_ s: String) -> Bool {
    let scalars = s.unicodeScalars
    guard (1...128).contains(scalars.count) else { return false }
    return !scalars.contains { ScalarSet.forbidden.contains($0) || (0x0a...0x0d).contains($0.value) || $0.value == 0x85 }
  }

  public static func isMerchantKey(_ s: String) -> Bool {
    let scalars = s.unicodeScalars
    guard (1...256).contains(scalars.count) else { return false }
    return !scalars.contains { ScalarSet.forbidden.contains($0) }
  }

  public static func isBillKey(_ s: String) -> Bool {
    let scalars = Array(s.unicodeScalars)
    guard (2...64).contains(scalars.count) else { return false }
    if scalars.first == " " || scalars.last == " " { return false }
    for (i, c) in scalars.enumerated() {
      if ScalarSet.forbidden.contains(c) { return false }
      if c == " ", i > 0, scalars[i - 1] == " " { return false }
    }
    return true
  }

  public static func isLast4(_ s: String) -> Bool {
    let u = Array(s.utf8)
    return u.count == 4 && u.allSatisfy(ASCII.isDigit)
  }
}
