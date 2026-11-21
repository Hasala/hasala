import CorePrimitives
import Foundation

public enum EmailNormError: Error, Equatable, Sendable {
  case badEmail
}

public enum EmailNorm {
  public static func normalize(_ input: String) throws(EmailNormError) -> String {
    var b = Array(input.utf8)
    guard b.allSatisfy({ $0 == 0x09 || (0x20...0x7e).contains($0) }) else { throw .badEmail }
    while let f = b.first, f == 0x20 || f == 0x09 { b.removeFirst() }
    while let l = b.last, l == 0x20 || l == 0x09 { b.removeLast() }
    for i in b.indices where (0x41...0x5a).contains(b[i]) { b[i] += 0x20 }
    guard (3...254).contains(b.count), b.allSatisfy({ $0 >= 0x21 }) else { throw .badEmail }
    let ats = b.indices.filter { b[$0] == 0x40 }
    guard ats.count == 1 else { throw .badEmail }
    let local = b[..<ats[0]]
    let domain = Array(b[(ats[0] + 1)...])
    guard (1...64).contains(local.count), (1...253).contains(domain.count) else { throw .badEmail }
    guard domain.first != 0x2e, domain.last != 0x2e, domain.contains(0x2e) else { throw .badEmail }
    return String(decoding: b, as: UTF8.self)
  }

  public static func hash(_ emailNorm: String) -> Data { sha256(Data(emailNorm.utf8)) }
}

public enum NameOK {
  public static func check(_ name: String) -> Bool {
    let s = Array(name.unicodeScalars)
    guard (1...64).contains(s.count) else { return false }
    for r in s {
      if r == " " { continue }
      switch r.properties.generalCategory {
      case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
        .nonspacingMark, .spacingMark, .enclosingMark,
        .decimalNumber, .letterNumber, .otherNumber,
        .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation,
        .finalPunctuation, .otherPunctuation,
        .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
        continue
      default:
        return false
      }
    }
    if s.first == " " || s.last == " " { return false }
    for i in s.indices.dropFirst() where s[i] == " " && s[i - 1] == " " { return false }
    return true
  }

  public static func fold(_ input: String) -> String {
    var out = String.UnicodeScalarView()
    var pendingSpace = false
    for r in input.precomposedStringWithCanonicalMapping.unicodeScalars {
      if r.properties.isWhitespace {
        pendingSpace = !out.isEmpty
        continue
      }
      if pendingSpace { out.append(" ") }
      pendingSpace = false
      out.append(r)
    }
    return String(out)
  }

  public static func normalize(_ input: String) -> String? {
    let n = fold(input)
    return check(n) ? n : nil
  }
}

public enum DisplayName {
  public enum Refusal: Error, Equatable, Sendable { case characters, length }

  public static func validate(_ input: String) -> Result<String, Refusal> {
    let name = NameOK.fold(input)
    guard name.utf8.count <= 256 else { return .failure(.characters) }
    let s = Array(name.unicodeScalars)
    guard (1...64).contains(s.count) else { return .failure(.length) }
    var letters = 0
    for (i, r) in s.enumerated() {
      switch r.properties.generalCategory {
      case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: letters += 1
      case .nonspacingMark, .spacingMark, .enclosingMark: break
      default:
        switch r.value {
        case 0x20, 0x27, 0x2019, 0x2d: break
        case 0x2e: if i + 1 < s.count, s[i + 1] != " " { return .failure(.characters) }
        default: return .failure(.characters)
        }
      }
    }
    guard letters > 0, NameOK.check(name) else { return .failure(.characters) }
    return .success(name)
  }
}
