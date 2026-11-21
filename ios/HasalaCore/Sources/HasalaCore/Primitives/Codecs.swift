import Foundation

public enum CodecError: Error, Equatable, Sendable {
  case notHex
  case notBase64
  case notBase64URL
  case base64URLPadding
  case notBase32
}

public enum Hex {
  private static let digits = Array("0123456789abcdef".utf8)

  public static func encode(_ bytes: some Sequence<UInt8>) -> String {
    var out = [UInt8]()
    out.reserveCapacity(bytes.underestimatedCount * 2)
    for b in bytes {
      out.append(digits[Int(b >> 4)])
      out.append(digits[Int(b & 0x0f)])
    }
    return String(decoding: out, as: UTF8.self)
  }

  public static func decode(_ s: String) throws(CodecError) -> Data {
    let u = Array(s.utf8)
    guard u.count % 2 == 0 else { throw .notHex }
    var out = Data(capacity: u.count / 2)
    var i = 0
    while i < u.count {
      guard let hi = nibble(u[i]), let lo = nibble(u[i + 1]) else { throw .notHex }
      out.append(hi << 4 | lo)
      i += 2
    }
    return out
  }

  static func nibble(_ c: UInt8) -> UInt8? {
    switch c {
    case 0x30...0x39: c - 0x30
    case 0x61...0x66: c - 0x61 + 10
    default: nil
    }
  }
}

public enum Base64 {
  private static let standard = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
  private static let url = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)

  public static func encode(_ bytes: some Sequence<UInt8>) -> String {
    encode(Array(bytes), alphabet: standard, pad: true)
  }

  public static func encodeURL(_ bytes: some Sequence<UInt8>) -> String {
    encode(Array(bytes), alphabet: url, pad: false)
  }

  public static func decode(_ s: String) throws(CodecError) -> Data {
    let u = Array(s.utf8)
    guard u.count % 4 == 0 else { throw .notBase64 }
    var body = u.count
    while body > 0, u[body - 1] == 0x3d, u.count - body < 2 { body -= 1 }
    guard let out = decodeBody(u[0..<body], alphabet: .standard) else { throw .notBase64 }
    return out
  }

  public static func decodeURL(_ s: String) throws(CodecError) -> Data {
    let u = Array(s.utf8)
    let firstPad = u.firstIndex(of: 0x3d) ?? u.count
    let padCount = u.count - firstPad
    guard padCount <= 2, u[firstPad...].allSatisfy({ $0 == 0x3d }) else { throw .notBase64URL }
    let rem = firstPad % 4
    guard rem != 1 else { throw .notBase64URL }
    guard let out = decodeBody(u[0..<firstPad], alphabet: .url) else { throw .notBase64URL }
    if padCount > 0, padCount != (rem == 0 ? 0 : 4 - rem) { throw .base64URLPadding }
    return out
  }

  private enum Alphabet { case standard, url }

  private static func value(_ c: UInt8, _ a: Alphabet) -> UInt32? {
    switch c {
    case 0x41...0x5a: UInt32(c - 0x41)
    case 0x61...0x7a: UInt32(c - 0x61 + 26)
    case 0x30...0x39: UInt32(c - 0x30 + 52)
    case 0x2b where a == .standard: 62
    case 0x2f where a == .standard: 63
    case 0x2d where a == .url: 62
    case 0x5f where a == .url: 63
    default: nil
    }
  }

  private static func decodeBody(_ u: ArraySlice<UInt8>, alphabet: Alphabet) -> Data? {
    guard u.count % 4 != 1 else { return nil }
    var out = Data(capacity: u.count * 3 / 4)
    var acc: UInt32 = 0
    var bits = 0
    for c in u {
      guard let v = value(c, alphabet) else { return nil }
      acc = (acc << 6) | v
      bits += 6
      if bits >= 8 {
        bits -= 8
        out.append(UInt8((acc >> UInt32(bits)) & 0xff))
      }
    }
    return out
  }

  private static func encode(_ b: [UInt8], alphabet: [UInt8], pad: Bool) -> String {
    var out = [UInt8]()
    out.reserveCapacity((b.count + 2) / 3 * 4)
    var i = 0
    while i + 3 <= b.count {
      let n = UInt32(b[i]) << 16 | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2])
      out += [alphabet[Int(n >> 18 & 63)], alphabet[Int(n >> 12 & 63)], alphabet[Int(n >> 6 & 63)], alphabet[Int(n & 63)]]
      i += 3
    }
    switch b.count - i {
    case 1:
      let n = UInt32(b[i]) << 16
      out += [alphabet[Int(n >> 18 & 63)], alphabet[Int(n >> 12 & 63)]]
      if pad { out += [0x3d, 0x3d] }
    case 2:
      let n = UInt32(b[i]) << 16 | UInt32(b[i + 1]) << 8
      out += [alphabet[Int(n >> 18 & 63)], alphabet[Int(n >> 12 & 63)], alphabet[Int(n >> 6 & 63)]]
      if pad { out.append(0x3d) }
    default: break
    }
    return String(decoding: out, as: UTF8.self)
  }
}

public enum Base32 {
  private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)

  public static func encode(_ bytes: some Sequence<UInt8>) -> String {
    var out = [UInt8]()
    var acc: UInt32 = 0
    var bits = 0
    for b in bytes {
      acc = (acc << 8) | UInt32(b)
      bits += 8
      while bits >= 5 {
        bits -= 5
        out.append(alphabet[Int((acc >> UInt32(bits)) & 31)])
      }
      acc &= (1 << UInt32(bits)) - 1
    }
    if bits > 0 { out.append(alphabet[Int((acc << UInt32(5 - bits)) & 31)]) }
    return String(decoding: out, as: UTF8.self)
  }

  public static func decode(_ s: String) throws(CodecError) -> Data {
    let u = Array(s.utf8)
    guard [0, 2, 4, 5, 7].contains(u.count % 8) else { throw .notBase32 }
    var out = Data(capacity: u.count * 5 / 8)
    var acc: UInt32 = 0
    var bits = 0
    for c in u {
      let v: UInt32
      switch c {
      case 0x41...0x5a: v = UInt32(c - 0x41)
      case 0x32...0x37: v = UInt32(c - 0x32 + 26)
      default: throw .notBase32
      }
      acc = (acc << 5) | v
      bits += 5
      if bits >= 8 {
        bits -= 8
        out.append(UInt8((acc >> UInt32(bits)) & 0xff))
      }
      acc &= (1 << UInt32(bits)) - 1
    }
    guard acc == 0 else { throw .notBase32 }
    return out
  }
}

public enum UTF8Text {
  public static func decode(_ bytes: some Collection<UInt8>) -> String {
    if bytes.starts(with: [0xef, 0xbb, 0xbf]) {
      return String(decoding: bytes.dropFirst(3), as: UTF8.self)
    }
    return String(decoding: bytes, as: UTF8.self)
  }

  public static func encode(_ s: String) -> [UInt8] { Array(s.utf8) }
}
