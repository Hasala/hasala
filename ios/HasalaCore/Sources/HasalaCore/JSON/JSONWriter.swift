import HasalaText

public struct JSONWriter: Sendable {
  public enum NumberStyle: Sendable { case javascript, literal }
  public enum KeyOrder: Sendable { case javascript, insertion }

  public var numbers: NumberStyle
  public var keyOrder: KeyOrder

  public init(numbers: NumberStyle = .javascript, keyOrder: KeyOrder = .javascript) {
    self.numbers = numbers
    self.keyOrder = keyOrder
  }

  public func bytes(_ value: JSONValue) -> [UInt8] {
    var out = [UInt8]()
    write(value, into: &out)
    return out
  }

  public func string(_ value: JSONValue) -> String {
    String(decoding: bytes(value), as: UTF8.self)
  }

  private func write(_ v: JSONValue, into out: inout [UInt8]) {
    switch v {
    case .null: out.append(contentsOf: "null".utf8)
    case .bool(let b): out.append(contentsOf: (b ? "true" : "false").utf8)
    case .number(let n):
      switch numbers {
      case .literal: out.append(contentsOf: n.literal.utf8)
      case .javascript: out.append(contentsOf: JSNumber.stringify(literal: n.literal).utf8)
      }
    case .string(let s): JSONWriter.quote(s, into: &out)
    case .array(let a):
      out.append(0x5b)
      for (k, x) in a.enumerated() {
        if k > 0 { out.append(0x2c) }
        write(x, into: &out)
      }
      out.append(0x5d)
    case .object(let o):
      out.append(0x7b)
      var first = true
      for m in ordered(o.members) {
        if !first { out.append(0x2c) }
        first = false
        JSONWriter.quote(m.key, into: &out)
        out.append(0x3a)
        write(m.value, into: &out)
      }
      out.append(0x7d)
    }
  }

  private func ordered(_ members: [JSONObject.Member]) -> [JSONObject.Member] {
    guard keyOrder == .javascript else { return members }
    var indexed: [(UInt32, JSONObject.Member)] = []
    var named: [JSONObject.Member] = []
    for m in members {
      if let n = JSONWriter.arrayIndex(m.key) { indexed.append((n, m)) } else { named.append(m) }
    }
    if indexed.isEmpty { return members }
    return indexed.sorted { $0.0 < $1.0 }.map(\.1) + named
  }

  static func arrayIndex(_ key: String) -> UInt32? {
    let u = Array(key.utf8)
    guard !u.isEmpty, u.count <= 10, u.allSatisfy(ASCII.isDigit), u.count == 1 || u[0] != 0x30 else {
      return nil
    }
    var v: UInt64 = 0
    for d in u { v = v * 10 + UInt64(d - 0x30) }
    return v <= 4_294_967_294 ? UInt32(v) : nil
  }

  private static let hexDigits = Array("0123456789abcdef".utf8)

  public static func quote(_ s: String, into out: inout [UInt8]) {
    out.append(0x22)
    for b in s.utf8 {
      switch b {
      case 0x22: out += [0x5c, 0x22]
      case 0x5c: out += [0x5c, 0x5c]
      case 0x08: out += [0x5c, 0x62]
      case 0x0c: out += [0x5c, 0x66]
      case 0x0a: out += [0x5c, 0x6e]
      case 0x0d: out += [0x5c, 0x72]
      case 0x09: out += [0x5c, 0x74]
      case 0x00...0x1f: out += [0x5c, 0x75, 0x30, 0x30, hexDigits[Int(b >> 4)], hexDigits[Int(b & 0x0f)]]
      default: out.append(b)
      }
    }
    out.append(0x22)
  }
}
