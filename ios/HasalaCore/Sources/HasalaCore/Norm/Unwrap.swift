import CoreTime
import HasalaText

struct Forward {
  var from: String
  var subject: String
  var date: String
  var body: String
  var found: Bool
}

enum Unwrap {
  typealias Line = ArraySlice<Unicode.Scalar>

  static func asciiLower(_ c: Unicode.Scalar) -> Unicode.Scalar {
    c.value >= 0x41 && c.value <= 0x5a ? Unicode.Scalar(UInt8(c.value + 0x20)) : c
  }

  static func foldCI(_ c: Unicode.Scalar) -> Unicode.Scalar {
    switch c.value {
    case 0x17f: "s"
    case 0x212a: "k"
    default: asciiLower(c)
    }
  }

  static func hasWordCI(_ s: Line, _ i: Int, _ word: String) -> Bool {
    var k = i
    for w in word.unicodeScalars {
      guard k < s.endIndex, foldCI(s[k]) == w else { return false }
      k += 1
    }
    return true
  }

  static func skip(_ s: Line, _ i: Int, _ c: Unicode.Scalar) -> Int {
    var k = i
    while k < s.endIndex, s[k] == c { k += 1 }
    return k
  }

  static func isForwardMarker(_ s: Line) -> Bool {
    var i = skip(s, s.startIndex, " ")
    if hasWordCI(s, i, "begin forwarded message:") {
      i += 24
    } else {
      let dashes = skip(s, i, "-")
      guard dashes > i else { return false }
      i = skip(s, dashes, " ")
      guard hasWordCI(s, i, "forwarded message") else { return false }
      i = skip(s, i + 17, " ")
      let dashes2 = skip(s, i, "-")
      guard dashes2 > i else { return false }
      i = dashes2
    }
    return skip(s, i, " ") == s.endIndex
  }

  static func stripFwdSubject(_ subject: String) -> String {
    let s = NormText.scalars(subject)[...]
    var i = skip(s, 0, " ")
    guard hasWordCI(s, i, "fw") else { return subject }
    i += 2
    if i < s.endIndex, foldCI(s[i]) == "d" { i += 1 }
    i = skip(s, i, " ")
    guard i < s.endIndex, s[i] == ":" else { return subject }
    i = skip(s, i + 1, " ")
    return NormText.string(s[i...])
  }

  static let headerLabels = ["from", "to", "subject", "date", "reply-to", "cc", "sent"]

  static func headerLine(_ s: Line) -> (label: String, value: Line)? {
    let i = skip(s, s.startIndex, " ")
    for label in headerLabels where hasWordCI(s, i, label) {
      var k = skip(s, i + label.unicodeScalars.count, " ")
      guard k < s.endIndex, s[k] == ":" else { continue }
      k = skip(s, k + 1, " ")
      let value = s[k...]
      if value.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\u{2028}" || $0 == "\u{2029}" }) { return nil }
      let matched = s[i..<(i + label.unicodeScalars.count)]
      let lowered = matched.map { $0.value == 0x212a ? "k" : asciiLower($0) }
      return (NormText.string(lowered), value)
    }
    return nil
  }

  static func unwrapForward(from: String, subject: String, body: String) -> Forward {
    let scalars = NormText.scalars(body)
    let lines = NormText.splitLines(scalars)

    guard let marker = lines.firstIndex(where: isForwardMarker) else {
      return Forward(from: from, subject: stripFwdSubject(subject), date: "", body: body, found: false)
    }

    var recFrom = ""
    var recSubject = ""
    var recDate = ""
    var end = marker + 1
    var sawHeader = false
    var i = marker + 1
    while i < lines.count {
      guard let m = headerLine(lines[i]) else {
        if sawHeader { break }
        i += 1
        continue
      }
      sawHeader = true
      var value = m.value.trimming(.unwrapTrim)
      if value.isEmpty {
        var j = i + 1
        while j < lines.count && lines[j].trimming(.unwrapTrim).isEmpty { j += 1 }
        if j < lines.count {
          value = lines[j].trimming(.unwrapTrim)
          i = j
        }
      }
      switch m.label {
      case "from": recFrom = NormText.string(value)
      case "subject": recSubject = NormText.string(value)
      case "date": recDate = NormText.string(value)
      default: break
      }
      i += 1
      end = i
    }

    var out = Forward(from: from, subject: subject, date: recDate, body: body, found: true)
    if !recFrom.isEmpty { out.from = recFrom }
    out.subject = recSubject.isEmpty ? stripFwdSubject(subject) : recSubject
    if sawHeader && end < lines.count {
      var joined: [Unicode.Scalar] = []
      for (k, l) in lines[end...].enumerated() {
        if k > 0 { joined.append("\n") }
        joined.append(contentsOf: l)
      }
      out.body = NormText.string(joined.trimming(.unwrapTrim))
    }
    return out
  }

  static let monthsLong = [
    "january", "february", "march", "april", "may", "june",
    "july", "august", "september", "october", "november", "december",
  ]
  static let monthsShort = monthsLong.map { String($0.unicodeScalars.prefix(3)) }
  static let weekdaysShort = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

  struct NaiveDateTime: Equatable {
    let year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int
  }

  static func make(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int) -> NaiveDateTime? {
    if mo < 1 || mo > 12 { return nil }
    if d < 1 || d > Civil.daysInMonth(year: Int64(y), month: mo) { return nil }
    if mi < 0 || mi >= 60 { return nil }
    if s < 0 || s >= 60 { return nil }
    if h < 0 || h >= 24 { return nil }
    return NaiveDateTime(year: y, month: mo, day: d, hour: h, minute: mi, second: s)
  }

  struct Cursor {
    let s: [Unicode.Scalar]
    var i = 0

    static func isDigit(_ c: Unicode.Scalar) -> Bool { c.value >= 0x30 && c.value <= 0x39 }
    static func isLetter(_ c: Unicode.Scalar) -> Bool {
      (c.value >= 0x41 && c.value <= 0x5a) || (c.value >= 0x61 && c.value <= 0x7a)
    }

    mutating func digits(_ min: Int, _ max: Int) -> Int? {
      var n = 0
      var v = 0
      while n < max, i < s.count, Self.isDigit(s[i]) {
        v = v * 10 + Int(s[i].value - 0x30)
        i += 1
        n += 1
      }
      return n >= min ? v : nil
    }

    mutating func letters(_ count: Int?) -> String? {
      var out = String.UnicodeScalarView()
      while i < s.count, Self.isLetter(s[i]), count.map({ out.count < $0 }) ?? true {
        out.append(asciiLower(s[i]))
        i += 1
      }
      if let count, out.count != count { return nil }
      return out.isEmpty ? nil : String(out)
    }

    mutating func lit(_ text: String) -> Bool {
      for c in text.unicodeScalars {
        guard i < s.count, s[i] == c else { return false }
        i += 1
      }
      return true
    }

    mutating func spaces() -> Bool {
      let start = i
      while i < s.count, s[i] == " " { i += 1 }
      return i > start
    }

    mutating func comma() -> Bool { lit(",") && spaces() }

    mutating func at() -> Bool { spaces() && lit("at") && spaces() }

    mutating func ampm() -> String? {
      if lit("AM") { return "AM" }
      if lit("PM") { return "PM" }
      return nil
    }

    var atEnd: Bool { i == s.count }
  }

  static func twelveHour(_ h: Int, _ ampm: String) -> Int? {
    if h < 0 || h > 12 { return nil }
    if ampm == "PM" && h < 12 { return h + 12 }
    if ampm == "AM" && h == 12 { return 0 }
    return h
  }

  static func layout(_ idx: Int, _ candidate: [Unicode.Scalar]) -> NaiveDateTime? {
    var c = Cursor(s: candidate)
    switch idx {
    case 0:
      guard let mon = c.letters(3), c.spaces(), let d = c.digits(1, 2), c.comma(), let y = c.digits(4, 4),
        c.at(), let h = c.digits(1, 2), c.lit(":"), let mi = c.digits(2, 2), c.spaces(),
        let ap = c.ampm(), c.atEnd
      else { return nil }
      guard let month = monthsShort.firstIndex(of: mon), let hh = twelveHour(h, ap) else { return nil }
      return make(y, month + 1, d, hh, mi, 0)
    case 1:
      guard let wd = c.letters(3), c.comma(), let mon = c.letters(3), c.spaces(), let d = c.digits(1, 2),
        c.comma(), let y = c.digits(4, 4), c.at(), let h = c.digits(1, 2), c.lit(":"),
        let mi = c.digits(2, 2), c.spaces(), let ap = c.ampm(), c.atEnd
      else { return nil }
      guard weekdaysShort.contains(wd), let month = monthsShort.firstIndex(of: mon), let hh = twelveHour(h, ap)
      else { return nil }
      return make(y, month + 1, d, hh, mi, 0)
    case 2, 3:
      guard let d = c.digits(1, 2), c.spaces(), let mon = c.letters(nil), c.spaces(), let y = c.digits(4, 4),
        c.at(), let h = c.digits(1, 2), c.lit(":"), let mi = c.digits(2, 2)
      else { return nil }
      var sec = 0
      if idx == 2 {
        guard c.lit(":"), let s = c.digits(2, 2) else { return nil }
        sec = s
      }
      guard c.atEnd, let month = monthsLong.firstIndex(of: mon) else { return nil }
      return make(y, month + 1, d, h, mi, sec)
    default:
      return nil
    }
  }

  static func parseForwardDate(_ s: String) -> NaiveDateTime? {
    var normalized = NormText.scalars(NormText.trimExplicit(s))
    for k in normalized.indices where normalized[k] == "\u{202F}" || normalized[k] == "\u{A0}" {
      normalized[k] = " "
    }
    var candidates = [normalized]
    if let lastSpace = normalized.lastIndex(of: " "), lastSpace > 0 {
      candidates.append(Array(normalized[0..<lastSpace].trimming(.unwrapTrim)))
    }
    for c in candidates {
      for i in 0..<4 {
        if let d = layout(i, c) { return d }
      }
    }
    return nil
  }
}
