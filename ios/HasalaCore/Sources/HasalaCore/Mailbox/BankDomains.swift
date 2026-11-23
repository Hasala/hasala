import CoreMail
import CoreTemplate
import Foundation

public enum BankDomains {
  public static let maxTermsPerQuery = 20
  public static let overlapMs: Int64 = 2 * 86_400_000

  public static let sharedSuffixesV1: Set<String> = [
    "ac.ae", "co.ae", "gov.ae", "mil.ae", "name.ae", "net.ae", "org.ae", "pro.ae", "sch.ae", "com.sa", "gov.sa",
    "net.sa", "org.sa", "com.qa", "com.kw", "com.bh", "com.om", "com.eg", "ac.uk", "co.uk", "gov.uk", "org.uk",
    "com.au", "co.in", "com.pk", "co.za",
  ]

  public static func isQuerySafe(_ d: String) -> Bool {
    let labels = d.utf8.split(separator: 0x2e, omittingEmptySubsequences: false)
    guard labels.count >= 2 else { return false }
    for l in labels {
      if l.isEmpty { return false }
      for b in l where !((b >= 0x61 && b <= 0x7a) || (b >= 0x30 && b <= 0x39) || b == 0x2d) { return false }
    }
    return true
  }

  public static func effectiveTrusted(_ senderTrust: [String: Bool]) -> [String] {
    senderTrust.compactMap { d, trusted -> String? in
      guard trusted, isQuerySafe(d), !ForwarderDomains.contains(d), !sharedSuffixesV1.contains(d) else { return nil }
      return d
    }.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
  }

  public static func isMember(_ domain: String, of set: [String]) -> Bool {
    guard !domain.isEmpty else { return false }
    let d = Array(domain.utf8)
    for s in set {
      let sb = Array(s.utf8)
      if d == sb { return true }
      if d.count > sb.count, d[d.count - sb.count - 1] == 0x2e, Array(d.suffix(sb.count)) == sb { return true }
    }
    return false
  }

  public static func groups(_ domains: [String], size: Int = maxTermsPerQuery) -> [[String]] {
    let size = max(1, size)
    return stride(from: 0, to: domains.count, by: size).map {
      Array(domains[$0..<min($0 + size, domains.count)])
    }
  }

  public static func sinceSec(watermarkMs: Int64) -> Int64 {
    max(0, (watermarkMs - overlapMs) / 1000)
  }

  public static func domainOf(_ address: String) -> String {
    let read = AuthResults.fromDomain(address)
    if !read.isEmpty { return read }
    let u = Array(address.utf8)
    guard let at = u.lastIndex(of: 0x40) else { return "" }
    var out: [UInt8] = []
    for b in u[(at + 1)...] {
      if b == 0x3e || b == 0x20 || b == 0x09 || b == 0x0d || b == 0x0a || b == 0x22 || b == 0x29 { break }
      out.append(asciiLower(b))
    }
    while out.last == 0x2e { out.removeLast() }
    return String(decoding: out, as: UTF8.self)
  }

  public static func templateDomains(bank: String, templates: [TemplateDefinition]) -> [String] {
    var out = Set<String>()
    for t in templates where t.bank == bank {
      for d in t.match.senderDomain { out.insert(asciiLowered(d)) }
    }
    return out.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
  }

  public enum TypedDomainError: Error, Sendable, Equatable {
    case empty, notQuerySafe, forwarder, sharedSuffix, nonASCII, addressRequired
  }

  public static func normalizeTyped(_ typed: String) throws(TypedDomainError) -> String {
    var s = typed.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.unicodeScalars.contains(where: { !$0.isASCII }) { throw .nonASCII }
    if let at = s.lastIndex(of: "@") { s = String(s[s.index(after: at)...]) }
    s = asciiLowered(s)
    if s.hasSuffix(".") { s.removeLast() }
    if s.isEmpty { throw .empty }
    guard isQuerySafe(s) else { throw .notQuerySafe }
    if ForwarderDomains.contains(s) { throw .forwarder }
    if sharedSuffixesV1.contains(s) { throw .sharedSuffix }
    return s
  }

  public static func normalizeTypedAddress(_ typed: String) throws(TypedDomainError) -> String {
    let s = typed.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.unicodeScalars.contains(where: { !$0.isASCII }) { throw .nonASCII }
    if s.isEmpty { throw .empty }
    guard let at = s.lastIndex(of: "@"), at != s.startIndex else { throw .addressRequired }
    let domain = try normalizeTyped(String(s[s.index(after: at)...]))
    let address = String(s[..<at]) + "@" + domain
    guard OutlookSenders.isQuerySafe(address) else { throw .notQuerySafe }
    return address
  }
}
