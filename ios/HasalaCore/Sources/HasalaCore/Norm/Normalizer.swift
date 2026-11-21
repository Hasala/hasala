import CoreTime
import HasalaText

public enum PartUsed: String, Sendable, Equatable {
  case html, plain, raw
}

public enum DateSource: String, Sendable, Equatable {
  case forwardHeader = "forward_header"
  case received
}

public struct NormalizeResult: Sendable, Equatable {
  public let text: String
  public let partUsed: PartUsed
  public let charset: String
  public let subject: String
  public let from: String
  public let forwarded: Bool
  public let emailDate: String
  public let dateSource: DateSource
}

public enum NormalizeError: Error, Equatable, Sendable {
  case unknownVersion(Int)
  case noTextPart
  case unsupportedCharset(String)
  case tooDeep
}

public enum Normalizer {
  public static let currentVersion = 1

  public static func versions() -> [Int] { [1] }

  public static let maxMultipartDepth = 32

  public static func normalize(
    version: Int, raw: [UInt8], receivedAtMs: Int64
  ) throws(NormalizeError) -> NormalizeResult {
    guard version == currentVersion else { throw .unknownVersion(version) }
    let extracted: Extracted?
    do throws(MIMEFailure) {
      extracted = try extract(raw)
    } catch .unsupportedCharset(let label) {
      throw .unsupportedCharset(label)
    } catch .tooDeep {
      throw .tooDeep
    } catch {
      throw .noTextPart
    }
    guard let ex = extracted else { throw .noTextPart }

    let body = ex.part == .html ? stripHTML(NormText.scalars(ex.body)) : NormText.scalars(ex.body)
    let text = collapse(body)

    let fwd = Unwrap.unwrapForward(from: ex.from, subject: ex.subject, body: text)
    let (emailDate, dateSource) = emailDateOf(forwardDate: fwd.date, receivedAtMs: receivedAtMs)
    return NormalizeResult(
      text: fwd.body, partUsed: ex.part, charset: ex.charset, subject: fwd.subject, from: fwd.from,
      forwarded: fwd.found, emailDate: emailDate, dateSource: dateSource)
  }

  public static func normalizeText(version: Int, text: String) throws(NormalizeError) -> String {
    guard version == currentVersion else { throw .unknownVersion(version) }
    var lines: Scalars = []
    lines.reserveCapacity(text.unicodeScalars.count)
    var pendingCR = false
    for c in text.unicodeScalars {
      if pendingCR {
        pendingCR = false
        lines.append("\n")
        if c == "\n" { continue }
      }
      if c == "\r" {
        pendingCR = true
        continue
      }
      lines.append(c)
    }
    if pendingCR { lines.append("\n") }
    return collapse(lines)
  }

  static func emailDateOf(forwardDate: String, receivedAtMs: Int64) -> (String, DateSource) {
    if !forwardDate.isEmpty, let parsed = Unwrap.parseForwardDate(forwardDate) {
      return (format(parsed), .forwardHeader)
    }
    return (format(epochMs: receivedAtMs), .received)
  }

  struct Extracted {
    let body: String
    let part: PartUsed
    let charset: String
    let subject: String
    let from: String
  }

  struct Walker {
    var html = ""
    var plain = ""
    var htmlCharset = ""
    var plainCharset = ""

    mutating func walk(_ e: MIME.Entity, depth: Int = 0) throws(MIMEFailure) -> Bool {
      if MIME.hasPrefix(e.mediaType, "multipart/") {
        if depth >= Normalizer.maxMultipartDepth { throw .tooDeep }
        do throws(MIMEFailure) {
          var parts = try MIME.Multipart(body: e.rawBody, boundary: e.params["boundary"] ?? "")
          while let part = try parts.next() {
            let entity = try MIME.newEntity(part.header, part.rawBody)
            if entity.failed { return true }
            if try walk(entity, depth: depth + 1) { return true }
          }
        } catch .walkAbort {
          return true
        } catch .parse {
          return true
        }
        return false
      }

      let isHTML = e.mediaType == Bytes.of("text/html")
      guard isHTML || e.mediaType == Bytes.of("text/plain") else { return false }
      let text: String
      do throws(MIMEFailure) {
        text = try e.text()
      } catch .unsupportedCharset(let label) {
        throw .unsupportedCharset(label)
      } catch {
        return false
      }
      let cs = NormText.jsLower(NormText.trimExplicit(e.params["charset"] ?? ""))
      if isHTML {
        if html.isEmpty {
          html = text
          htmlCharset = cs
        }
      } else if plain.isEmpty {
        plain = text
        plainCharset = cs
      }
      return false
    }
  }

  static func extract(_ raw: [UInt8]) throws(MIMEFailure) -> Extracted? {
    let header: ParsedHeader
    do {
      header = try MIME.readHeader(raw[...], 0)
    } catch {
      return try rawFallback(raw)
    }

    let subject = try MIME.decodeWords(header.get("subject"))
    let from = MIME.bareAddress(try MIME.decodeWords(header.get("from")))

    let entity = try MIME.newEntity(header, raw[header.bodyStart...])
    var walker = Walker()
    let aborted = try walker.walk(entity)

    if !walker.html.isEmpty {
      return Extracted(body: walker.html, part: .html, charset: walker.htmlCharset, subject: subject, from: from)
    }
    if !walker.plain.isEmpty {
      return Extracted(body: walker.plain, part: .plain, charset: walker.plainCharset, subject: subject, from: from)
    }
    if aborted { return try rawFallback(raw) }
    return nil
  }

  static func rawFallback(_ raw: [UInt8]) throws(MIMEFailure) -> Extracted {
    let (subject, from) = try scanRawHeaders(raw)
    return Extracted(
      body: NormText.decodeUTF8(MIME.rawBodyAfterHeaders(raw)), part: .raw, charset: "", subject: subject, from: from)
  }

  static func scanRawHeaders(_ raw: [UInt8]) throws(MIMEFailure) -> (String, String) {
    let body = MIME.rawBodyAfterHeaders(raw)
    let headLen = body.count < raw.count ? raw.count - body.count : raw.count
    var s: [UInt8] = []
    s.reserveCapacity(headLen)
    var k = 0
    while k < headLen {
      if raw[k] == Bytes.cr && k + 1 < headLen && raw[k + 1] == Bytes.lf {
        s.append(Bytes.lf)
        k += 2
      } else {
        s.append(raw[k])
        k += 1
      }
    }
    var fields: [[UInt8]] = []
    var start = 0
    func line(_ l: ArraySlice<UInt8>) {
      if l.isEmpty { return }
      if (l.first == Bytes.sp || l.first == Bytes.tab) && !fields.isEmpty {
        fields[fields.count - 1].append(Bytes.sp)
        fields[fields.count - 1].append(contentsOf: MIME.trimExplicitBinary(l))
        return
      }
      fields.append(Array(l))
    }
    for i in 0..<s.count where s[i] == Bytes.lf {
      line(s[start..<i])
      start = i + 1
    }
    line(s[start..<s.count])

    var subject = ""
    var from = ""
    for f in fields {
      guard let i = Bytes.index(of: 0x3a, in: f) else { continue }
      let name = Bytes.latin1Lower(Array(MIME.trimExplicitBinary(f[0..<i])))
      let value = Array(f[(i + 1)...])
      if name == Bytes.of("subject") && subject.isEmpty {
        subject = try MIME.decodeWords(value)
      } else if name == Bytes.of("from") && from.isEmpty {
        from = MIME.bareAddress(try MIME.decodeWords(value))
      }
    }
    return (subject, from)
  }

  typealias Scalars = [Unicode.Scalar]

  static func hasCI(_ s: Scalars, _ i: Int, _ word: Scalars) -> Bool {
    guard i + word.count <= s.count else { return false }
    for k in 0..<word.count where Unwrap.foldCI(s[i + k]) != word[k] { return false }
    return true
  }

  static func has(_ s: Scalars, _ i: Int, _ word: Scalars) -> Bool {
    guard i + word.count <= s.count else { return false }
    for k in 0..<word.count where s[i + k] != word[k] { return false }
    return true
  }

  struct ForwardScan {
    let s: Scalars
    let c: Unicode.Scalar
    var ptr = 0
    mutating func next(from: Int) -> Int? {
      if ptr < from { ptr = from }
      while ptr < s.count && s[ptr] != c { ptr += 1 }
      return ptr < s.count ? ptr : nil
    }
  }

  static func removeElement(_ s: Scalars, _ tag: String) -> Scalars {
    let open = Array(("<" + tag).unicodeScalars)
    let close = Array(("</" + tag + ">").unicodeScalars)
    var closes: [Int] = []
    var k = 0
    while k + close.count <= s.count {
      if s[k] == "<" && hasCI(s, k, close) { closes.append(k) }
      k += 1
    }
    var closePtr = 0
    var gts = ForwardScan(s: s, c: ">")
    var out: Scalars = []
    out.reserveCapacity(s.count)
    var i = 0
    while i < s.count {
      if s[i] == "<", hasCI(s, i, open), let gt = gts.next(from: i + open.count) {
        while closePtr < closes.count && closes[closePtr] < gt + 1 { closePtr += 1 }
        if closePtr < closes.count {
          out.append(" ")
          i = closes[closePtr] + close.count
          continue
        }
      }
      out.append(s[i])
      i += 1
    }
    return out
  }

  static func replaceAll(_ s: Scalars, _ literal: String) -> Scalars {
    let w = Array(literal.unicodeScalars)
    var out: Scalars = []
    out.reserveCapacity(s.count)
    var i = 0
    while i < s.count {
      if s[i] == w[0] && has(s, i, w) {
        out.append("\n")
        i += w.count
        continue
      }
      out.append(s[i])
      i += 1
    }
    return out
  }

  static let blockTags = ["<br>", "<br/>", "</p>", "</tr>", "</div>"]

  static func stripHTML(_ input: Scalars) -> Scalars {
    var s = removeElement(input, "script")
    s = removeElement(s, "style")
    for t in blockTags { s = replaceAll(s, t) }
    var gts = ForwardScan(s: s, c: ">")
    var out: Scalars = []
    out.reserveCapacity(s.count)
    var i = 0
    while i < s.count {
      if s[i] == "<", i + 1 < s.count, s[i + 1] != ">", let gt = gts.next(from: i + 1) {
        out.append("\n")
        i = gt + 1
        continue
      }
      out.append(s[i])
      i += 1
    }
    return out
  }

  static let entities: [(Scalars, Unicode.Scalar)] = [
    (Array("&nbsp;".unicodeScalars), " "),
    (Array("&amp;".unicodeScalars), "&"),
    (Array("&lt;".unicodeScalars), "<"),
    (Array("&gt;".unicodeScalars), ">"),
    (Array("&quot;".unicodeScalars), "\""),
    (Array("&#39;".unicodeScalars), "'"),
  ]

  static func collapse(_ s: Scalars) -> String {
    var decoded: Scalars = []
    decoded.reserveCapacity(s.count)
    var i = 0
    outer: while i < s.count {
      let c = s[i]
      if c == "&" {
        for (e, r) in entities where has(s, i, e) {
          decoded.append(r)
          i += e.count
          continue outer
        }
      }
      decoded.append(c)
      i += 1
    }

    var out: Scalars = []
    out.reserveCapacity(decoded.count)
    var line: Scalars = []
    func flush() {
      let t = line.trimming(.unwrapTrim)
      if !t.isEmpty {
        if !out.isEmpty { out.append("\n") }
        out.append(contentsOf: t)
      }
      line.removeAll(keepingCapacity: true)
    }
    var inSpace = false
    for c in decoded {
      if c == "\n" {
        flush()
        inSpace = false
        continue
      }
      if c == " " || c == "\t" || c == "\u{A0}" {
        if !inSpace { line.append(" ") }
        inSpace = true
        continue
      }
      inSpace = false
      line.append(c)
    }
    flush()
    return NormText.string(out)
  }

  static func format(_ d: Unwrap.NaiveDateTime) -> String {
    let date = "\(Civil.pad(d.year, 4))-\(Civil.pad(d.month, 2))-\(Civil.pad(d.day, 2))"
    return "\(date)T\(Civil.pad(d.hour, 2)):\(Civil.pad(d.minute, 2)):\(Civil.pad(d.second, 2))Z"
  }

  static func format(epochMs: Int64) -> String {
    let days = Civil.floorDiv(epochMs, Civil.msPerDay)
    let (y, m, d) = Civil.civilFromDays(days)
    let rem = epochMs - days * Civil.msPerDay
    return format(
      Unwrap.NaiveDateTime(
        year: Int(y), month: m, day: d, hour: Int(rem / 3_600_000), minute: Int(rem / 60_000 % 60),
        second: Int(rem / 1000 % 60)))
  }
}
