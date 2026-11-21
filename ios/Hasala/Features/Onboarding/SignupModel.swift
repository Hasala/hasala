import Foundation
import Observation

@MainActor
@Observable
final class SignupModel {
  private let account: AccountService
  private let unseenPhrase: any UnseenPhraseNoting
  private let accountCreated: () -> Void
  var path: [WelcomeRoute] = []
  var navigationPath: [WelcomeRoute] {
    get { path }
    set {
      if newValue.count < path.count { failure = nil }
      path = newValue
    }
  }

  var inviteText = "" {
    didSet {
      guard oldValue != inviteText else { return }
      invitePasted = false
      if inviteFromLink, InviteCode.normalize(inviteText) != linkCode {
        linkKey = nil
        inviteFromLink = false
        linkPasteboardChange = nil
      }
      if failure == .notInvited { failure = nil }
      pastedLinkRefused = false
    }
  }
  private(set) var inviteFromLink = false
  private var linkKey: String?
  private var linkCode: String?
  private(set) var invitePasted = false
  private(set) var pastedLinkRefused = false
  private(set) var linkPasteboardChange: Int?
  var clearPasteboard: @MainActor (Int) -> Void = { clearPastedPhrase(changeCount: $0) }

  var displayName = ""
  var email = ""
  var nameError: String?
  var emailError: String?

  var code = "" {
    didSet {
      guard !code.isEmpty, case .codeWrong = failure else { return }
      failure = nil
      wrongCode = ""
    }
  }
  private(set) var codeSentAt: Date?
  private(set) var wrongCode = ""
  private(set) var emailVerified = false
  private(set) var codeUsedUp = false

  var method: SignInMethod = .passkey {
    didSet { if passkeyRegistered, method != .passkey { method = .passkey } }
  }
  var newPassword = ""
  var confirmPassword = ""
  var passwordShown = false

  private(set) var phrase: RecoveryPhrase?
  var phraseRevealed = false {
    didSet {
      if phraseRevealed, phraseMasked { phraseRevealed = false }
      if phraseRevealed { phraseSeen = true }
    }
  }
  var phraseMasked = false {
    didSet { if phraseMasked { phraseRevealed = false } }
  }
  private(set) var phraseSeen = false

  private(set) var ticket: SignupTicket?
  private var ticketInvite: String?
  private(set) var replacing = false
  private(set) var profile: AccountProfile?
  private var passkeyTicketID: String?
  var passkeyRegistered: Bool { ticket != nil && passkeyTicketID == ticket?.id }
  private(set) var passkeyPRF = false
  private(set) var passkeySynced = false
  private(set) var wordsInSignup = false
  var wordsLater: Bool {
    !replacing && !wordsInSignup && method == .passkey && passkeyPRF && passkeySynced && passkeyRegistered
      && capabilities.contains(.viewPhrase)
  }
  var passkeyWithoutPRF: Bool { !replacing && method == .passkey && passkeyRegistered && !passkeyPRF }
  var wordsOnlyInSetup: Bool { !capabilities.contains(.viewPhrase) || method == .password || passkeyWithoutPRF }
  var busy = false
  var failure: AuthFailure?
  var now: () -> Date = { .now }

  var whoCanSeeOpen = false

  var capabilities: AccountCapabilities { account.capabilities }

  init(
    account: AccountService, unseenPhrase: any UnseenPhraseNoting = InMemoryUnseenPhrase(),
    accountCreated: @escaping () -> Void = {}
  ) {
    self.account = account
    self.unseenPhrase = unseenPhrase
    self.accountCreated = accountCreated
  }

  func go(_ route: WelcomeRoute) {
    failure = nil
    path.append(route)
  }

  func back() {
    failure = nil
    if !path.isEmpty { path.removeLast() }
  }

  var normalizedInvite: String { InviteCode.normalize(inviteText) }
  var inviteCode: InviteCode? { InviteCode(inviteText) }

  var inviteHint: String? {
    let n = normalizedInvite
    guard !n.isEmpty else { return nil }
    if !InviteCode.isAlphabet(n) || n.count > InviteCode.length { return "Invite codes are 24 letters and numbers." }
    return nil
  }

  func applyInviteLink(_ link: InviteLink, pasteboardChange: Int? = nil) {
    linkCode = link.code.value
    inviteText = link.code.value
    linkKey = link.linkKey
    inviteFromLink = true
    invitePasted = false
    linkPasteboardChange = pasteboardChange
  }

  func paste(_ text: String, pasteboardChange: Int? = nil) {
    if let link = InviteLink.parse(pasted: text) {
      applyInviteLink(link, pasteboardChange: pasteboardChange)
      return
    }
    inviteText = InviteCode.entryCharacters(text)
    invitePasted = true
  }

  func usePastedInvite(_ text: String, pasteboardChange: Int? = nil) {
    failure = nil
    pastedLinkRefused = false
    guard let link = InviteLink.parse(pasted: text) else {
      if InviteCode(InviteCode.entryCharacters(text)) != nil {
        paste(text)
      } else {
        pastedLinkRefused = true
      }
      path = [.invite]
      return
    }
    applyInviteLink(link, pasteboardChange: pasteboardChange)
    path = [.inviteReady]
  }

  func submitInvite() {
    guard inviteCode != nil else {
      failure = nil
      return
    }
    go(.aboutYou)
  }

  var aboutYouReady: Bool { !displayName.trimmingCharacters(in: .whitespaces).isEmpty && !email.isEmpty }

  var linkProvesAddress: Bool { inviteFromLink && linkKey != nil }

  private func reusableTicket(now: Date) -> SignupTicket? {
    guard let t = ticket, let invite = inviteCode, ticketInvite == invite.value, !t.isExpired(now: now),
      t.email == AccountFields.email(email), t.displayName == AccountFields.displayName(displayName)
    else { return nil }
    return t
  }

  var emailConfirmed: Bool {
    if let t = reusableTicket(now: .now) { return t.emailProven || emailVerified }
    guard let t = ticket, t.emailProven, linkProvesAddress, ticketInvite == inviteCode?.value else { return false }
    return t.email == AccountFields.email(email)
  }

  var emailHelp: String {
    if emailConfirmed {
      return ticket?.emailProven == true
        ? "Confirmed by your invite link. Security alerts go here."
        : "Confirmed by your code. Security alerts go here."
    }
    return linkProvesAddress
      ? "No code if it's where your invite went. Security alerts go here."
      : "We'll send a code to confirm it. Security alerts go here."
  }

  func submitAboutYou() async {
    nameError = AccountFields.displayName(displayName) == nil ? AuthFailure.badName.message : nil
    emailError = AccountFields.email(email) == nil ? AuthFailure.badEmail.message : nil
    guard nameError == nil, emailError == nil, let invite = inviteCode else { return }
    if let t = reusableTicket(now: .now) {
      go(t.emailProven || emailVerified ? .method : .verifyEmail)
      return
    }
    busy = true
    defer { busy = false }
    do {
      let t = try await account.beginSignup(code: invite, linkKey: linkProvesAddress ? linkKey : nil, email: email,
                                            displayName: displayName)
      ticket = t
      ticketInvite = invite.value
      clearPastedLink()
      emailVerified = false
      codeUsedUp = false
      email = t.email
      if t.emailProven {
        go(.method)
      } else {
        codeSentAt = .now
        code = ""
        wrongCode = ""
        go(.verifyEmail)
      }
    } catch .notInvited {
      failure = .notInvited
      if path.contains(.inviteReady) {
        path = [.invite]
      } else {
        path.removeAll { $0 == .aboutYou }
      }
    } catch {
      failure = error
    }
  }

  func resendCode() async {
    guard let ticket, !busy else { return }
    busy = true
    defer { busy = false }
    do {
      self.ticket = try await account.resendSignupCode(ticket)
      codeSentAt = .now
      code = ""
      wrongCode = ""
      emailVerified = false
      codeUsedUp = false
      failure = nil
    } catch {
      failure = error
    }
  }

  func codeState(now: Date) -> CodeCells.State {
    if codeUsedUp || failure == .codeExpired || ticket?.codeExpired(now: now) == true { return .expired }
    if case .codeWrong = failure { return .wrong }
    return .typing
  }

  func submitCode() async {
    guard let ticket, code.count == 6, !busy else { return }
    if emailVerified {
      code = ""
      go(.method)
      return
    }
    busy = true
    defer { busy = false }
    do {
      try await account.verifySignupEmail(ticket, code: code)
      guard self.ticket == ticket else { return }
      emailVerified = true
      code = ""
      go(.method)
    } catch {
      guard self.ticket == ticket else { return }
      if error == .codeExpired { codeUsedUp = true }
      wrongCode = error == .codeExpired ? "" : code
      failure = error
      code = ""
    }
  }

  func continueWithMethod() async {
    switch method {
    case .password:
      go(.password)
    case .passkey:
      await registerPasskey()
    }
  }

  private func registerPasskey() async {
    guard let ticket else { return }
    if ticket.isExpired(now: now()) {
      startAgain()
      return
    }
    if passkeyRegistered {
      if wordsLater {
        busy = true
        defer { busy = false }
        await finishWithoutWords()
        return
      }
      showPhraseIntro()
      return
    }
    busy = true
    defer { busy = false }
    do {
      let made = try await account.registerPasskey(ticket)
      passkeyTicketID = ticket.id
      method = .passkey
      passkeyPRF = made.prf
      passkeySynced = made.synced
      wordsInSignup = false
      if wordsLater {
        await finishWithoutWords()
        return
      }
      try startPhrase()
      go(.phraseIntro)
    } catch .unsupported {
      failure = .unsupported
      method = .password
    } catch {
      failure = error
    }
  }

  var passwordAssessment: PasswordAssessment {
    PasswordRules.assess(newPassword, personal: [displayName, email, email.split(separator: "@").first.map(String.init) ?? ""])
  }

  var passwordsMatch: Bool { !confirmPassword.isEmpty && confirmPassword == newPassword }
  var passwordReady: Bool { passwordAssessment.acceptable && passwordsMatch }

  func submitPassword() {
    guard passwordReady else { return }
    if !replacing, ticket?.isExpired(now: now()) == true {
      startAgain()
      return
    }
    showPhraseIntro()
  }

  func startReplacement() {
    replacing = true
    method = .passkey
    do {
      try startPhrase()
      failure = nil
    } catch {
      failure = error
    }
  }

  func showReplacementWords() {
    if phrase == nil { startReplacement() }
    guard phrase != nil else { return }
    go(.phraseShow)
  }

  private func showPhraseIntro(newPhrase: Bool = false) {
    do {
      if newPhrase || phrase == nil { try startPhrase() }
    } catch {
      failure = error
      return
    }
    go(.phraseIntro)
  }

  private func startPhrase() throws(AuthFailure) {
    phrase = try account.makeRecoveryPhrase()
    phraseRevealed = false
    phraseSeen = false
  }

  func finish() async {
    guard phraseSeen, let phrase, replacing || ticket != nil else { return }
    if !replacing, ticket?.isExpired(now: now()) == true {
      startAgain()
      return
    }
    busy = true
    defer { busy = false }
    let credential: NewCredential = method == .passkey ? .passkey : .password(newPassword)
    do {
      if replacing {
        profile = try await account.finishInterruptedSetup(phrase: phrase)
      } else if let ticket {
        profile = try await account.finishAccount(ticket, credential: credential, phrase: phrase)
      }
      unseenPhrase.noteSeen()
      self.phrase = nil
      linkKey = nil
      clearPastedLink()
      newPassword = ""
      confirmPassword = ""
      passwordShown = false
      go(.accountReady)
    } catch .codeExpired where !replacing {
      startAgain()
    } catch {
      failure = error
    }
  }

  private func clearPastedLink() {
    guard let change = linkPasteboardChange else { return }
    clearPasteboard(change)
    linkPasteboardChange = nil
  }

  private func finishWithoutWords() async {
    guard wordsLater, let ticket else { return }
    if ticket.isExpired(now: now()) {
      startAgain()
      return
    }
    do {
      profile = try await account.finishAccountWithoutWords(ticket)
      unseenPhrase.noteUnseen(at: now())
      self.phrase = nil
      linkKey = nil
      failure = nil
      accountCreated()
    } catch .codeExpired {
      startAgain()
    } catch .wordsInSignup {
      wordsInSignup = true
      showPhraseIntro(newPhrase: true)
    } catch {
      failure = error
    }
  }

  private func startAgain() {
    clearPastedLink()
    let reason: AuthFailure = phraseSeen ? .signupExpiredPhrase : .signupExpired
    phrase = nil
    phraseRevealed = false
    phraseSeen = false
    ticket = nil
    emailVerified = false
    codeUsedUp = false
    if let about = path.firstIndex(of: .aboutYou) { path = Array(path.prefix(through: about)) }
    failure = reason
  }
}
