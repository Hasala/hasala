import HasalaICU

enum EngineError: Error, Equatable, Sendable {
  case notCompilable
  case limitExceeded
  case matchFailed
}

struct ICUPattern: Equatable {
  let source: String
  let groups: [String?]

  static let maxRepeat = 1000

  static func translate(_ pattern: String, caseInsensitive: Bool) throws(EngineError) -> ICUPattern {
    var p = Parser(src: Array(pattern.unicodeScalars), ci: caseInsensitive)
    try p.disjunction()
    guard p.i == p.src.count else { throw .notCompilable }
    return ICUPattern(source: p.out, groups: p.groups)
  }

  static func compile(_ pattern: String, caseInsensitive: Bool) throws(EngineError) -> ICURegex {
    try ICURegex(try translate(pattern, caseInsensitive: caseInsensitive))
  }

  static let digit = CodePointSet(ranges: [0x30...0x39])
  static let word = CodePointSet(ranges: [0x30...0x39, 0x41...0x5A, 0x5F...0x5F, 0x61...0x7A])
  static let wordCI = word.caseClosed
  static let dot = CodePointSet([0x0A, 0x0D, 0x2028, 0x2029]).complement

  static func hex(_ v: UInt32) -> String { String(v, radix: 16, uppercase: true) }

  static func literal(_ v: UInt32) -> String {
    switch v {
    case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: String(Unicode.Scalar(v)!)
    default: "\\x{\(hex(v))}"
    }
  }

  static func emit(_ set: CodePointSet) -> String {
    if set.isEmpty { return "[^\\x{0}-\\x{10FFFF}]" }
    var s = "["
    for r in set.ranges {
      s += "\\x{\(hex(r.lowerBound))}"
      if r.upperBound != r.lowerBound { s += "-\\x{\(hex(r.upperBound))}" }
    }
    return s + "]"
  }

  struct Parser {
    let src: [Unicode.Scalar]
    let ci: Bool
    var i = 0
    var out = ""
    var groups: [String?] = []

    func peek(_ k: Int = 0) -> Unicode.Scalar? { i + k < src.count ? src[i + k] : nil }

    static func isSyntax(_ c: Unicode.Scalar) -> Bool { "^$\\.*+?()[]{}|".unicodeScalars.contains(c) }
    static func isDigit(_ c: Unicode.Scalar) -> Bool { c.value >= 0x30 && c.value <= 0x39 }
    static func hexValue(_ c: Unicode.Scalar) -> UInt32? {
      switch c.value {
      case 0x30...0x39: c.value - 0x30
      case 0x41...0x46: c.value - 0x41 + 10
      case 0x61...0x66: c.value - 0x61 + 10
      default: nil
      }
    }

    mutating func disjunction() throws(EngineError) {
      try alternative()
      while peek() == "|" {
        out += "|"
        i += 1
        try alternative()
      }
    }

    mutating func alternative() throws(EngineError) {
      while let c = peek(), c != "|", c != ")" { try term() }
    }

    mutating func term() throws(EngineError) {
      switch peek() {
      case "^":
        out += "^"
        i += 1
      case "$":
        out += "\\z"
        i += 1
      default:
        try atom()
        try quantifier()
      }
    }

    mutating func emitLiteral(_ v: UInt32) {
      if ci {
        let orbit = CaseFold.orbit(v)
        if orbit.count > 1 {
          out += ICUPattern.emit(CodePointSet(orbit))
          return
        }
      }
      out += ICUPattern.literal(v)
    }

    mutating func emitSet(_ set: CodePointSet) {
      out += ICUPattern.emit(ci ? set.caseClosed : set)
    }

    func classEscape(_ e: Unicode.Scalar) -> CodePointSet? {
      switch e {
      case "d": ICUPattern.digit
      case "D": ICUPattern.digit.complement
      case "w": ci ? ICUPattern.wordCI : ICUPattern.word
      case "W": (ci ? ICUPattern.wordCI : ICUPattern.word).complement
      default: nil
      }
    }

    mutating func characterEscape(inClass: Bool) throws(EngineError) -> UInt32 {
      guard let e = peek() else { throw .notCompilable }
      i += 1
      switch e {
      case "n": return 0x0A
      case "r": return 0x0D
      case "t": return 0x09
      case "f": return 0x0C
      case "v": return 0x0B
      case "x":
        guard let a = peek(), let b = peek(1), let hi = Self.hexValue(a), let lo = Self.hexValue(b) else {
          throw .notCompilable
        }
        i += 2
        return hi << 4 | lo
      case "-" where inClass:
        return 0x2D
      default:
        guard Self.isSyntax(e) || e == "/" else { throw .notCompilable }
        return e.value
      }
    }

    mutating func atom() throws(EngineError) {
      guard let c = peek() else { throw .notCompilable }
      switch c {
      case "(":
        i += 1
        if peek() == "?" {
          if peek(1) == ":" {
            i += 2
            out += "(?:"
          } else if peek(1) == "P", peek(2) == "<" {
            i += 3
            var name = String.UnicodeScalarView()
            while let n = peek(), n != ">" {
              name.append(n)
              i += 1
            }
            guard peek() == ">", isGroupName(name) else { throw .notCompilable }
            i += 1
            let text = String(name)
            guard !groups.contains(where: { $0?.utf8.elementsEqual(text.utf8) == true }) else { throw .notCompilable }
            groups.append(text)
            out += "("
          } else {
            throw .notCompilable
          }
        } else {
          groups.append(nil)
          out += "("
        }
        try disjunction()
        guard peek() == ")" else { throw .notCompilable }
        i += 1
        out += ")"
      case "[":
        i += 1
        out += ICUPattern.emit(try charClass())
      case "\\":
        i += 1
        guard let e = peek() else { throw .notCompilable }
        if let set = classEscape(e) {
          i += 1
          emitSet(set)
        } else {
          emitLiteral(try characterEscape(inClass: false))
        }
      case ".":
        i += 1
        emitSet(ICUPattern.dot)
      default:
        guard !Self.isSyntax(c) else { throw .notCompilable }
        i += 1
        emitLiteral(c.value)
      }
    }

    func isGroupName(_ name: String.UnicodeScalarView) -> Bool {
      guard let f = name.first else { return false }
      func word(_ c: Unicode.Scalar) -> Bool {
        (c.value >= 0x41 && c.value <= 0x5a) || (c.value >= 0x61 && c.value <= 0x7a) || c == "_"
      }
      return word(f) && name.dropFirst().allSatisfy { word($0) || Self.isDigit($0) }
    }

    enum ClassAtom {
      case char(UInt32)
      case set(CodePointSet)
    }

    mutating func classAtom() throws(EngineError) -> ClassAtom {
      guard let c = peek() else { throw .notCompilable }
      if c == "\\" {
        i += 1
        guard let e = peek() else { throw .notCompilable }
        if let set = classEscape(e) {
          i += 1
          return .set(set)
        }
        return .char(try characterEscape(inClass: true))
      }
      i += 1
      return .char(c.value)
    }

    mutating func charClass() throws(EngineError) -> CodePointSet {
      var negate = false
      if peek() == "^" {
        negate = true
        i += 1
      }
      var ranges: [ClosedRange<UInt32>] = []
      var set = CodePointSet.empty
      while true {
        guard let c = peek() else { throw .notCompilable }
        if c == "]" {
          i += 1
          break
        }
        let a = try classAtom()
        if peek() == "-", let after = peek(1), after != "]" {
          i += 1
          let b = try classAtom()
          guard case .char(let lo) = a, case .char(let hi) = b, lo <= hi else { throw .notCompilable }
          ranges.append(lo...hi)
          continue
        }
        switch a {
        case .char(let v): ranges.append(v...v)
        case .set(let s): set = set.union(s)
        }
      }
      var result = set.union(CodePointSet(ranges: ranges))
      if ci { result = result.caseClosed }
      if negate { result = result.complement }
      return result
    }

    mutating func count() -> Int? {
      var v = 0
      var n = 0
      while let c = peek(), Self.isDigit(c) {
        v = min(v * 10 + Int(c.value - 0x30), Int(Int32.max))
        i += 1
        n += 1
      }
      return n > 0 ? v : nil
    }

    mutating func quantifier() throws(EngineError) {
      guard let c = peek() else { return }
      switch c {
      case "*", "+", "?":
        i += 1
        out.unicodeScalars.append(c)
      case "{":
        i += 1
        guard let lo = count() else { throw .notCompilable }
        var text = "{\(lo)"
        if peek() == "," {
          i += 1
          text += ","
          if let hi = count() {
            guard hi >= lo, hi <= ICUPattern.maxRepeat else { throw .notCompilable }
            text += "\(hi)"
          }
        }
        guard lo <= ICUPattern.maxRepeat, peek() == "}" else { throw .notCompilable }
        i += 1
        out += text + "}"
      default:
        return
      }
      if peek() == "?" {
        i += 1
        out += "?"
      }
    }
  }
}

final class ICURegex: @unchecked Sendable {
  private let proto: OpaquePointer
  let groups: [String?]

  static let timeLimit: Int32 = 10_000
  static let stackOverflow: HasalaUErrorCode = 0x10311
  static let timeOut: HasalaUErrorCode = 0x10312

  init(_ p: ICUPattern) throws(EngineError) {
    var status: HasalaUErrorCode = 0
    let units = Array(p.source.utf16)
    let re = units.withUnsafeBufferPointer { buf in
      uregex_open(buf.baseAddress, Int32(buf.count), 0, nil, &status)
    }
    guard status <= 0, let re else {
      if let re { uregex_close(re) }
      throw .notCompilable
    }
    var gstatus: HasalaUErrorCode = 0
    let count = uregex_groupCount(re, &gstatus)
    guard gstatus <= 0, Int(count) == p.groups.count else {
      uregex_close(re)
      throw .notCompilable
    }
    proto = re
    groups = p.groups
  }

  deinit { uregex_close(proto) }

  struct Match: Equatable {
    let range: Range<Int>
    let groups: [Range<Int>?]
  }

  func firstMatch(in text: [UInt16], timeLimit: Int32 = ICURegex.timeLimit) throws(EngineError) -> Match? {
    var status: HasalaUErrorCode = 0
    guard let re = uregex_clone(proto, &status), status <= 0 else { throw .matchFailed }
    defer { uregex_close(re) }
    uregex_setTimeLimit(re, timeLimit, &status)
    let buffer = text.isEmpty ? [0] : text
    let result: Match?? = buffer.withUnsafeBufferPointer { buf -> Match?? in
      uregex_setText(re, buf.baseAddress, Int32(text.count), &status)
      guard status <= 0 else { return .none }
      let found = uregex_find(re, 0, &status)
      guard status <= 0 else { return .none }
      guard found != 0 else { return .some(nil) }
      func span(_ g: Int32) -> Range<Int>? {
        var s: HasalaUErrorCode = 0
        let start = uregex_start(re, g, &s)
        let end = uregex_end(re, g, &s)
        guard s <= 0, start >= 0, end >= start else { return nil }
        return Int(start)..<Int(end)
      }
      guard let whole = span(0) else { return .none }
      let gs = (0..<groups.count).map { span(Int32($0 + 1)) }
      return .some(Match(range: whole, groups: gs))
    }
    guard let result else { throw status == Self.stackOverflow || status == Self.timeOut ? .limitExceeded : .matchFailed }
    return result
  }
}
