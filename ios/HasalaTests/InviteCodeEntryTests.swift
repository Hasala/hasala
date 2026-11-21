import Foundation
import Testing

@testable import Hasala

@Suite("Invite code field")
struct InviteCodeEntryTests {
  static let code = "ABCDEFGHIJKLMNOPQRSTUVWX"
  static let grouped = "ABCD-EFGH-IJKL-MNOP-QRST-UVWX"

  func type(_ keys: String, into start: InviteCodeEntry = InviteCodeEntry()) -> InviteCodeEntry {
    var e = start
    for k in keys {
      e = InviteCodeEntry.edit(e.text, range: NSRange(location: e.textCaret, length: 0), replacement: String(k))
    }
    return e
  }

  func backspace(_ shown: String, at: Int) -> InviteCodeEntry {
    InviteCodeEntry.edit(shown, range: NSRange(location: at - 1, length: 1), replacement: "")
  }

  @Test func fastTypingKeepsTheOrder() {
    var e = InviteCodeEntry()
    for (i, k) in Self.code.lowercased().enumerated() {
      e = type(String(k), into: e)
      let typed = String(Self.code.prefix(i + 1))
      #expect(e.characters == typed)
      #expect(e.text == InviteCode.group(typed))
      #expect(e.textCaret == e.text.utf16.count)
    }
    #expect(e.text == Self.grouped)
    #expect(InviteCode(e.characters)?.value == Self.code)
  }

  @Test func typedHyphensAndSpacesAreSkipped() {
    #expect(type("abcd-efgh ijkl-").text == "ABCD-EFGH-IJKL")
    #expect(type("ab-cd").text == "ABCD")
    #expect(type("-").text == "")
  }

  @Test func lowerCaseIsUpperCased() {
    #expect(type("a").text == "A")
    #expect(type("aBcDe").text == "ABCD-E")
    #expect(InviteCodeEntry("abcd efgh").text == "ABCD-EFGH")
  }

  @Test func eitherSideOfAHyphenIsTheSamePlace() {
    let before = InviteCodeEntry.edit("ABCD-EFGH", range: NSRange(location: 4, length: 0), replacement: "x")
    let after = InviteCodeEntry.edit("ABCD-EFGH", range: NSRange(location: 5, length: 0), replacement: "x")
    #expect(before == after)
    #expect(before.text == "ABCD-XEFG-H")
    #expect(before.textCaret == 6)
  }

  @Test func typingInTheMiddleStaysInOrder() {
    let start = InviteCodeEntry.edit("ABCD-EFGH", range: NSRange(location: 2, length: 0), replacement: "")
    #expect(start.textCaret == 2)
    let e = type("xyz", into: start)
    #expect(e.text == "ABXY-ZCDE-FGH")
    #expect(e.textCaret == 6)
  }

  @Test func keysLandInOrderWhereverTheCaretIs() {
    var rng = SplitMix64(seed: 0x4841_5341_4C41)
    let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567ABCXYZ- ")
    for _ in 0..<500 {
      let start = String((0..<Int(rng.next() % 25)).map { _ in alphabet[Int(rng.next() % 32)] })
      let shown = InviteCodeEntry(start).text
      let offset = Int(rng.next() % UInt64(shown.utf16.count + 1))
      let keys = String((0..<Int(1 + rng.next() % 12)).map { _ in alphabet[Int(rng.next() % UInt64(alphabet.count))] })

      var e = InviteCodeEntry.edit(shown, range: NSRange(location: offset, length: 0), replacement: "")
      e = type(keys, into: e)

      let ns = shown as NSString
      let head = InviteCode.entryCharacters(ns.substring(to: offset))
      let tail = InviteCode.entryCharacters(ns.substring(from: offset))
      let room = InviteCode.entryLimit - head.count - tail.count
      let expected = head + InviteCode.entryCharacters(keys).prefix(room) + tail
      #expect(e.characters == expected, "\(keys) at \(offset) of \(shown)")
      #expect(e.text == InviteCode.group(expected))
    }
  }

  @Test func typingPastTheLimitKeepsWhatIsThere() {
    let pasted = InviteCodeEntry.edit("", range: NSRange(location: 0, length: 0), replacement: Self.grouped)
    let e = type("ABCDEFGHIJKLMNOPQRST", into: pasted)
    #expect(e.characters == Self.code + "ABCDEFGH")
    #expect(e.characters.count == InviteCode.entryLimit)
    let mid = type("XY", into: InviteCodeEntry.edit(e.text, range: NSRange(location: 2, length: 0), replacement: ""))
    #expect(mid.characters == e.characters)
  }

  @Test(arguments: [
    "ABCDEFGHIJKLMNOPQRSTUVWX",
    "abcdefghijklmnopqrstuvwx",
    "ABCD-EFGH-IJKL-MNOP-QRST-UVWX",
    "abcd efgh ijkl mnop qrst uvwx",
    "  ABCD\u{2013}EFGH\u{2014}IJKL\u{00A0}MNOP\nQRST\u{200B}UVWX \n",
  ])
  func pastingACodeIntoTheEmptyField(_ pasted: String) {
    let e = InviteCodeEntry.edit("", range: NSRange(location: 0, length: 0), replacement: pasted)
    #expect(e.text == Self.grouped)
    #expect(e.characters == Self.code)
    #expect(e.textCaret == Self.grouped.utf16.count)
  }

  @Test func pastingOverTheWholeFieldReplacesIt() {
    let e = InviteCodeEntry.edit("ZZZZ-ZZ", range: NSRange(location: 0, length: 7), replacement: Self.grouped)
    #expect(e.text == Self.grouped)
  }

  @Test func pastingInTheMiddleInsertsThere() {
    let e = InviteCodeEntry.edit("ABCD-EF", range: NSRange(location: 5, length: 0), replacement: "x-y z")
    #expect(e.text == "ABCD-XYZE-F")
    #expect(e.textCaret == 8)
  }

  @Test func pastedInviteLinks() throws {
    let key = String(repeating: "k", count: 43)
    let link = try #require(InviteLink.parse(pasted: "  https://hasala.app/i/\(Self.grouped)#\(key)\n"))
    #expect(link.code.value == Self.code)
    #expect(link.linkKey == key)
    #expect(InviteLink.parse(pasted: Self.grouped) == nil)
    #expect(InviteLink.parse(pasted: "see https://hasala.app/i/\(Self.code)") == nil)
    #expect(InviteLink.parse(pasted: "https://example.com/i/\(Self.code)#\(key)") == nil)
  }

  @MainActor
  @Test func pasteButtonTakesACodeOrALink() throws {
    let m = SignupModel(account: MockAccountService())
    m.paste(" abcd efgh-ijkl mnop qrst uvwx\n")
    #expect(m.inviteCode?.value == Self.code)
    #expect(m.invitePasted)
    #expect(!m.inviteFromLink)

    let key = String(repeating: "k", count: 43)
    let other = SignupModel(account: MockAccountService())
    other.paste("https://hasala.app/i/\(Self.code)#\(key)")
    #expect(other.inviteCode?.value == Self.code)
    #expect(other.inviteFromLink)
    #expect(!other.invitePasted)
  }

  @MainActor
  @Test func typingAnotherCodeIsNoLongerThePastedOne() throws {
    let m = SignupModel(account: MockAccountService())
    m.paste(Self.code)
    #expect(m.invitePasted)
    m.paste(Self.code)
    #expect(m.invitePasted)
    m.inviteText = "XBCDEFGHIJKLMNOPQRSTUVWA"
    #expect(m.inviteCode != nil)
    #expect(!m.invitePasted)
    m.paste(Self.code)
    #expect(m.invitePasted)
  }

  @Test func deletingAtTheEndAcrossAHyphen() {
    var e = backspace("ABCD-E", at: 6)
    #expect(e.text == "ABCD")
    #expect(e.textCaret == 4)
    e = backspace(e.text, at: e.textCaret)
    #expect(e.text == "ABC")
    #expect(e.textCaret == 3)
  }

  @Test func deletingJustAfterAHyphen() {
    let e = backspace("ABCD-EFGH", at: 5)
    #expect(e.text == "ABCE-FGH")
    #expect(e.textCaret == 3)
  }

  @Test func forwardDeleteJustBeforeAHyphen() {
    let e = InviteCodeEntry.edit("ABCD-EFGH", range: NSRange(location: 4, length: 1), replacement: "", forward: true)
    #expect(e.text == "ABCD-FGH")
    #expect(e.textCaret == 4)
  }

  @Test func deletingASelectionAcrossAHyphen() {
    let e = InviteCodeEntry.edit("ABCD-EFGH", range: NSRange(location: 2, length: 5), replacement: "")
    #expect(e.text == "ABGH")
    #expect(e.textCaret == 2)
  }

  @Test func deletingInAnEmptyFieldDoesNothing() {
    let e = InviteCodeEntry.edit("", range: NSRange(location: 0, length: 0), replacement: "")
    #expect(e == InviteCodeEntry())
  }

  @Test func outOfRangeEditsAreHeldToTheText() {
    let e = InviteCodeEntry.edit("ABCD", range: NSRange(location: 9, length: 3), replacement: "e")
    #expect(e.text == "ABCD-E")
  }

  @Test func otherCharactersStaySoTheHintCanSayWhy() {
    #expect(type("abc1").text == "ABC1")
    let m = SignupModel(account: MockAccountService())
    m.inviteText = type("abc1").characters
    #expect(m.inviteHint == "Invite codes are 24 letters and numbers.")
  }
}

private struct SplitMix64 {
  var state: UInt64
  init(seed: UInt64) { state = seed }
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
