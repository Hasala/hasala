import HasalaText

public enum JSONValue: Sendable, Hashable {
  case null
  case bool(Bool)
  case number(JSONNumber)
  case string(String)
  case array([JSONValue])
  case object(JSONObject)

  public static func == (a: JSONValue, b: JSONValue) -> Bool {
    switch (a, b) {
    case (.null, .null): true
    case (.bool(let x), .bool(let y)): x == y
    case (.number(let x), .number(let y)): x == y
    case (.string(let x), .string(let y)): utf8Equal(x, y)
    case (.array(let x), .array(let y)): x == y
    case (.object(let x), .object(let y)): x == y
    default: false
    }
  }

  public func hash(into h: inout Hasher) {
    switch self {
    case .null: h.combine(0)
    case .bool(let b): h.combine(1); h.combine(b)
    case .number(let n): h.combine(2); h.combine(n)
    case .string(let s): h.combine(3); h.combine(Array(s.utf8))
    case .array(let a): h.combine(4); h.combine(a)
    case .object(let o): h.combine(5); h.combine(o)
    }
  }
}

public struct JSONNumber: Sendable, Hashable, CustomStringConvertible {
  public let literal: String

  public init?(literal: String) {
    guard JSONNumber.isNumberLiteral(Array(literal.utf8)) else { return nil }
    self.literal = literal
  }

  public init(_ value: Int64) { literal = String(value) }

  init(validated literal: String) { self.literal = literal }

  public var description: String { literal }

  public var isIntegerLiteral: Bool {
    var u = Substring(literal).utf8[...]
    if u.first == 0x2d { u = u.dropFirst() }
    return !u.isEmpty && u.allSatisfy(ASCII.isDigit)
  }

  public var int64Value: Int64? {
    isIntegerLiteral ? Int64(literal) : nil
  }

  public var v4Int: Int64? {
    guard literal != "-0", let v = int64Value, v >= -JSONNumber.maxSafeInteger,
      v <= JSONNumber.maxSafeInteger
    else { return nil }
    return v
  }

  public static let maxSafeInteger: Int64 = 9_007_199_254_740_991

  static func isNumberLiteral(_ u: [UInt8]) -> Bool {
    var i = 0
    return scanNumber(u, &i) && i == u.count
  }

  static func scanNumber(_ u: [UInt8], _ i: inout Int) -> Bool {
    let n = u.count
    func digits() -> Int {
      let start = i
      while i < n, ASCII.isDigit(u[i]) { i += 1 }
      return i - start
    }
    if i < n, u[i] == 0x2d { i += 1 }
    guard i < n else { return false }
    if u[i] == 0x30 {
      i += 1
    } else if digits() == 0 {
      return false
    }
    if i < n, u[i] == 0x2e {
      i += 1
      guard digits() > 0 else { return false }
    }
    if i < n, u[i] == 0x65 || u[i] == 0x45 {
      i += 1
      if i < n, u[i] == 0x2b || u[i] == 0x2d { i += 1 }
      guard digits() > 0 else { return false }
    }
    return true
  }
}

public struct JSONObject: Sendable, Hashable {
  public struct Member: Sendable, Hashable {
    public let key: String
    public var value: JSONValue

    public static func == (a: Member, b: Member) -> Bool { utf8Equal(a.key, b.key) && a.value == b.value }
    public func hash(into h: inout Hasher) {
      h.combine(Array(key.utf8))
      h.combine(value)
    }
  }

  public private(set) var members: [Member]
  private var positions: [[UInt8]: Int]

  public init() {
    members = []
    positions = [:]
  }

  public init(_ pairs: [(String, JSONValue)]) {
    self.init()
    members.reserveCapacity(pairs.count)
    for (k, v) in pairs { self[k] = v }
  }

  public var count: Int { members.count }
  public var keys: [String] { members.map(\.key) }

  public subscript(key: String) -> JSONValue? {
    get { index(of: key).map { members[$0].value } }
    set {
      let k = Array(key.utf8)
      if let i = positions[k] {
        if let v = newValue {
          members[i].value = v
        } else {
          members.remove(at: i)
          positions[k] = nil
          for j in i..<members.count { positions[Array(members[j].key.utf8)] = j }
        }
      } else if let v = newValue {
        positions[k] = members.count
        members.append(Member(key: key, value: v))
      }
    }
  }

  private func index(of key: String) -> Int? { positions[Array(key.utf8)] }

  public static func == (a: JSONObject, b: JSONObject) -> Bool { a.members == b.members }
  public func hash(into h: inout Hasher) { h.combine(members) }
}

extension JSONValue {
  public var objectValue: JSONObject? { if case .object(let o) = self { o } else { nil } }
  public var arrayValue: [JSONValue]? { if case .array(let a) = self { a } else { nil } }
  public var stringValue: String? { if case .string(let s) = self { s } else { nil } }
  public var numberValue: JSONNumber? { if case .number(let n) = self { n } else { nil } }
  public var boolValue: Bool? { if case .bool(let b) = self { b } else { nil } }
  public var isNull: Bool { if case .null = self { true } else { false } }

  public subscript(key: String) -> JSONValue? { objectValue?[key] }

  public func sortingKeysByUTF8() -> JSONValue {
    switch self {
    case .array(let a): return .array(a.map { $0.sortingKeysByUTF8() })
    case .object(let o):
      let sorted = o.members.sorted { compareUTF8($0.key, $1.key) < 0 }
      return .object(JSONObject(sorted.map { ($0.key, $0.value.sortingKeysByUTF8()) }))
    default: return self
    }
  }
}
