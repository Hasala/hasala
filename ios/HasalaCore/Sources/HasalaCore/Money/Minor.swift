import HasalaText

public enum MoneyError: Error, Equatable, Sendable {
  case grammar
  case exceedsInt64
  case outOfRange
  case overflow
}

public struct Minor: Sendable, Hashable, Comparable, CustomStringConvertible {
  public let value: Int64

  public init?(_ value: Int64) {
    guard value >= 0 else { return nil }
    self.value = value
  }

  public init(wire s: String) throws(MoneyError) {
    let v = try MoneyGrammar.parseV4(s, allowNegative: false)
    self.value = v
  }

  public var wire: String { String(value) }
  public var description: String { wire }
  public static func < (a: Minor, b: Minor) -> Bool { a.value < b.value }
}

public struct PositiveMinor: Sendable, Hashable, Comparable, CustomStringConvertible {
  public let value: Int64

  public init?(_ value: Int64) {
    guard value > 0 else { return nil }
    self.value = value
  }

  public init(wire s: String) throws(MoneyError) {
    let v = try MoneyGrammar.parseV4(s, allowNegative: false)
    guard v > 0 else { throw .outOfRange }
    self.value = v
  }

  public var minor: Minor { Minor(value)! }
  public var wire: String { String(value) }
  public var description: String { wire }
  public static func < (a: PositiveMinor, b: PositiveMinor) -> Bool { a.value < b.value }
}

public struct SignedMinor: Sendable, Hashable, Comparable, CustomStringConvertible {
  public let value: Int64

  public init?(_ value: Int64) {
    guard value != .min else { return nil }
    self.value = value
  }

  public init(wire s: String) throws(MoneyError) {
    let v = try MoneyGrammar.parseV4(s, allowNegative: true)
    guard v != .min else { throw .outOfRange }
    self.value = v
  }

  public var wire: String { String(value) }
  public var description: String { wire }
  public static func < (a: SignedMinor, b: SignedMinor) -> Bool { a.value < b.value }
}

public enum MoneyGrammar {
  public static func parseV4(_ s: String, allowNegative: Bool) throws(MoneyError) -> Int64 {
    var u = Array(s.utf8)[...]
    var negative = false
    if allowNegative, u.first == 0x2d {
      negative = true
      u = u.dropFirst()
    }
    guard let first = u.first, u.allSatisfy(ASCII.isDigit) else { throw .grammar }
    if first == 0x30 {
      guard u.count == 1, !negative else { throw .grammar }
      return 0
    }
    guard u.count <= 19 else { throw .grammar }
    return try accumulate(u, negative: negative)
  }

  public static func parseV3(_ s: String) throws(MoneyError) -> Int64 {
    let u = Array(s.utf8)
    guard ASCII.isDecimal(s) else { throw .grammar }
    let significant = u.drop(while: { $0 == 0x30 })
    return significant.isEmpty ? 0 : try accumulate(significant, negative: false)
  }

  private static func accumulate(_ digits: ArraySlice<UInt8>, negative: Bool) throws(MoneyError) -> Int64 {
    guard digits.count <= 19 else { throw .exceedsInt64 }
    var v: Int128 = 0
    for d in digits { v = v * 10 + Int128(d - 0x30) }
    if negative { v = -v }
    guard let out = Int64(exactly: v) else { throw .exceedsInt64 }
    return out
  }
}

public struct CurrencyCode: Sendable, Hashable, CustomStringConvertible {
  public let code: String

  public init?(_ s: String) {
    let u = Array(s.utf8)
    guard u.count == 3, u.allSatisfy(ASCII.isUpper) else { return nil }
    code = s
  }

  public var description: String { code }

  public static let aed = CurrencyCode("AED")!
}

public enum MinorExponent {
  public static func v1(_ currency: CurrencyCode) -> Int {
    switch currency.code {
    case "BHD", "IQD", "JOD", "KWD", "LYD", "OMR", "TND": 3
    case "BIF", "CLP", "DJF", "GNF", "ISK", "JPY", "KMF", "KRW", "PYG", "RWF", "UGX", "UYI", "VND", "VUV", "XAF",
      "XOF", "XPF":
      0
    default: 2
    }
  }
}
