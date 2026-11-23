import HasalaText

public enum MatchKind: String, Sendable, Codable, CaseIterable {
  case exact
  case startsWith = "starts_with"
  case contains
  case regex

  public var order: Int {
    switch self {
    case .exact: 0
    case .startsWith: 1
    case .contains: 2
    case .regex: 3
    }
  }

  public var minRunes: Int {
    switch self {
    case .exact: 2
    case .startsWith: 3
    case .contains: 4
    case .regex: 1
    }
  }
}

public struct RuleInput: Sendable, Equatable {
  public var id: String
  public var patterns: [String]
  public var match: String
  public var category: String
  public var priority: Int64
  public var enabled: Bool
  public var removed: Bool

  public init(id: String, patterns: [String], match: String, category: String, priority: Int64, enabled: Bool = true, removed: Bool = false) {
    self.id = id
    self.patterns = patterns
    self.match = match
    self.category = category
    self.priority = priority
    self.enabled = enabled
    self.removed = removed
  }
}

public struct DictEntry: Sendable, Equatable {
  public var pattern: String
  public var match: String
  public var category: String
  public var display: String?

  public init(pattern: String, match: String, category: String, display: String? = nil) {
    self.pattern = pattern
    self.match = match
    self.category = category
    self.display = display
  }
}

public struct Defect: Sendable, Equatable {
  public var id: String
  public var code: String

  public init(id: String, code: String) {
    self.id = id
    self.code = code
  }
}

public struct PreparedPattern: Sendable, Equatable {
  public let id: String
  public let pattern: String
  public let match: MatchKind
  public let category: String
  public let priority: Int64
  public let display: String?
  let bytes: [UInt8]
  let runes: Int

  init(id: String, pattern: String, match: MatchKind, category: String, priority: Int64, display: String? = nil) {
    self.id = id
    self.pattern = pattern
    self.match = match
    self.category = category
    self.priority = priority
    self.display = display
    self.bytes = Array(pattern.utf8)
    self.runes = pattern.unicodeScalars.count
  }

  func hits(_ subject: [UInt8]) -> Bool {
    switch match {
    case .exact: return subject == bytes
    case .startsWith: return subject.starts(with: bytes)
    case .contains: return Matcher.contains(subject, bytes)
    case .regex: return false
    }
  }

  static func order(_ a: PreparedPattern, _ b: PreparedPattern) -> Bool {
    if a.priority != b.priority { return a.priority < b.priority }
    if a.match.order != b.match.order { return a.match.order < b.match.order }
    if a.runes != b.runes { return a.runes > b.runes }
    let p = compareScalars(a.pattern, b.pattern)
    if p != 0 { return p < 0 }
    let c = compareScalars(a.category, b.category)
    if c != 0 { return c < 0 }
    return compareScalars(a.id, b.id) < 0
  }
}

public struct PreparedRules: Sendable {
  public let rules: [PreparedPattern]
  public let entries: [PreparedPattern]
  public let defects: [Defect]
  let exactIndex: [[UInt8]: Int]

  public static let empty = PreparedRules(rules: [], entries: [], defects: [], exactIndex: [:])
}

public struct MatchHit: Sendable, Equatable {
  public enum Source: String, Sendable { case rule, dictionary }
  public let source: Source
  public let category: String
  public let id: String
  public let pattern: String
  public let match: MatchKind
  public let display: String?
}

public enum Matcher {
  public static let maxRulePatternRunes = 512
  public static let maxDictPatternRunes = 64

  public static func prepare(rules: [RuleInput], entries: [DictEntry], categories: (any CategoryLookup)? = nil) -> PreparedRules {
    var defects: [Defect] = []
    var out: [PreparedPattern] = []
    for r in rules {
      if r.removed || !r.enabled { continue }
      out += prepareRule(r, categories, &defects)
    }
    var dict: [PreparedPattern] = []
    for e in entries {
      switch validateDictEntry(e) {
      case .defect(let d): defects.append(d)
      case .entry(let v):
        if let categories, let d = categoryDefect(v.category, categories) {
          defects.append(Defect(id: "\(v.match) \(v.pattern)", code: d))
          continue
        }
        dict.append(
          PreparedPattern(id: "\(v.match) \(v.pattern)", pattern: v.pattern, match: MatchKind(rawValue: v.match)!, category: v.category, priority: 0, display: v.display))
      }
    }
    out.sort(by: PreparedPattern.order)
    dict.sort(by: PreparedPattern.order)
    var exact: [[UInt8]: Int] = [:]
    for (i, e) in dict.enumerated() where e.match == .exact && exact[e.bytes] == nil { exact[e.bytes] = i }
    return PreparedRules(rules: out, entries: dict, defects: defects, exactIndex: exact)
  }

  private static func categoryDefect(_ id: String, _ categories: any CategoryLookup) -> String? {
    guard let info = categories.info(id) else { return "category_unknown" }
    return info.active ? nil : "category_retired"
  }

  private static func prepareRule(_ r: RuleInput, _ categories: (any CategoryLookup)?, _ defects: inout [Defect]) -> [PreparedPattern] {
    func bad(_ code: String) -> [PreparedPattern] {
      defects.append(Defect(id: r.id, code: code))
      return []
    }
    guard let match = MatchKind(rawValue: r.match) else { return bad("unknown_match") }
    let category = Canon.canonical(r.category)
    if category.isEmpty { return bad("empty_category") }
    if let categories, let d = categoryDefect(category, categories) { return bad(d) }
    if match == .regex { return bad("regex_not_supported") }
    var out: [PreparedPattern] = []
    for raw in r.patterns {
      if hasLineBreak(raw) { return bad("multiline") }
      let pattern = Canon.canonical(raw)
      if pattern.isEmpty { return bad("empty_pattern") }
      let n = pattern.unicodeScalars.count
      if n > maxRulePatternRunes { return bad("pattern_too_long") }
      if n < match.minRunes { return bad(match.rawValue + "_too_short") }
      out.append(PreparedPattern(id: r.id, pattern: pattern, match: match, category: category, priority: r.priority))
    }
    return out
  }

  public enum EntryCheck: Sendable, Equatable {
    case entry(DictEntry)
    case defect(Defect)
  }

  public static func validateDictEntry(_ e: DictEntry) -> EntryCheck {
    let id = "\(e.match) \(e.pattern) -> \(e.category)"
    func bad(_ code: String) -> EntryCheck { .defect(Defect(id: id, code: code)) }
    if e.match == "regex" { return bad("regex_not_allowed") }
    guard let kind = MatchKind(rawValue: e.match) else { return bad("unknown_match") }
    if hasLineBreak(e.pattern) || hasLineBreak(e.category) { return bad("multiline") }
    let pattern = Canon.canonical(e.pattern)
    let category = Canon.canonical(e.category)
    if pattern.isEmpty { return bad("empty_pattern") }
    if !pattern.unicodeScalars.contains(where: isAlnum) { return bad("pattern_not_alnum") }
    if pattern.unicodeScalars.contains(where: isUnprintable) { return bad("pattern_unprintable") }
    if category.isEmpty { return bad("empty_category") }
    let cn = category.unicodeScalars.count
    if cn < 2 { return bad("category_too_short") }
    if cn > 32 { return bad("category_too_long") }
    if !isDictCategory(category) { return bad("category_not_a_label") }
    let n = pattern.unicodeScalars.count
    if n > maxDictPatternRunes { return bad("pattern_too_long") }
    if n < kind.minRunes { return bad(kind.rawValue + "_too_short") }
    return .entry(DictEntry(pattern: pattern, match: e.match, category: category, display: e.display))
  }

  public static func firstHit(_ merchantRaw: String, _ prepared: PreparedRules, accept: (PreparedPattern) -> Bool = { _ in true })
    -> MatchHit?
  {
    let subject = Array(Canon.subject(merchantRaw).utf8)
    if subject.isEmpty { return nil }
    for r in prepared.rules where r.hits(subject) && accept(r) {
      return MatchHit(source: .rule, category: r.category, id: r.id, pattern: r.pattern, match: r.match, display: nil)
    }
    for e in prepared.entries where e.hits(subject) && accept(e) {
      return MatchHit(source: .dictionary, category: e.category, id: e.id, pattern: e.pattern, match: e.match, display: e.display)
    }
    return nil
  }

  public static func hits(_ pattern: PreparedPattern, merchantRaw: String) -> Bool {
    let subject = Array(Canon.subject(merchantRaw).utf8)
    return !subject.isEmpty && pattern.hits(subject)
  }

  static func contains(_ hay: [UInt8], _ needle: [UInt8]) -> Bool {
    if needle.isEmpty { return true }
    if needle.count > hay.count { return false }
    let first = needle[0]
    var i = 0
    let last = hay.count - needle.count
    while i <= last {
      if hay[i] == first {
        var j = 1
        while j < needle.count && hay[i + j] == needle[j] { j += 1 }
        if j == needle.count { return true }
      }
      i += 1
    }
    return false
  }

  static func hasLineBreak(_ s: String) -> Bool {
    s.unicodeScalars.contains { [0x0a, 0x0d, 0x0b, 0x0c, 0x85, 0x2028, 0x2029].contains($0.value) }
  }

  static func isUnprintable(_ s: Unicode.Scalar) -> Bool {
    switch s.properties.generalCategory {
    case .control, .format, .surrogate, .privateUse, .unassigned: true
    default: false
    }
  }

  static func isAlnum(_ s: Unicode.Scalar) -> Bool {
    switch s.properties.generalCategory {
    case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber, .letterNumber,
      .otherNumber:
      true
    default: false
    }
  }

  static func isDictCategory(_ s: String) -> Bool {
    let u = Array(s.utf8)
    guard (1...32).contains(u.count), ASCII.isLower(u[0]) || ASCII.isDigit(u[0]) else { return false }
    return u.allSatisfy { ASCII.isLower($0) || ASCII.isDigit($0) || [0x20, 0x5f, 0x2f, 0x26, 0x2d].contains($0) }
  }
}
