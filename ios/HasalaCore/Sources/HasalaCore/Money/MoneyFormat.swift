import HasalaText

public enum MoneyFormat {
  public static let minus = "\u{2212}"

  public static let exponentRange = 0...18

  public static func formatMinor(_ minor: Int64, exponent: Int = 2) -> String {
    let body = groupedBody(minor.magnitude, exponent: exponent)
    return minor < 0 ? minus + body : body
  }

  public static func formatMoney(_ minor: Int64, currency: String, exponent: Int = 2) -> String {
    currency.isEmpty ? formatMinor(minor, exponent: exponent) : "\(currency) \(formatMinor(minor, exponent: exponent))"
  }

  public enum Direction: Sendable { case debit, credit, unparsed }
  public enum Flow: Sendable, Equatable { case `in`, out, none }

  public static func signedMinor(_ direction: Direction, _ minor: Int64, exponent: Int = 2) -> (text: String, flow: Flow)
  {
    switch direction {
    case .unparsed: return ("\u{2014}", .none)
    case .credit: return ("+" + groupedBody(minor.magnitude, exponent: exponent), .in)
    case .debit: return (minus + groupedBody(minor.magnitude, exponent: exponent), .out)
    }
  }

  public static func minorToDraft(_ minor: Int64?, exponent: Int = 2) -> String {
    guard let minor else { return "" }
    let body = plainBody(minor.magnitude, exponent: exponent)
    return minor < 0 ? "-" + body : body
  }

  public enum Draft: Sendable, Equatable {
    case empty
    case amount(Int64)
    case refused(DraftRefusal)
  }

  public enum DraftRefusal: Sendable, Equatable {
    case negative
    case tooPrecise
    case notAnAmount
    case tooLarge
  }

  public static func parseMinorDraft(_ text: String, exponent: Int = 2) -> Draft {
    precondition(exponentRange.contains(exponent), "minor exponent out of range")
    let t = Array(text.trimming(.jsTrim).utf8)
    if t.isEmpty { return .empty }
    if t.first == 0x2d || t.starts(with: Array(minus.utf8)) { return .refused(.negative) }
    let point = t.firstIndex(of: 0x2e)
    let whole = t[..<(point ?? t.endIndex)]
    let fraction = point.map { t[(t.index(after: $0))...] } ?? []
    guard !whole.isEmpty, whole.allSatisfy(ASCII.isDigit), fraction.allSatisfy(ASCII.isDigit) else {
      return .refused(.notAnAmount)
    }
    if fraction.count > exponent {
      return .refused(.tooPrecise)
    }
    var v: Int128 = 0
    for d in whole {
      v = v * 10 + Int128(d - 0x30)
      if v > Int128(Int64.max) { return .refused(.tooLarge) }
    }
    for _ in 0..<exponent { v *= 10 }
    var frac: Int128 = 0
    for k in 0..<exponent {
      frac = frac * 10 + (k < fraction.count ? Int128(fraction[fraction.startIndex + k] - 0x30) : 0)
    }
    guard let out = Int64(exactly: v + frac) else { return .refused(.tooLarge) }
    return .amount(out)
  }

  private static func split(_ magnitude: UInt64, exponent: Int) -> (whole: String, fraction: String) {
    precondition(exponentRange.contains(exponent), "minor exponent out of range")
    guard exponent > 0 else { return (String(magnitude), "") }
    var scale: UInt64 = 1
    for _ in 0..<exponent { scale *= 10 }
    let frac = String(magnitude % scale)
    return (String(magnitude / scale), String(repeating: "0", count: exponent - frac.utf8.count) + frac)
  }

  private static func groupedBody(_ magnitude: UInt64, exponent: Int) -> String {
    let (whole, fraction) = split(magnitude, exponent: exponent)
    let g = group(whole)
    return fraction.isEmpty ? g : "\(g).\(fraction)"
  }

  private static func plainBody(_ magnitude: UInt64, exponent: Int) -> String {
    let (whole, fraction) = split(magnitude, exponent: exponent)
    return fraction.isEmpty ? whole : "\(whole).\(fraction)"
  }

  private static func group(_ digits: String) -> String {
    let u = Array(digits.utf8)
    var out = [UInt8]()
    for (i, d) in u.enumerated() {
      if i > 0 && (u.count - i) % 3 == 0 { out.append(0x2c) }
      out.append(d)
    }
    return String(decoding: out, as: UTF8.self)
  }
}
