import CoreCrypto
import CorePrimitives
import CoreResources
import Foundation

struct InviteCode: Equatable, Hashable, Sendable {
  static let length = 24
  let value: String

  static func normalize(_ raw: String) -> String {
    String(raw.uppercased().unicodeScalars.filter { $0 != " " && $0 != "-" }.map(Character.init))
  }

  static func isAlphabet(_ s: String) -> Bool {
    s.unicodeScalars.allSatisfy { ("A"..."Z").contains($0) || ("2"..."7").contains($0) }
  }

  init?(_ raw: String) {
    let n = Self.normalize(raw)
    guard n.unicodeScalars.count == Self.length, Self.isAlphabet(n) else { return nil }
    value = n
  }

  var grouped: String { Self.group(value) }

  static func group(_ normalized: String) -> String {
    var out = ""
    for (i, c) in normalized.enumerated() {
      if i > 0, i % 4 == 0 { out.append("-") }
      out.append(c)
    }
    return out
  }

  static let entryLimit = length + 8

  static func entryCharacters(_ raw: String) -> String {
    let kept = keptCharacters(raw)
    guard kept.count > entryLimit else { return kept }
    if let code = inviteLinkCode(in: raw) ?? codeRun(in: raw) { return code }
    return String(kept.prefix(entryLimit))
  }

  static func inviteLinkCode(in text: String) -> String? {
    for token in text.split(whereSeparator: { $0.isWhitespace || $0 == "<" || $0 == ">" || $0 == "\"" }) {
      guard token.hasPrefix("https://hasala.app/i") else { continue }
      if let link = InviteLink.parse(pasted: String(token)) { return link.code.value }
    }
    return nil
  }

  static func codeRun(in text: String) -> String? {
    let pattern = "(?<![A-Za-z0-9])[A-Za-z2-7]{4}(?:[- ]?[A-Za-z2-7]{4}){5}(?![A-Za-z0-9])"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let ns = text as NSString
    var best: (rank: Int, value: String)?
    for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
      let run = ns.substring(with: match.range)
      guard let code = InviteCode(run) else { continue }
      let rank = (run.contains("-") ? 2 : 0) + (run.contains(where: \.isLowercase) ? 0 : 1)
      if best.map({ rank > $0.rank }) ?? true { best = (rank, code.value) }
    }
    return best?.value
  }

  static func keptCharacters(_ raw: String) -> String {
    var out = String.UnicodeScalarView()
    for s in raw.uppercased().unicodeScalars {
      switch s.properties.generalCategory {
      case .dashPunctuation, .format, .control, .spaceSeparator, .lineSeparator, .paragraphSeparator: continue
      default: if s != "\u{2212}" { out.append(s) }
      }
    }
    return String(out)
  }
}

struct InviteCodeEntry: Equatable, Sendable {
  private(set) var characters: String
  private(set) var caret: Int

  init(_ raw: String = "") {
    characters = InviteCode.entryCharacters(raw)
    caret = characters.count
  }

  var text: String { InviteCode.group(characters) }

  var textCaret: Int { InviteCode.group(String(characters.prefix(caret))).utf16.count }

  static func edit(_ shown: String, range: NSRange, replacement: String, forward: Bool = false) -> InviteCodeEntry {
    let ns = shown as NSString
    let lower = range.location == NSNotFound ? ns.length : min(max(range.location, 0), ns.length)
    let upper = min(lower + max(range.length, 0), ns.length)
    var before = InviteCode.keptCharacters(ns.substring(to: lower))
    var after = InviteCode.keptCharacters(ns.substring(from: upper))
    let removed = InviteCode.keptCharacters(ns.substring(with: NSRange(location: lower, length: upper - lower)))
    var inserted = InviteCode.entryCharacters(replacement)
    let room = max(0, InviteCode.entryLimit - before.count - after.count)
    if inserted.count > room { inserted = String(inserted.prefix(room)) }
    if inserted.isEmpty, upper > lower, removed.isEmpty {
      if forward {
        if !after.isEmpty { after.removeFirst() }
      } else if !before.isEmpty {
        before.removeLast()
      }
    }
    var entry = InviteCodeEntry()
    entry.characters = before + inserted + after
    entry.caret = (before + inserted).count
    return entry
  }
}

struct InviteLink: Equatable, Sendable {
  var code: InviteCode
  var linkKey: String?

  static func parse(_ url: URL) -> InviteLink? {
    guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
      c.scheme == "https", c.host == "hasala.app", c.port == nil, c.user == nil, c.password == nil,
      c.query == nil
    else { return nil }
    let path = c.percentEncodedPath
    let fragment = c.percentEncodedFragment ?? ""
    if path == "/i" {
      guard let code = InviteCode(fragment.removingPercentEncoding ?? "") else { return nil }
      return InviteLink(code: code, linkKey: nil)
    }
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0].isEmpty, parts[1] == "i",
      let seg = String(parts[2]).removingPercentEncoding, let code = InviteCode(seg)
    else { return nil }
    let keyOK =
      fragment.utf8.count == 43
      && fragment.unicodeScalars.allSatisfy {
        ("A"..."Z").contains($0) || ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "-"
      }
    return InviteLink(code: code, linkKey: keyOK ? fragment : nil)
  }

  static func parse(pasted text: String) -> InviteLink? {
    guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
    return parse(url)
  }
}

enum AccountFields {
  static func email(_ raw: String) -> String? { try? EmailNorm.normalize(raw) }

  static let emailMaxBytes = 254

  static func nameTooLong(_ raw: String) -> Bool {
    guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
    if case .failure(.length) = DisplayName.validate(raw) { return true }
    return false
  }

  static func emailTooLong(_ raw: String) -> Bool {
    raw.trimmingCharacters(in: .whitespaces).utf8.count > emailMaxBytes
  }

  static func displayName(_ raw: String) -> String? {
    if case .success(let name) = DisplayName.validate(raw) { return name }
    return nil
  }
}

struct PasswordAssessment: Equatable, Sendable {
  enum Strength: Int, Equatable, Sendable, Comparable {
    case empty = 0, tooShort, weak, fair, strong

    static func < (a: Strength, b: Strength) -> Bool { a.rawValue < b.rawValue }
  }

  var strength: Strength
  var longEnough: Bool
  var notPersonal: Bool
  var notCommon: Bool
  var message: String?

  var acceptable: Bool { longEnough && notPersonal && notCommon && strength >= .fair }
}

enum PasswordRules {
  static let blocklist = PasswordPolicy.Blocklist(text: CoreResources.commonPasswords())

  static func assess(_ password: String, personal: [String] = []) -> PasswordAssessment {
    if password.isEmpty {
      return PasswordAssessment(strength: .empty, longEnough: false, notPersonal: true, notCommon: true, message: nil)
    }
    let violation = PasswordPolicy.check(password, blocklist: blocklist)
    let lowered = password.lowercased().filter { !$0.isWhitespace }
    let notPersonal = !personal.contains { p in
      let q = p.lowercased().filter { !$0.isWhitespace }
      guard q.count >= 3 else { return false }
      return lowered == q || (lowered.contains(q) && q.count * 2 >= lowered.count)
    }
    switch violation {
    case .tooShort:
      let typed = password.precomposedStringWithCanonicalMapping.unicodeScalars.count
      let message = typed == password.count
        ? "Too short. \(typed) of \(PasswordPolicy.minScalars) characters."
        : "Too short. Use \(PasswordPolicy.minScalars) characters or more."
      return PasswordAssessment(strength: .tooShort, longEnough: false, notPersonal: notPersonal, notCommon: true,
                                message: message)
    case .tooLong:
      return PasswordAssessment(strength: .weak, longEnough: false, notPersonal: notPersonal, notCommon: true,
                                message: "Use 128 characters or fewer.")
    case .tooCommon:
      return PasswordAssessment(strength: .weak, longEnough: true, notPersonal: notPersonal, notCommon: false,
                                message: "Too common. Try a longer phrase or let iPhone suggest one.")
    case nil:
      break
    }
    if !notPersonal {
      return PasswordAssessment(strength: .weak, longEnough: true, notPersonal: false, notCommon: true,
                                message: "Don't use your name or email.")
    }
    let scalars = password.unicodeScalars
    let classes = [
      scalars.contains { CharacterSet.lowercaseLetters.contains($0) },
      scalars.contains { CharacterSet.uppercaseLetters.contains($0) },
      scalars.contains { CharacterSet.decimalDigits.contains($0) },
      scalars.contains { !CharacterSet.alphanumerics.contains($0) },
    ].filter { $0 }.count
    let distinct = Set(scalars).count
    let strong = scalars.count >= 16 || (classes >= 3 && distinct >= 8)
    if distinct < 5 {
      return PasswordAssessment(strength: .weak, longEnough: true, notPersonal: true, notCommon: true,
                                message: "Too many repeats. Try a short phrase.")
    }
    return PasswordAssessment(
      strength: strong ? .strong : .fair, longEnough: true, notPersonal: true, notCommon: true,
      message: strong ? "Strong. Hard to guess, easy to type." : "Good. Longer is even better.")
  }
}

enum PhraseRules {
  static let wordCount = Phrase.wordCount

  static func generate() throws(AuthFailure) -> RecoveryPhrase {
    do {
      let e = try Phrase.generate(random: SystemRandom())
      defer { e.wipe() }
      return RecoveryPhrase(words: try Phrase.words(entropy: e))
    } catch {
      throw .unsupported
    }
  }

  static func validate(_ typed: String) -> Result<[String], AuthFailure> {
    let words = Phrase.normalize(typed)
    do {
      let e = try Phrase.entropy(words: words)
      e.wipe()
      return .success(words)
    } catch {
      return .failure(.badPhrase(message(error)))
    }
  }

  static func message(_ error: PhraseError) -> String {
    switch error {
    case .length(let n): "A recovery phrase has 12 words. This has \(n)."
    case .unknownWord(let i, let w): "Word \(i + 1), \u{201C}\(w)\u{201D}, isn't a recovery-phrase word."
    case .checksum: "These aren't a Hasala phrase. Two words may be swapped."
    case .entropyLength: "A recovery phrase has 12 words."
    }
  }

  static func suggestions(for prefix: String, limit: Int = 4) -> [String] {
    let p = prefix.lowercased().trimmingCharacters(in: .whitespaces)
    guard p.count >= 2 else { return [] }
    return Array(BIP39English.words.lazy.filter { $0.hasPrefix(p) }.prefix(limit))
  }

  static func isWord(_ w: String) -> Bool { BIP39English.words.contains(w) }
}
