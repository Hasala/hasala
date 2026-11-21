import CoreCategorize
import CoreExtract
import CoreJSON
import CoreMail
import CoreNorm
import CorePrimitives
import CoreReplay
import CoreTemplate
import CoreTime
import Foundation

public enum MailboxLimits {
  public static let maxMessageBytes = 1_000_000
  public static let maxResponseBytes = maxMessageBytes / 3 * 4 + 65_536
  public static let maxAmountMinor: Int64 = ExtractReading.maxAmountMinor
}

public struct MailGates: Sendable, Equatable, Codable {
  public var ar: String
  public var senderTrusted: Bool
  public var template: String?
  public var forwarded: Bool
  public var kind: String? = nil
  public var reader: String? = nil
}

public struct ParsedFields: Sendable, Equatable, Codable {
  public var amountMinor: Int64
  public var currency: String
  public var direction: String
  public var merchant: String
  public var last4: String
  public var postedAt: String
  public var precision: String
  public var isTransfer: Bool
}

public struct ParsedMail: Sendable, Equatable, Codable {
  public var messageID: String
  public var ingestID: String
  public var internalDateMs: Int64
  public var bank: String
  public var last4: String
  public var gates: MailGates
  public var fields: ParsedFields?
  public var dayPostedAt: String
  public var headerIDHash: String? = nil
  public var recipient: RecipientCheck? = nil
  public var spam: Bool? = nil
  public var senderDomain: String? = nil
  public var readerConfident: Bool? = nil
  public var held: Bool? = nil
}

public struct IngestDecision: Sendable, Equatable {
  public var category: String?
  public var source: JSONValue
  public init(category: String?, source: JSONValue) {
    self.category = category
    self.source = source
  }
  public static let none = IngestDecision(category: nil, source: .object(JSONObject([("kind", .string("none"))])))
}

public protocol IngestCategorizer: Sendable {
  func decide(merchantRaw: String, direction: String) -> IngestDecision
}

public struct NoCategorizer: IngestCategorizer {
  public init() {}
  public func decide(merchantRaw: String, direction: String) -> IngestDecision { .none }
}

public struct MailboxIngestDraft: Sendable, Equatable {
  public let messageID: String
  public let ingestID: String
  public let internalDateMs: Int64
  public let payload: JSONObject
  public let needsReview: Bool
}

public enum MessageDisposer {
  public enum Parse: Sendable, Equatable {
    case setAside(domain: String)
    case mail(ParsedMail)
    case interrupted
  }

  public static func parse(
    raw: [UInt8], messageID: String, internalDateMs: Int64, topLevelFrom: String,
    templates: [CompiledTemplate], bankDomains: [String], trusted: [String], provider: MailProviderID,
    linkedAddress: String?, spam: Bool, analyze: (String) -> AuthResults.Analysis
  ) -> Parse {
    var none: MailReaderState?
    return parse(
      raw: raw, messageID: messageID, internalDateMs: internalDateMs, topLevelFrom: topLevelFrom, templates: templates,
      bankDomains: bankDomains, trusted: trusted, provider: provider, linkedAddress: linkedAddress, spam: spam,
      reader: &none, analyze: analyze)
  }

  public static func parse(
    raw: [UInt8], messageID: String, internalDateMs: Int64, topLevelFrom: String,
    templates: [CompiledTemplate], bankDomains: [String], trusted: [String], provider: MailProviderID,
    linkedAddress: String?, spam: Bool, reader: inout MailReaderState?, analyze: (String) -> AuthResults.Analysis
  ) -> Parse {
    let headers = MailHeaders.headerBlock(rawMessage: raw)
    let analysis = analyze(headers)
    let verified = analysis.verdict.trusted ? analysis.domain : nil
    let norm = try? Normalizer.normalize(version: Normalizer.currentVersion, raw: raw, receivedAtMs: internalDateMs)

    var domains: [String] = []
    for d in [verified ?? "", BankDomains.domainOf(norm?.from ?? ""), BankDomains.domainOf(topLevelFrom)]
    where !d.isEmpty && !domains.contains(d) {
      domains.append(d)
    }
    guard domains.contains(where: { BankDomains.isMember($0, of: bankDomains) }) else {
      return .setAside(domain: domains.first ?? "")
    }

    let senderTrusted = verified.map { BankDomains.isMember($0, of: trusted) } ?? false
    let forwarded = norm?.forwarded ?? false
    let day = dayInstant(internalDateMs)
    var mail = ParsedMail(
      messageID: messageID, ingestID: "", internalDateMs: internalDateMs, bank: "", last4: "",
      gates: MailGates(ar: analysis.verdict.reason.recorded, senderTrusted: senderTrusted, template: nil, forwarded: forwarded),
      fields: nil, dayPostedAt: day)
    mail.ingestID = ingestID(raw)
    mail.headerIDHash = MessageIDEvidence.hash(headers: headers)
    mail.recipient = MailRecipients.check(
      linked: linkedAddress, headers: headers, provider: provider, signingDomain: verified, signature: analysis.signature)
    mail.spam = spam
    mail.senderDomain = domains.first { BankDomains.isMember($0, of: bankDomains) }

    guard let norm else { return .mail(mail) }
    let fromDomain = BankDomains.domainOf(norm.from)
    let learn = senderTrusted && !forwarded && !spam
    let readAs = fromDomain.isEmpty ? (mail.senderDomain ?? "") : fromDomain
    let input = ExtractInput(
      sender: learn ? (verified ?? readAs) : readAs, subject: norm.subject, text: norm.text,
      receivedAtMs: internalDateMs, listUnsubscribe: hasListUnsubscribe(headers))
    let setAsideDomain = mail.senderDomain ?? domains.first ?? ""
    let matching = templatesMatching(templates, domains: domains)
    for t in matching {
      let x: Extraction
      do {
        x = try t.execute(subject: norm.subject, normalizedBody: norm.text)
      } catch .cancelled {
        return .interrupted
      } catch {
        continue
      }
      guard x.matched else { continue }
      guard let posted = postedAt(x, template: t, internalDateMs: internalDateMs),
        var f = usableFields(x, posted: posted)
      else { continue }
      mail.bank = t.definition.bank
      var reading: ExtractReading?
      let verdict = CombinedReader.templateVerdict(
        input, amountMinor: f.amountMinor, currency: f.currency, direction: ExtractDirection(rawValue: f.direction),
        captured: f.merchant
      ) {
        guard reader != nil else { return nil }
        let (r, next) = CombinedReader.read(input, reader!.layouts)
        if learn && reader!.training { reader!.layouts = next }
        reading = r
        return r
      }
      guard let verdict else {
        reader?.bump(mail.bank) { $0.pendingSetAside += 1 }
        return .setAside(domain: setAsideDomain)
      }
      f.amountMinor = verdict.amountMinor
      f.currency = verdict.currency
      if verdict.held { mail.held = true }
      mail.last4 = x.last4
      mail.gates.template = "\(t.definition.id)@\(t.definition.version)"
      mail.fields = f
      if let reading {
        let agrees = reading.outcome == .transaction && reading.amountMinor == f.amountMinor && reading.currency == f.currency
        reader!.bump(mail.bank) {
          $0.templateHit += 1
          if agrees { $0.readerAgreed += 1 } else { $0.readerDisagreed += 1 }
        }
      }
      return .mail(mail)
    }
    if Task.isCancelled { return .interrupted }
    guard reader != nil else { return .mail(mail) }
    let (reading, next) = CombinedReader.read(input, reader!.layouts)
    if learn && reader!.training { reader!.layouts = next }
    let bank = matching.first?.definition.bank ?? ""
    switch reading.outcome {
    case .pending:
      reader!.bump(bank.isEmpty ? setAsideDomain : bank) { $0.pendingSetAside += 1 }
      return .setAside(domain: setAsideDomain)
    case .transaction:
      guard let f = readerFields(reading, stated: CombinedReader.statedDate(input), internalDateMs: internalDateMs)
      else { break }
      mail.bank = bank
      mail.last4 = f.last4
      mail.gates.reader = MailReaderState.marker
      mail.gates.kind = reading.kind == .other ? nil : reading.kind.rawValue
      mail.fields = f
      mail.readerConfident = reading.meetsFilingBar
      reader!.bump(bank.isEmpty ? setAsideDomain : bank) { $0.readerOnly += 1 }
    default:
      break
    }
    return .mail(mail)
  }

  static func templatesMatching(_ templates: [CompiledTemplate], domains: [String]) -> [CompiledTemplate] {
    templates.filter { t in
      t.definition.match.senderDomain.contains { want in
        domains.contains { BankDomains.isMember($0, of: [asciiLowered(want)]) }
      }
    }
  }

  static func hasListUnsubscribe(_ headers: String) -> Bool {
    headers.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }).contains {
      $0.utf8.count >= 17 && asciiLowered(String($0.prefix(17))) == "list-unsubscribe:"
    }
  }

  static let readerMerchantLimit = 200

  static func readerFields(_ r: ExtractReading, stated: ExtractStatedDate?, internalDateMs: Int64) -> ParsedFields? {
    guard r.isUsable, let amount = r.amountMinor, let currency = r.currency, let direction = r.direction,
      let posted = readerPostedAt(stated, internalDateMs: internalDateMs)
    else { return nil }
    let last4 = r.last4.flatMap { $0.utf8.count == 4 && $0.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 } ? $0 : nil } ?? ""
    return ParsedFields(
      amountMinor: amount, currency: currency, direction: direction.rawValue,
      merchant: String((r.merchant ?? "").prefix(readerMerchantLimit)), last4: last4, postedAt: posted.0, precision: posted.1,
      isTransfer: r.kind == .transferNotice)
  }

  static func readerPostedAt(_ stated: ExtractStatedDate?, internalDateMs: Int64) -> (String, String)? {
    guard let stated, let d = CivilDate(year: stated.year, month: stated.month, day: stated.day),
      d != LocalClock.localDate(internalDateMs)
    else { return Instant.iso(internalDateMs).map { ($0, "time") } }
    let start = LocalClock.startOfDay(d)
    if let m = stated.minuteOfDay { return Instant.iso(start + Int64(m) * 60_000).map { ($0, "time") } }
    return Instant.iso(start).map { ($0, "day") }
  }

  public static func unparsed(raw: [UInt8], messageID: String, internalDateMs: Int64, spam: Bool) -> ParsedMail {
    var mail = ParsedMail(
      messageID: messageID, ingestID: ingestID(raw), internalDateMs: internalDateMs, bank: "", last4: "",
      gates: MailGates(ar: AuthResults.Reason.parseError.rawValue, senderTrusted: false, template: nil, forwarded: false),
      fields: nil, dayPostedAt: dayInstant(internalDateMs))
    mail.spam = spam
    return mail
  }

  public static func finalize(
    _ m: ParsedMail, provider: MailProviderID, grantID: String, categorizer: any IngestCategorizer,
    texts: TextOverlap? = nil
  ) -> MailboxIngestDraft {
    let provenance = JSONValue.object(
      JSONObject([
        ("provider", .string(provider.rawValue)), ("grant_id", .string(grantID)), ("message_id", .string(m.messageID)),
      ]))
    guard let f = m.fields else {
      let gates = gatesJSON(m.gates, template: "none")
      var p = JSONObject([
        ("unparsed", .bool(true)), ("needs_review", .bool(true)), ("posted_at", .string(m.dayPostedAt)),
        ("posted_precision", .string("day")), ("merchant_raw", .string("")), ("last4", .string("")),
        ("category", .null), ("entry_method", .string("mailbox")), ("provenance", provenance), ("gates", gates),
      ])
      if let h = m.headerIDHash { p["dedupe"] = .object(JSONObject([("message_id", .string(h))])) }
      return MailboxIngestDraft(
        messageID: m.messageID, ingestID: m.ingestID, internalDateMs: m.internalDateMs, payload: p, needsReview: true)
    }

    let filesItself =
      m.gates.ar == AuthResults.Reason.pass.rawValue && m.gates.senderTrusted && !m.gates.forwarded
      && m.spam == false
      && m.recipient != nil && m.recipient != .mismatch
      && (m.gates.reader == nil || m.readerConfident == true)
      && m.held != true
      && texts?.twin(of: m) == nil
    let decided = categorizer.decide(merchantRaw: f.merchant, direction: f.direction)
    let decision = decided.category == nil ? refundDecision(m, f) ?? decided : decided

    var p = JSONObject([
      ("amount_minor", .string(String(f.amountMinor))), ("currency", .string(f.currency)),
      ("direction", .string(f.direction)), ("posted_at", .string(f.postedAt)),
      ("posted_precision", .string(f.precision)), ("merchant_raw", .string(f.merchant)), ("last4", .string(f.last4)),
    ])
    if let c = decision.category {
      p["category"] = .string(c)
      p["category_source"] = decision.source
    }
    p["needs_review"] = .bool(!filesItself)
    p["unparsed"] = .bool(false)
    p["tier"] = .string(m.gates.reader == nil ? "template" : "heuristic")
    p["entry_method"] = .string("mailbox")
    p["provenance"] = provenance
    if !m.bank.isEmpty { p["bank"] = .string(m.bank) }
    p["gates"] = gatesJSON(m.gates, template: m.gates.template ?? "none")
    if let h = m.headerIDHash { p["dedupe"] = .object(JSONObject([("message_id", .string(h))])) }
    return MailboxIngestDraft(
      messageID: m.messageID, ingestID: m.ingestID, internalDateMs: m.internalDateMs, payload: p,
      needsReview: !filesItself)
  }

  public enum RefusedProvenance: Sendable, CaseIterable {
    case whole, trimmed, none
  }

  public static let trimmedProvenanceLimit = 256

  public static func refusedShape(
    _ d: MailboxIngestDraft, keepGates: Bool, provenance keep: RefusedProvenance = .whole
  ) -> MailboxIngestDraft {
    var p = JSONObject([
      ("unparsed", .bool(true)), ("needs_review", .bool(true)), ("parse_error", .string("payload_refused")),
      ("posted_at", .string(dayInstant(d.internalDateMs))), ("posted_precision", .string("day")),
      ("merchant_raw", .string("")), ("last4", .string("")), ("category", .null), ("entry_method", .string("mailbox")),
    ])
    switch keep {
    case .whole:
      if let prov = d.payload["provenance"] { p["provenance"] = prov }
    case .trimmed:
      if let prov = trimmedProvenance(d.payload["provenance"]) { p["provenance"] = prov }
    case .none:
      break
    }
    if keepGates, let g = d.payload["gates"] { p["gates"] = g }
    return MailboxIngestDraft(
      messageID: d.messageID, ingestID: d.ingestID, internalDateMs: d.internalDateMs, payload: p, needsReview: true)
  }

  static func trimmedProvenance(_ v: JSONValue?) -> JSONValue? {
    guard let prov = v?.objectValue else { return nil }
    var fields: [(String, JSONValue)] = []
    for key in ["provider", "grant_id", "message_id"] {
      guard let s = prov[key]?.stringValue, !s.isEmpty, s.utf8.count <= trimmedProvenanceLimit else { return nil }
      fields.append((key, .string(s)))
    }
    return .object(JSONObject(fields))
  }

  public static let refundTemplates = [
    "dib.card-refund.v1", "dib.card-reversal.v1", "dib.sms.refund.v1", "dib.sms.reversal.v1", "enbd.sms.refund.v1",
  ]

  static func refundDecision(_ m: ParsedMail, _ f: ParsedFields) -> IngestDecision? {
    refundDecision(template: m.gates.template, direction: f.direction)
  }

  static func refundDecision(template ref: String?, direction: String) -> IngestDecision? {
    guard direction == "credit", let ref,
      let id = ref.split(separator: "@", maxSplits: 1).first.map(String.init), refundTemplates.contains(id)
    else { return nil }
    return IngestDecision(
      category: "refunds",
      source: .object(
        JSONObject([
          ("kind", .string("dictionary")), ("bundle", .string(DictionaryManifest.bundle)), ("entry", .string("template:\(id)")),
        ])))
  }

  static func gatesJSON(_ g: MailGates, template: String) -> JSONValue {
    var o = JSONObject([
      ("ar", .string(g.ar)), ("sender", .string(g.senderTrusted ? "trusted" : "untrusted")),
      ("template", .string(template)), ("forwarded", .bool(g.forwarded)),
    ])
    if let k = g.kind { o["kind"] = .string(k) }
    if let r = g.reader { o["reader"] = .string(r) }
    return .object(o)
  }

  public static func ingestID(_ raw: [UInt8]) -> String {
    Hex.encode(sha256(Data(raw)))
  }

  public static func dayInstant(_ epochMs: Int64) -> String {
    guard let d = LocalClock.localDate(epochMs), let s = Instant.iso(LocalClock.startOfDay(d)) else {
      return "1970-01-01T00:00:00.000Z"
    }
    return s
  }

  static func postedAt(_ x: Extraction, template t: CompiledTemplate, internalDateMs: Int64) -> (String, String)? {
    if x.postedAt.isEmpty {
      guard let s = Instant.iso(internalDateMs) else { return nil }
      return (s, "time")
    }
    guard let wallMs = try? parseInstantMs(x.postedAt) else { return nil }
    let layouts = t.definition.extract.filter { $0.field == "date" }.flatMap(\.layouts)
    let timed = layouts.map { $0.contains("hh") || $0.contains("HH") }
    let isMidnight = Civil.floorDiv(wallMs, Civil.msPerDay) * Civil.msPerDay == wallMs
    let dayOnly = !timed.contains(true) || (isMidnight && timed.contains(false))
    if dayOnly {
      guard let d = CivilDate(daysSinceEpoch: Civil.floorDiv(wallMs, Civil.msPerDay)) else { return nil }
      if LocalClock.localDate(internalDateMs) == d, let s = Instant.iso(internalDateMs) {
        return (s, "time")
      }
      guard let s = Instant.iso(LocalClock.startOfDay(d)) else { return nil }
      return (s, "day")
    }
    guard let s = Instant.iso(wallMs - LocalClock.offsetMs) else { return nil }
    return (s, "time")
  }

  static func usableFields(_ x: Extraction, posted: (String, String)) -> ParsedFields? {
    guard ExtractReading.usableAmount(x.amountMinor, currency: x.currency), ExtractDirection(rawValue: x.direction) != nil
    else { return nil }
    return ParsedFields(
      amountMinor: x.amountMinor, currency: x.currency, direction: x.direction, merchant: x.merchant, last4: x.last4,
      postedAt: posted.0, precision: posted.1, isTransfer: x.isTransfer)
  }
}
