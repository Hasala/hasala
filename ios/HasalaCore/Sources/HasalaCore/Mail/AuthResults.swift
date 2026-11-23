import HasalaText

public enum AuthResults {
  public enum Provider: String, Sendable, Equatable, CaseIterable {
    case gmail, outlook
  }

  public static let gmailAuthservID = "mx.google.com"
  public static let maxRawUnits = 256 * 1024
  public static let maxFieldLines = 512

  public enum Reason: String, Sendable, Equatable {
    case pass
    case noAR = "no_ar"
    case multipleAR = "multiple_ar"
    case notTopmost = "not_topmost"
    case fail
    case parseError = "parse_error"
    case noEOP = "no_eop"
    case notInbox = "not_inbox"
    case unknownSender = "unknown_sender"
    case noDMARCReject = "no_dmarc_reject"

    public var recorded: String {
      switch self {
      case .notInbox, .unknownSender, .noDMARCReject: Reason.fail.rawValue
      default: rawValue
      }
    }
  }

  public struct Verdict: Sendable, Equatable {
    public let trusted: Bool
    public let reason: Reason

    public init(trusted: Bool, reason: Reason) {
      self.trusted = trusted
      self.reason = reason
    }
  }

  public struct Analysis: Sendable, Equatable {
    public let verdict: Verdict
    public let domain: String?
    public let signature: String?

    public init(verdict: Verdict, domain: String?, signature: String? = nil) {
      self.verdict = verdict
      self.domain = domain
      self.signature = signature
    }
  }

  public static func gmailVerdict(_ rawHeaders: String) -> Verdict { analyze(rawHeaders).verdict }

  public static func outlookVerdict(_ rawHeaders: String) -> Verdict { analyzeOutlook(rawHeaders).verdict }

  public static func verdict(_ rawHeaders: String, provider: Provider) -> Verdict {
    analyze(rawHeaders, provider: provider).verdict
  }

  public static func verifiedDomain(_ rawHeaders: String, provider: Provider = .gmail) -> String? {
    analyze(rawHeaders, provider: provider).domain
  }

  public static func analyze(_ rawHeaders: String, provider: Provider) -> Analysis {
    switch provider {
    case .gmail: analyze(rawHeaders)
    case .outlook: analyzeOutlook(rawHeaders)
    }
  }

  static func untrusted(_ r: Reason) -> Analysis { Analysis(verdict: Verdict(trusted: false, reason: r), domain: nil) }

  public static func analyze(_ rawHeaders: String) -> Analysis {
    if rawHeaders.isEmpty { return untrusted(.noAR) }
    guard let fields = readFields(rawHeaders) else { return untrusted(.parseError) }

    let arValues = named(fields, "authentication-results").map(\.value)
    if arValues.isEmpty { return untrusted(.noAR) }

    let parsed = arValues.map(parseARValue)
    if parsed.contains(where: { !$0.readable }) { return untrusted(.parseError) }
    let gmail = parsed.indices.filter { parsed[$0].authservID.utf8.elementsEqual(gmailAuthservID.utf8) }
    if gmail.isEmpty { return untrusted(.noAR) }
    if gmail.count > 1 { return untrusted(.multipleAR) }
    guard gmail[0] == 0 else { return untrusted(.notTopmost) }

    let ar = parsed[0]
    let from = named(fields, "from")
    let fromDom = from.count == 1 ? string(fromDomain(from[0].value)) : ""
    guard
      let dkimPass = ar.methods.first(where: {
        same($0.method, "dkim") && same($0.result, "pass") && dkimAligned(dkimDomain($0), fromDom)
      })
    else { return untrusted(.fail) }
    if ar.methods.contains(where: { same($0.method, "dmarc") && !same(domainProp($0, "header.from"), fromDom) }) {
      return untrusted(.fail)
    }
    let domain = dkimDomain(dkimPass)
    let b = dkimPass.props.last { $0.key.utf8.elementsEqual("header.b".utf8) }.map { string(jsTrim(Array($0.value.unicodeScalars))) }
    return Analysis(verdict: Verdict(trusted: true, reason: .pass), domain: domain, signature: (b?.isEmpty ?? true) ? nil : b)
  }

  static let outlookAuthAs = Array("x-ms-exchange-organization-authas".unicodeScalars)
  static let outlookAuthSource = Array("x-ms-exchange-organization-authsource".unicodeScalars)
  static let outlookAuthAsValues = [Array("anonymous".unicodeScalars)]
  static let outlookAuthSourceSuffix = Array(".prod.outlook.com".unicodeScalars)
  static let outlookRequired: [(method: String, result: String)] = [("compauth", "pass"), ("dmarc", "pass")]

  public static func analyzeOutlook(_ rawHeaders: String) -> Analysis {
    if rawHeaders.isEmpty { return untrusted(.noAR) }
    guard let fields = readFields(rawHeaders) else { return untrusted(.parseError) }

    let parsed = named(fields, "authentication-results").map { parseARValue($0.value) }
    if parsed.contains(where: { !$0.readable }) { return untrusted(.parseError) }

    let ms = parsed.indices.filter { parsed[$0].microsoftForm }
    if ms.isEmpty { return untrusted(.noAR) }
    if ms.count > 1 { return untrusted(.multipleAR) }
    guard ms[0] == 0 else { return untrusted(.notTopmost) }
    let ar = parsed[0]

    let authAs = named(fields, outlookAuthAs).map { jsLower(jsTrim($0.value)) }
    let authSource = named(fields, outlookAuthSource).map { jsLower(jsTrim($0.value)) }
    guard authAs.count == 1, outlookAuthAsValues.contains(authAs[0]),
      authSource.count == 1, authSource[0].count >= outlookAuthSourceSuffix.count,
      Array(authSource[0].suffix(outlookAuthSourceSuffix.count)) == outlookAuthSourceSuffix,
      isLDHDomain(authSource[0])
    else { return untrusted(.noEOP) }

    for req in outlookRequired {
      let specs = ar.methods.filter { same($0.method, req.method) }
      guard specs.count == 1, same(specs[0].result, req.result) else { return untrusted(.fail) }
    }
    guard let dmarc = ar.methods.first(where: { same($0.method, "dmarc") }) else { return untrusted(.fail) }
    let domain = domainProp(dmarc, "header.from")
    if domain.isEmpty { return untrusted(.fail) }

    let from = named(fields, "from")
    guard from.count == 1, same(string(fromDomain(from[0].value)), domain) else { return untrusted(.fail) }

    return Analysis(verdict: Verdict(trusted: true, reason: .pass), domain: domain)
  }

  public static func analyzeOutlookSender(
    _ rawHeaders: String, inInbox: Bool, knownSenders: [String], rejectDomains: [String]
  ) -> Analysis {
    guard let fields = readFields(rawHeaders) else { return untrusted(.parseError) }
    guard inInbox else { return untrusted(.notInbox) }
    let from = named(fields, "from")
    guard from.count == 1, let address = fromAddress(from[0].value),
      knownSenders.contains(where: { same(ASCII.lowercased($0), address) })
    else { return untrusted(.unknownSender) }
    let domain = String(address[address.index(after: address.lastIndex(of: "@")!)...])
    guard rejectDomains.contains(where: { same(ASCII.lowercased($0), domain) }) else { return untrusted(.noDMARCReject) }
    return Analysis(verdict: Verdict(trusted: true, reason: .pass), domain: domain)
  }

  static func fromAddress(_ value: Scalars) -> String? {
    let (clean, readable) = stripComments(value)
    guard readable, let s = stripQuoted(clean), !s.contains(","), !s.contains(";") else { return nil }
    let addr: Scalars
    if let lt = s.firstIndex(of: "<") {
      guard let gt = s.firstIndex(of: ">"), gt > lt, s.filter({ $0 == "<" }).count == 1,
        s.filter({ $0 == ">" }).count == 1, !s[..<lt].contains("@"), jsTrim(s[(gt + 1)...]).isEmpty
      else { return nil }
      addr = Array(jsTrim(s[(lt + 1)..<gt]))
    } else {
      guard !s.contains(">") else { return nil }
      addr = Array(jsTrim(s))
    }
    guard addr.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7e }),
      let at = addr.firstIndex(of: "@"), at > 0, addr.filter({ $0 == "@" }).count == 1
    else { return nil }
    let lower = Array(ASCII.lowercased(string(addr)).unicodeScalars)
    guard isLDHDomain(Array(lower[(at + 1)...])) else { return nil }
    return string(lower)
  }

  static func stripQuoted(_ v: Scalars) -> Scalars? {
    var out: Scalars = []
    var inQuote = false
    var i = 0
    while i < v.count {
      let c = v[i]
      if inQuote {
        if c == "\\" {
          i += 2
          continue
        }
        if c == "\"" { inQuote = false }
      } else if c == "\"" {
        inQuote = true
        out.append(" ")
      } else {
        out.append(c)
      }
      i += 1
    }
    return inQuote ? nil : out
  }

  static func dkimAligned(_ d: String, _ from: String) -> Bool {
    if d.isEmpty || from.isEmpty { return false }
    let (d8, f8) = (Array(d.utf8), Array(from.utf8))
    if d8 == f8 { return true }
    func under(_ a: [UInt8], _ b: [UInt8]) -> Bool { a.count > b.count && a.suffix(b.count + 1).elementsEqual([0x2e] + b) }
    return under(f8, d8) || (f8.contains(0x2e) && under(d8, f8))
  }

  public static func fromDomain(_ value: String) -> String { string(fromDomain(Array(value.unicodeScalars))) }

  static func fromDomain(_ value: Scalars) -> Scalars {
    let (clean, ok) = stripComments(value)
    guard ok else { return [] }
    var lt = -1
    var gt = -1
    var lts = 0
    var gts = 0
    var inQuote = false
    var i = 0
    while i < clean.count {
      let c = clean[i]
      if inQuote {
        if c == "\\" {
          i += 1
        } else if c == "\"" {
          inQuote = false
        }
      } else if c == "\"" {
        inQuote = true
      } else if c == "<" {
        lt = i
        lts += 1
      } else if c == ">" {
        gt = i
        gts += 1
      } else if c == "," {
        return []
      }
      i += 1
    }
    guard lts <= 1, gts == lts, gt >= lt else { return [] }
    let addr = lts == 1 ? Array(clean[(lt + 1)..<gt]) : clean
    var at = -1
    inQuote = false
    i = 0
    while i < addr.count {
      let c = addr[i]
      if inQuote {
        if c == "\\" {
          i += 1
        } else if c == "\"" {
          inQuote = false
        }
      } else if c == "\"" {
        inQuote = true
      } else if c == "@" {
        at = i
      }
      i += 1
    }
    guard at >= 0 else { return [] }
    var lo = at + 1
    var hi = addr.count
    while lo < hi, addr[lo] == " " || addr[lo] == "\t" { lo += 1 }
    while hi > lo, addr[hi - 1] == " " || addr[hi - 1] == "\t" { hi -= 1 }
    var out: Scalars = []
    for c in addr[lo..<hi] {
      let l = c.value >= 0x41 && c.value <= 0x5a ? Unicode.Scalar(UInt8(c.value + 0x20)) : c
      let allowed = (l.value >= 0x61 && l.value <= 0x7a) || (l.value >= 0x30 && l.value <= 0x39) || l == "." || l == "-"
      guard allowed else { return [] }
      out.append(l)
    }
    while out.last == "." { out.removeLast() }
    return out
  }

  typealias Scalars = [Unicode.Scalar]

  struct Field {
    let name: Scalars
    let value: Scalars
  }

  struct MethodSpec {
    let method: String
    let result: String
    let props: [(key: String, value: String)]
  }

  struct ARHeader {
    let authservID: String
    let methods: [MethodSpec]
    let microsoftForm: Bool
    let readable: Bool
  }

  static func readFields(_ rawHeaders: String) -> [Field]? {
    guard rawHeaders.utf16.count <= maxRawUnits else { return nil }
    return unfold(Array(rawHeaders.unicodeScalars))
  }

  static func named(_ fields: [Field], _ name: Scalars) -> [Field] {
    fields.filter { jsLower(jsTrim($0.name)) == name }
  }

  static func named(_ fields: [Field], _ name: String) -> [Field] { named(fields, Array(name.unicodeScalars)) }

  static func unfold(_ raw: Scalars) -> [Field]? {
    var lines: [ArraySlice<Unicode.Scalar>] = []
    var start = 0
    var i = 0
    while i < raw.count {
      let c = raw[i]
      if c == "\r" || c == "\n" {
        lines.append(raw[start..<i])
        i += (c == "\r" && i + 1 < raw.count && raw[i + 1] == "\n") ? 2 : 1
        start = i
        continue
      }
      i += 1
    }
    lines.append(raw[start..<raw.count])

    var fields: [Field] = []
    var curName: Scalars? = nil
    var curValue: Scalars = []
    var foldLines = 0
    func flush() {
      if let n = curName { fields.append(Field(name: n, value: curValue)) }
      curName = nil
    }
    for line in lines {
      if line.isEmpty { break }
      if line.first == " " || line.first == "\t" {
        if curName != nil {
          foldLines += 1
          if foldLines > maxFieldLines { return nil }
          curValue.append(" ")
          curValue.append(contentsOf: jsTrimStart(line))
        }
        continue
      }
      guard let colon = line.firstIndex(of: ":") else {
        flush()
        continue
      }
      flush()
      curName = Array(line[line.startIndex..<colon])
      curValue = Array(jsTrimStart(line[(colon + 1)...]))
      foldLines = 0
    }
    flush()
    return fields
  }

  static func parseARValue(_ value: Scalars) -> ARHeader {
    let (clean, stripped) = stripComments(value)
    var readable = stripped
    let segments = splitTop(clean, ";")
    let idToken = tokenize(segments.first ?? []).first ?? []
    let authservID = string(jsLower(unquote(idToken)))
    let microsoftForm = idToken.contains("=")
    var methods: [MethodSpec] = []
    for seg in segments.dropFirst(microsoftForm ? 0 : 1) {
      let toks = tokenize(seg)
      if toks.isEmpty { continue }
      if toks.count == 1, jsLower(toks[0]) == Array("none".unicodeScalars) { continue }
      guard let spec = parseMethodSpec(toks) else {
        readable = false
        continue
      }
      methods.append(spec)
    }
    return ARHeader(authservID: authservID, methods: methods, microsoftForm: microsoftForm, readable: readable)
  }

  static func parseMethodSpec(_ tokens: [Scalars]) -> MethodSpec? {
    guard let head = splitKV(tokens[0]) else { return nil }
    let name = head.key.split(separator: "/", omittingEmptySubsequences: false).first.map(Array.init) ?? []
    let method = string(jsLower(jsTrim(name)))
    if method.isEmpty { return nil }
    let result = string(jsLower(jsTrim(unquote(head.value))))
    var props: [(key: String, value: String)] = []
    for t in tokens.dropFirst() {
      guard let kv = splitKV(t) else { return nil }
      props.append((string(jsLower(jsTrim(kv.key))), string(unquote(kv.value))))
    }
    return MethodSpec(method: method, result: result, props: props)
  }

  static func splitKV(_ token: Scalars) -> (key: Scalars, value: Scalars)? {
    guard let eq = token.firstIndex(of: "=") else { return nil }
    return (Array(token[0..<eq]), Array(token[(eq + 1)...]))
  }

  static func domainProp(_ spec: MethodSpec, _ key: String) -> String {
    guard let raw = spec.props.last(where: { $0.key.utf8.elementsEqual(key.utf8) })?.value else { return "" }
    var v = Array(jsTrim(Array(raw.unicodeScalars)))
    if let at = v.lastIndex(of: "@") { v = Array(v[(at + 1)...]) }
    let lower = jsLower(v)
    return isLDHDomain(lower) ? string(lower) : ""
  }

  static func dkimDomain(_ spec: MethodSpec) -> String {
    spec.props.contains { $0.key.utf8.elementsEqual("header.d".utf8) }
      ? domainProp(spec, "header.d") : domainProp(spec, "header.i")
  }

  static func isLDHDomain(_ v: Scalars) -> Bool {
    func alnum(_ c: Unicode.Scalar) -> Bool { (c.value >= 0x61 && c.value <= 0x7a) || (c.value >= 0x30 && c.value <= 0x39) }
    let labels = v.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.count >= 2 else { return false }
    for l in labels {
      guard let f = l.first, let last = l.last, l.count <= 63, alnum(f), alnum(last) else { return false }
      guard l.allSatisfy({ alnum($0) || $0 == "-" }) else { return false }
    }
    return true
  }

  static func stripComments(_ v: Scalars) -> (Scalars, readable: Bool) {
    var out: Scalars = []
    var depth = 0
    var inQuote = false
    var i = 0
    while i < v.count {
      let c = v[i]
      if inQuote {
        if c == "\\" {
          out.append(c)
          if i + 1 < v.count { out.append(v[i + 1]) }
          i += 2
          continue
        }
        if c == "\"" { inQuote = false }
        out.append(c)
      } else if depth > 0 {
        if c == "\\" {
          i += 2
          continue
        }
        if c == "\"" { return (out, false) }
        if c == "(" {
          depth += 1
        } else if c == ")" {
          depth -= 1
        }
      } else if c == ")" {
        return (out, false)
      } else if c == "(" {
        depth += 1
        out.append(" ")
      } else {
        if c == "\"" { inQuote = true }
        out.append(c)
      }
      i += 1
    }
    return (out, depth == 0 && !inQuote)
  }

  static func splitTop(_ v: Scalars, _ sep: Unicode.Scalar) -> [Scalars] {
    var parts: [Scalars] = []
    var cur: Scalars = []
    var inQuote = false
    var i = 0
    while i < v.count {
      let c = v[i]
      if inQuote {
        if c == "\\" {
          cur.append(c)
          if i + 1 < v.count { cur.append(v[i + 1]) }
          i += 2
          continue
        }
        if c == "\"" { inQuote = false }
        cur.append(c)
      } else if c == "\"" {
        inQuote = true
        cur.append(c)
      } else if c == sep {
        parts.append(cur)
        cur = []
      } else {
        cur.append(c)
      }
      i += 1
    }
    parts.append(cur)
    return parts
  }

  static func tokenize(_ seg: Scalars) -> [Scalars] {
    var out: [Scalars] = []
    var cur: Scalars = []
    var inQuote = false
    var i = 0
    while i < seg.count {
      let c = seg[i]
      if inQuote {
        if c == "\\" {
          cur.append(c)
          if i + 1 < seg.count { cur.append(seg[i + 1]) }
          i += 2
          continue
        }
        if c == "\"" { inQuote = false }
        cur.append(c)
      } else if c == "\"" {
        inQuote = true
        cur.append(c)
      } else if c == " " || c == "\t" {
        if !cur.isEmpty { out.append(cur) }
        cur = []
      } else {
        cur.append(c)
      }
      i += 1
    }
    if !cur.isEmpty { out.append(cur) }
    return out
  }

  static func unquote(_ s: Scalars) -> Scalars {
    let t = Array(jsTrim(s))
    guard t.count >= 2, t.first == "\"", t.last == "\"" else { return t }
    let inner = t[1..<(t.count - 1)]
    var out: Scalars = []
    var i = inner.startIndex
    while i < inner.endIndex {
      if inner[i] == "\\" && i + 1 < inner.endIndex {
        out.append(inner[i + 1])
        i += 2
      } else {
        out.append(inner[i])
        i += 1
      }
    }
    return out
  }

  static func jsTrim(_ s: some Collection<Unicode.Scalar>) -> ArraySlice<Unicode.Scalar> {
    let a = Array(s)
    var lo = 0
    var hi = a.count
    while lo < hi, ScalarSet.jsTrim.contains(a[lo]) { lo += 1 }
    while hi > lo, ScalarSet.jsTrim.contains(a[hi - 1]) { hi -= 1 }
    return a[lo..<hi]
  }

  static func jsTrimStart(_ s: ArraySlice<Unicode.Scalar>) -> ArraySlice<Unicode.Scalar> {
    var lo = s.startIndex
    while lo < s.endIndex, ScalarSet.jsTrim.contains(s[lo]) { lo += 1 }
    return s[lo...]
  }

  static func jsLower(_ s: some Collection<Unicode.Scalar>) -> Scalars {
    var out: Scalars = []
    out.reserveCapacity(s.count)
    for c in s {
      if c.isASCII {
        out.append(c.value >= 0x41 && c.value <= 0x5a ? Unicode.Scalar(UInt8(c.value + 0x20)) : c)
      } else {
        out.append(contentsOf: c.properties.lowercaseMapping.unicodeScalars)
      }
    }
    return out
  }

  static func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }

  static func string(_ s: some Sequence<Unicode.Scalar>) -> String {
    var v = String.UnicodeScalarView()
    v.append(contentsOf: s)
    return String(v)
  }
}
