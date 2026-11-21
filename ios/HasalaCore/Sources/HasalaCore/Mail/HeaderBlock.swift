public enum MailHeaders {
  public static func headerBlock(_ raw: String) -> String {
    let s = Array(raw.unicodeScalars)
    var i = 0
    while i + 1 < s.count {
      let a = s[i]
      let b = s[i + 1]
      if a == "\r" && b == "\n" && i + 3 < s.count && s[i + 2] == "\r" && s[i + 3] == "\n" { break }
      if (a == "\n" && b == "\n") || (a == "\r" && b == "\r") { break }
      i += 1
    }
    guard i + 1 < s.count else { return raw }
    var out = String.UnicodeScalarView()
    out.append(contentsOf: s[0..<i])
    return String(out)
  }

  public static func headerBlock(rawMessage: some Collection<UInt8>) -> String {
    var scalars = String(decoding: rawMessage, as: UTF8.self).unicodeScalars
    if scalars.first == "\u{FEFF}" { scalars.removeFirst() }
    return headerBlock(String(scalars))
  }
}
