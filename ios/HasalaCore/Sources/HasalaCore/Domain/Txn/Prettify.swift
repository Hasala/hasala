import CoreCategorize
import HasalaText

public enum MerchantDisplay {
  static let acronyms: [String] = [
    "dxb", "auh", "shj", "uae", "llc", "fze", "fzco", "fzc", "atm", "pos", "dewa", "sewa", "addc", "du", "enbd", "dib", "adcb",
    "fab", "rak", "uk", "us",
  ]

  public static func prettify(_ raw: String) -> String {
    let s = raw.collapsingGoSpace
    let hasLower = s.unicodeScalars.contains { $0.properties.isLowercase }
    let hasUpperASCII = s.utf8.contains { ASCII.isUpper($0) }
    guard !hasLower && hasUpperASCII else { return s }
    return s.split(separator: " ", omittingEmptySubsequences: true).map { tok -> String in
      let t = String(tok)
      if t.utf8.contains(where: ASCII.isDigit) { return t }
      let lower = ASCII.lowercased(t)
      if acronyms.contains(lower) { return ASCII.uppercased(t) }
      guard let first = lower.unicodeScalars.first else { return t }
      return ASCII.uppercased(String(first)) + String(lower.unicodeScalars.dropFirst())
    }.joined(separator: " ")
  }

  public static func name(raw: String, renamed: String?, dictionary: String?) -> String {
    if let renamed, !renamed.isEmpty { return renamed }
    if let dictionary, !dictionary.isEmpty { return dictionary }
    let p = prettify(raw)
    return p.isEmpty ? raw : p
  }
}
