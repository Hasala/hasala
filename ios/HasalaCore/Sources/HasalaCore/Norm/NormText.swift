import HasalaText

enum Bytes {
  static let lf: UInt8 = 0x0a
  static let cr: UInt8 = 0x0d
  static let sp: UInt8 = 0x20
  static let tab: UInt8 = 0x09

  static func index(of needle: [UInt8], in hay: [UInt8], from: Int = 0) -> Int? {
    index(of: needle, in: hay[...], from: from)
  }

  static func index(of b: UInt8, in hay: [UInt8], from: Int = 0) -> Int? { index(of: b, in: hay[...], from: from) }

  static func index(of needle: [UInt8], in hay: ArraySlice<UInt8>, from: Int) -> Int? {
    let lo = max(hay.startIndex, from)
    if needle.isEmpty { return lo <= hay.endIndex ? lo : nil }
    guard hay.endIndex - needle.count >= lo else { return nil }
    let first = needle[0]
    var i = lo
    let last = hay.endIndex - needle.count
    outer: while i <= last {
      if hay[i] != first {
        i += 1
        continue
      }
      for j in 1..<needle.count where hay[i + j] != needle[j] {
        i += 1
        continue outer
      }
      return i
    }
    return nil
  }

  static func index(of b: UInt8, in hay: ArraySlice<UInt8>, from: Int) -> Int? {
    var i = max(hay.startIndex, from)
    while i < hay.endIndex {
      if hay[i] == b { return i }
      i += 1
    }
    return nil
  }

  static func hasPrefix(_ hay: ArraySlice<UInt8>, _ needle: [UInt8], at: Int) -> Bool {
    guard at >= hay.startIndex, at + needle.count <= hay.endIndex else { return false }
    for j in 0..<needle.count where hay[at + j] != needle[j] { return false }
    return true
  }

  static func hasPrefix(_ hay: [UInt8], _ needle: [UInt8], at: Int = 0) -> Bool { hasPrefix(hay[...], needle, at: at) }

  static func trim(_ s: ArraySlice<UInt8>, where isTrimmed: (UInt8) -> Bool) -> ArraySlice<UInt8> {
    var lo = s.startIndex
    var hi = s.endIndex
    while lo < hi, isTrimmed(s[lo]) { lo += 1 }
    while hi > lo, isTrimmed(s[hi - 1]) { hi -= 1 }
    return s[lo..<hi]
  }

  static func latin1Lower(_ s: [UInt8]) -> [UInt8] {
    s.map { b in
      if b >= 0x41 && b <= 0x5a { return b + 0x20 }
      if b >= 0xc0 && b <= 0xde && b != 0xd7 { return b + 0x20 }
      return b
    }
  }

  static func of(_ s: StaticString) -> [UInt8] {
    s.withUTF8Buffer { Array($0) }
  }

  static func latin1String(_ s: [UInt8]) -> String {
    var out = String.UnicodeScalarView()
    for b in s { out.append(Unicode.Scalar(b)) }
    return String(out)
  }
}

enum NormText {
  static func jsLower(_ s: String) -> String {
    var out = String.UnicodeScalarView()
    for c in s.unicodeScalars {
      if c.isASCII {
        out.append(c.value >= 0x41 && c.value <= 0x5a ? Unicode.Scalar(UInt8(c.value + 0x20)) : c)
      } else {
        out.append(contentsOf: c.properties.lowercaseMapping.unicodeScalars)
      }
    }
    return String(out)
  }

  static func trimExplicit(_ s: String) -> String { s.trimming(.unwrapTrim) }

  @inline(__always) static func scalars(_ s: String) -> [Unicode.Scalar] { Array(s.unicodeScalars) }

  @inline(__always) static func string(_ s: some Sequence<Unicode.Scalar>) -> String {
    var v = String.UnicodeScalarView()
    v.append(contentsOf: s)
    return String(v)
  }

  static func splitLines(_ s: [Unicode.Scalar]) -> [ArraySlice<Unicode.Scalar>] {
    var out: [ArraySlice<Unicode.Scalar>] = []
    var start = 0
    for i in 0..<s.count where s[i] == "\n" {
      out.append(s[start..<i])
      start = i + 1
    }
    out.append(s[start..<s.count])
    return out
  }

  static func decodeUTF8(_ bytes: some Collection<UInt8>) -> String {
    String(decoding: bytes, as: UTF8.self)
  }
}
