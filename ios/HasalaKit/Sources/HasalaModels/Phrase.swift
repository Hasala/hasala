public struct MoneyPhrase: Sendable, Hashable, Codable, ExpressibleByStringLiteral {
  public enum Part: Sendable, Hashable, Codable {
    case text(String)
    case money(Money, style: MoneyStyle, hiddenGlyphs: Int)
    case signedMoney(Money, style: MoneyStyle, hiddenGlyphs: Int)
  }

  public var parts: [Part]

  public init(_ parts: [Part]) { self.parts = parts }
  public init(stringLiteral value: String) { self.parts = [.text(value)] }

  public func rendered(hidden: Bool) -> String {
    parts.map { part in
      switch part {
      case .text(let s):
        return s
      case .money(let m, let style, let glyphs):
        return hidden ? MoneyFormat.hidden(count: glyphs) : MoneyFormat.string(m, style: style)
      case .signedMoney(let m, let style, let glyphs):
        if hidden { return MoneyFormat.hidden(count: glyphs) }
        let sign = m.minor < 0 ? "\u{2212}" : "+"
        return sign + MoneyFormat.string(m, style: style)
      }
    }.joined()
  }

  public func spoken(hidden: Bool) -> String {
    var out: [String] = []
    for (i, part) in parts.enumerated() {
      switch part {
      case .text(let s):
        guard i + 1 < parts.count else { out.append(s); continue }
        switch parts[i + 1] {
        case .money(let m, _, _), .signedMoney(let m, _, _):
          let unit = m.currency + " "
          if s.hasSuffix("+") || s.hasSuffix("\u{2212}") || s.hasSuffix("-") {
            out.append(s)
          } else {
            out.append(s.hasSuffix(unit) ? String(s.dropLast(unit.count)) : s)
          }
        case .text:
          out.append(s)
        }
      case .money(let m, let style, _):
        out.append(hidden ? MoneyFormat.hiddenSpoken : MoneyFormat.spoken(m, style: style))
      case .signedMoney(let m, let style, _):
        out.append(hidden ? MoneyFormat.hiddenSpoken : MoneyFormat.spoken(m, style: style, sign: .signed))
      }
    }
    return out.joined()
  }
}

public extension MoneyPhrase.Part {
  static func amount(_ m: Money, _ style: MoneyStyle = .exact, hidden glyphs: Int = 4) -> Self {
    .money(m, style: style, hiddenGlyphs: glyphs)
  }
}
