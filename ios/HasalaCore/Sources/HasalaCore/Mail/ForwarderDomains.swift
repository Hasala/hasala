public enum ForwarderDomains {
  public static let v1: [String] = [
    "apple.com", "fastmail.com", "gmail.com", "google.com", "googlemail.com", "hotmail.com", "icloud.com",
    "live.com", "mac.com", "me.com", "messagingengine.com", "microsoft.com", "outlook.com", "proton.me",
    "protonmail.ch", "protonmail.com", "yahoo.com", "zoho.com",
  ]

  public static func contains(_ domain: String) -> Bool {
    var d = AuthResults.jsLower(AuthResults.jsTrim(Array(domain.unicodeScalars)))
    if d.last == "." { d.removeLast() }
    if d.isEmpty { return false }
    let bytes = Array(AuthResults.string(d).utf8)
    for f in v1 {
      let fb = Array(f.utf8)
      if bytes == fb { return true }
      if bytes.count > fb.count && bytes[bytes.count - fb.count - 1] == 0x2e && Array(bytes.suffix(fb.count)) == fb {
        return true
      }
    }
    return false
  }
}
