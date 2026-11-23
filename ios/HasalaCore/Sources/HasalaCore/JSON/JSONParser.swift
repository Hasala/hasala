public enum JSONParseError: Error, Equatable, Sendable {
  case syntax(offset: Int)
  case tooDeep(limit: Int)
}

public enum JSONParser {
  public static let defaultMaxDepth = 128

  public static func parse(
    _ bytes: some Collection<UInt8>, maxDepth: Int = defaultMaxDepth, refuseLoneSurrogates: Bool = false
  ) throws(JSONParseError) -> JSONValue {
    var start = bytes.startIndex
    if bytes.starts(with: [0xef, 0xbb, 0xbf]) { start = bytes.index(start, offsetBy: 3) }
    let text = String(decoding: bytes[start...], as: UTF8.self)
    return try parse(text: text, maxDepth: maxDepth, refuseLoneSurrogates: refuseLoneSurrogates)
  }

  public static func parse(
    text: String, maxDepth: Int = defaultMaxDepth, refuseLoneSurrogates: Bool = false
  ) throws(JSONParseError) -> JSONValue {
    var p = Parser(bytes: Array(text.utf8), maxDepth: maxDepth, refuseLoneSurrogates: refuseLoneSurrogates)
    p.skipWhitespace()
    let v = try p.document()
    p.skipWhitespace()
    guard p.i == p.u.count else { throw .syntax(offset: p.i) }
    return v
  }
}

private struct Parser {
  let u: [UInt8]
  let maxDepth: Int
  let refuseLoneSurrogates: Bool
  var i = 0

  init(bytes: [UInt8], maxDepth: Int, refuseLoneSurrogates: Bool) {
    u = bytes
    self.maxDepth = maxDepth
    self.refuseLoneSurrogates = refuseLoneSurrogates
  }

  mutating func skipWhitespace() {
    while i < u.count, u[i] == 0x20 || u[i] == 0x09 || u[i] == 0x0a || u[i] == 0x0d { i += 1 }
  }

  func fail() -> JSONParseError { .syntax(offset: i) }

  struct Frame {
    var isObject: Bool
    var items: [JSONValue] = []
    var object = JSONObject()
    var key = ""
  }

  mutating func document() throws(JSONParseError) -> JSONValue {
    var stack: [Frame] = []
    while true {
      skipWhitespace()
      guard i < u.count else { throw fail() }
      var produced: JSONValue
      switch u[i] {
      case 0x7b, 0x5b:
        let isObject = u[i] == 0x7b
        guard stack.count < maxDepth else { throw .tooDeep(limit: maxDepth) }
        i += 1
        skipWhitespace()
        if i < u.count, u[i] == (isObject ? 0x7d : 0x5d) {
          i += 1
          produced = isObject ? .object(JSONObject()) : .array([])
        } else {
          var frame = Frame(isObject: isObject)
          if isObject { frame.key = try memberKey() }
          stack.append(frame)
          continue
        }
      case 0x22: produced = .string(try string())
      case 0x74:
        try literal("true")
        produced = .bool(true)
      case 0x66:
        try literal("false")
        produced = .bool(false)
      case 0x6e:
        try literal("null")
        produced = .null
      case 0x2d, 0x30...0x39: produced = .number(try number())
      default: throw fail()
      }

      while true {
        guard !stack.isEmpty else { return produced }
        let top = stack.count - 1
        if stack[top].isObject {
          stack[top].object[stack[top].key] = produced
        } else {
          stack[top].items.append(produced)
        }
        skipWhitespace()
        guard i < u.count else { throw fail() }
        if u[i] == 0x2c {
          i += 1
          if stack[top].isObject {
            skipWhitespace()
            stack[top].key = try memberKey()
          }
          break
        }
        guard u[i] == (stack[top].isObject ? 0x7d : 0x5d) else { throw fail() }
        i += 1
        let done = stack.removeLast()
        produced = done.isObject ? .object(done.object) : .array(done.items)
      }
    }
  }

  mutating func memberKey() throws(JSONParseError) -> String {
    guard i < u.count, u[i] == 0x22 else { throw fail() }
    let key = try string()
    skipWhitespace()
    guard i < u.count, u[i] == 0x3a else { throw fail() }
    i += 1
    return key
  }

  mutating func literal(_ word: StaticString) throws(JSONParseError) {
    let w = UnsafeBufferPointer(start: word.utf8Start, count: word.utf8CodeUnitCount)
    guard i + w.count <= u.count, u[i..<(i + w.count)].elementsEqual(w) else { throw fail() }
    i += w.count
  }

  mutating func number() throws(JSONParseError) -> JSONNumber {
    let start = i
    guard JSONNumber.scanNumber(u, &i) else { throw fail() }
    return JSONNumber(validated: String(decoding: u[start..<i], as: UTF8.self))
  }

  mutating func string() throws(JSONParseError) -> String {
    i += 1
    var out = [UInt8]()
    while true {
      guard i < u.count else { throw fail() }
      let c = u[i]
      switch c {
      case 0x22:
        i += 1
        return String(decoding: out, as: UTF8.self)
      case 0x5c:
        i += 1
        guard i < u.count else { throw fail() }
        let e = u[i]
        i += 1
        switch e {
        case 0x22: out.append(0x22)
        case 0x5c: out.append(0x5c)
        case 0x2f: out.append(0x2f)
        case 0x62: out.append(0x08)
        case 0x66: out.append(0x0c)
        case 0x6e: out.append(0x0a)
        case 0x72: out.append(0x0d)
        case 0x74: out.append(0x09)
        case 0x75: appendScalar(try unicodeEscape(), to: &out)
        default:
          i -= 1
          throw fail()
        }
      case 0x00...0x1f:
        throw fail()
      default:
        out.append(c)
        i += 1
      }
    }
  }

  mutating func unicodeEscape() throws(JSONParseError) -> UInt32 {
    let first = try hex4()
    switch first {
    case 0xd800...0xdbff:
      if i + 6 <= u.count, u[i] == 0x5c, u[i + 1] == 0x75 {
        let save = i
        i += 2
        let second = try hex4()
        if (0xdc00...0xdfff).contains(second) {
          return 0x10000 + ((first - 0xd800) << 10) + (second - 0xdc00)
        }
        i = save
      }
      if refuseLoneSurrogates { throw fail() }
      return 0xfffd
    case 0xdc00...0xdfff:
      if refuseLoneSurrogates { throw fail() }
      return 0xfffd
    default:
      return first
    }
  }

  mutating func hex4() throws(JSONParseError) -> UInt32 {
    guard i + 4 <= u.count else { throw fail() }
    var v: UInt32 = 0
    for _ in 0..<4 {
      let c = u[i]
      let d: UInt32
      switch c {
      case 0x30...0x39: d = UInt32(c - 0x30)
      case 0x41...0x46: d = UInt32(c - 0x41 + 10)
      case 0x61...0x66: d = UInt32(c - 0x61 + 10)
      default: throw fail()
      }
      v = v << 4 | d
      i += 1
    }
    return v
  }

  func appendScalar(_ v: UInt32, to out: inout [UInt8]) {
    let s = Unicode.Scalar(v) ?? "\u{FFFD}"
    out.append(contentsOf: UTF8.encode(s)!)
  }
}
