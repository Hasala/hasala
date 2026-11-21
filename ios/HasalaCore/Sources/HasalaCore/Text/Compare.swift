public func compareUTF8(_ a: String, _ b: String) -> Int {
  var x = a.utf8.makeIterator()
  var y = b.utf8.makeIterator()
  while true {
    switch (x.next(), y.next()) {
    case (nil, nil): return 0
    case (nil, _): return -1
    case (_, nil): return 1
    case (let p?, let q?): if p != q { return p < q ? -1 : 1 }
    }
  }
}

public func compareScalars(_ a: String, _ b: String) -> Int {
  var x = a.unicodeScalars.makeIterator()
  var y = b.unicodeScalars.makeIterator()
  while true {
    switch (x.next(), y.next()) {
    case (nil, nil): return 0
    case (nil, _): return -1
    case (_, nil): return 1
    case (let p?, let q?): if p != q { return p.value < q.value ? -1 : 1 }
    }
  }
}

public func utf8Equal(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }

public struct ExactKey: Sendable, Hashable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
  public let value: String

  public init(_ value: String) { self.value = value }
  public init(stringLiteral value: String) { self.value = value }

  public init(from decoder: any Decoder) throws { value = try decoder.singleValueContainer().decode(String.self) }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.singleValueContainer()
    try c.encode(value)
  }

  public static func == (a: ExactKey, b: ExactKey) -> Bool { utf8Equal(a.value, b.value) }

  public func hash(into h: inout Hasher) {
    h.combine(value.utf8.count)
    for b in value.utf8 { h.combine(b) }
  }

  public var description: String { value }
}

public func runeCount(_ s: String) -> Int { s.unicodeScalars.count }

public func truncateRunes(_ s: String, _ n: Int) -> String {
  guard n > 0 else { return "" }
  let scalars = s.unicodeScalars
  let end = scalars.index(scalars.startIndex, offsetBy: n, limitedBy: scalars.endIndex) ?? scalars.endIndex
  return String(scalars[scalars.startIndex..<end])
}

public enum ASCII {
  public static func lowercased(_ s: String) -> String {
    String(decoding: s.utf8.map { $0 >= 0x41 && $0 <= 0x5a ? $0 + 0x20 : $0 }, as: UTF8.self)
  }

  public static func uppercased(_ s: String) -> String {
    String(decoding: s.utf8.map { $0 >= 0x61 && $0 <= 0x7a ? $0 - 0x20 : $0 }, as: UTF8.self)
  }

  public static func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }
  public static func isUpper(_ b: UInt8) -> Bool { b >= 0x41 && b <= 0x5a }
  public static func isLower(_ b: UInt8) -> Bool { b >= 0x61 && b <= 0x7a }
  public static func isLowerHexDigit(_ b: UInt8) -> Bool { isDigit(b) || (b >= 0x61 && b <= 0x66) }

  public static func isDecimal(_ s: String) -> Bool {
    !s.utf8.isEmpty && s.utf8.allSatisfy(isDigit)
  }

  public static func isLowerHex(_ s: String, count n: Int) -> Bool {
    s.utf8.count == n && s.utf8.allSatisfy(isLowerHexDigit)
  }
}

public enum GoCase {
  public static func lower(_ s: Unicode.Scalar) -> Unicode.Scalar {
    if s.isASCII {
      return s.value >= 0x41 && s.value <= 0x5a ? Unicode.Scalar(UInt8(s.value + 0x20)) : s
    }
    return s.properties.lowercaseMapping.unicodeScalars.first ?? s
  }

  public static func lower(_ s: String) -> String {
    var out = String.UnicodeScalarView()
    for c in s.unicodeScalars { out.append(lower(c)) }
    return String(out)
  }
}
