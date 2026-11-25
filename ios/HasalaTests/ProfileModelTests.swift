import HasalaDesign
import HasalaMocks
import HasalaModels
import Testing

@testable import Hasala

@MainActor
@Suite("Profile model")
struct ProfileModelTests {
  @Test func theStatusCardSaysWhatIsTrue() {
    let health = MayaLedger.state.mailbox
    let working = MailboxesSummary([MockMailbox.gmail], health: health, offer: nil)
    #expect(working.title == "Bank alerts are working")
    #expect(working.detail == "Last email 4 min ago\nEmirates NBD and DIB")
    #expect(working.hue == .mint)
    #expect(!working.needsYou)

    let signIn = MailboxesSummary([MockMailbox.needingSignIn(MockMailbox.gmail)], health: health,
                                  offer: .signInAgain(mailboxID: MockMailbox.gmail.id, provider: .gmail))
    #expect(signIn.title == "Sign in again")
    #expect(signIn.hue == .sand)
    #expect(signIn.needsYou)

    let outlook = MailboxesSummary([MockMailbox.needingSignIn(MockMailbox.outlook)], health: health,
                                   offer: .signInAgain(mailboxID: MockMailbox.outlook.id, provider: .outlook))
    #expect(outlook.title == "Sign in again")
    #expect(outlook.detail == "Microsoft ended access to maya.k@example.com.")
    #expect(outlook.hue == .sand)

    let none = MailboxesSummary([], health: health, offer: .connect)
    #expect(none.title == "Your email isn't connected")
    #expect(none.needsYou)
  }

  @Test func theSecurityRowShowsItsStatus() {
    let passkey = MockAccountService.securityState(for: .passkey)
    #expect(ProfileSheet.securityStatus(passkey).text == "Protected")
    #expect(ProfileSheet.securityStatus(passkey).tone == .success)
    var passwordOnly = passkey
    passwordOnly.passkeys = []
    #expect(ProfileSheet.securityStatus(passwordOnly).text == "Password only")
    #expect(ProfileSheet.securityStatus(passwordOnly).tone == .warning)
    passwordOnly.frozen = FreezeInfo(by: .operator, when: nil)
    #expect(ProfileSheet.securityStatus(passwordOnly).text == "Frozen")
  }

  @Test func theFooterLeadsWithTheBuild() throws {
    let build = try BuildInfo(infoDictionary: [
      "CFBundleShortVersionString": "0.2.0", "CFBundleVersion": "1", "HasalaGitCommit": "unset",
      "HasalaEnvironment": "qa", "HasalaAPIBaseURL": "https://api.example.com", "HasalaGoogleClientID": "unset",
      "HasalaGoogleRedirectScheme": "unset", "HasalaGmailPubSubTopic": "unset",
      "HasalaOutlookClientID": "unset", "HasalaOutlookRedirectScheme": "msauth.app.hasala.ios",
    ])
    let footer = ProfileSheet.footer(build)
    #expect(footer.hasPrefix("Hasala QA · 0.2.0 ("))
    #expect(footer.hasSuffix(" · End\u{2011}to\u{2011}end encrypted, never sold"))
  }

  @Test func profileSettingsAndRules() {
    let app = AppModel(store: InMemoryLedger())
    let profile = ProfileViewModel(app: app)
    profile.setNotifications(.everything)
    #expect(profile.snapshot.prefs.notifications == .everything)
    #expect(profile.rules.first?.pattern == "\u{201C}carrefour\u{201D}")
    profile.setRule("r-zuma", enabled: false)
    #expect(profile.rules.first { $0.id == "r-zuma" }?.enabled == false)
    #expect(profile.rules.map(\.matches) == profile.rules.map(\.matches).sorted(by: >))
    #expect(profile.exportRows.count == app.store.state.txns.count)
  }

  @Test func aRuleLearnedTodaySaysSo() throws {
    let app = AppModel(store: InMemoryLedger())
    let profile = ProfileViewModel(app: app)
    #expect(!profile.rules.contains { $0.learnedToday })
    #expect(app.perform(.categorize("lulu", "groceries", learnRule: true, project: nil)))
    let learned = try #require(profile.rules.first { $0.learnedToday })
    #expect(learned.pattern == "\u{201C}lulu hypermarket dxb marina\u{201D}")
    #expect(learned.detail == "Exact match · Groceries · 0 matches")
    #expect(profile.snapshot.categoriesAndRules == "18 categories · 7 rules")
  }

  @Test func theMoneyRowsFollowTheLedger() {
    let app = AppModel(store: InMemoryLedger())
    let profile = ProfileViewModel(app: app)
    #expect(profile.snapshot.bills == "9 tracked · 3 to check")
    #expect(profile.snapshot.newBills == 1)
    #expect(app.perform(.trackCandidate("apple-bill")))
    #expect(profile.snapshot.bills == "10 tracked")
    #expect(profile.snapshot.newBills == 0)
    app.toggleAmountsHidden()
    #expect(profile.hidden)
    #expect(profile.snapshot.projects.rendered(hidden: profile.hidden) == "1 active")
  }

  @Test func thePlanRowShowsOverAssignedAndFollowsTheMonth() {
    let ledger = InMemoryLedger()
    let app = AppModel(store: ledger)
    let profile = ProfileViewModel(app: app)
    #expect(profile.planLine.rendered(hidden: false).hasSuffix(" ready to assign"))
    #expect(app.perform(.setBudget("dining", YearMonth(2026, 10), .aed(3_000_00))))
    let over = profile.planLine.rendered(hidden: false)
    #expect(over.hasSuffix(" over-assigned"))
    #expect(over.contains("400"))
    ledger.setNow(LocalDateTime(2026, 11, 2, 9, 0))
    #expect(profile.planLine.rendered(hidden: false) != over)
  }

  @Test func aBillCanBeStoppedFromItsPage() throws {
    let app = AppModel(store: InMemoryLedger())
    let bills = BillsViewModel(app: app)
    let axa = try #require(bills.detail("axa"))
    #expect(axa.isLate)
    bills.markPaid("axa")
    #expect(bills.detail("axa")?.state == .upcoming)
    #expect(bills.detail("axa")?.history.dropFirst().first?.title == "Wed 7 Oct")
    bills.stopTracking("axa")
    #expect(bills.detail("axa")?.isEnded == true)
    #expect(bills.snapshot.tracked == 8)
  }

  @Test func thePostersDrawTheSameGlyphAsTheRowAndHero() throws {
    let app = AppModel(store: InMemoryLedger())
    let looks = BillsViewModel(app: app).snapshot.needsALook
    let axa = try #require(looks.first { $0.billID == "axa" })
    let du = try #require(looks.first { $0.billID == "du" })
    #expect(BillsView.posterGlyph(axa) == .icon(axa.glyph.icon))
    #expect(BillsView.posterGlyph(du) == .icon(du.glyph.icon))
  }

  @Test func signingOutSaysTheDataStays() {
    #expect(AccountCopy.signOutMessage.contains("Your data stays here"))
    #expect(!AccountCopy.signOutMessage.contains("erased"))
  }

  @Test func accountsAddUp() {
    let app = AppModel(store: InMemoryLedger())
    let accounts = AccountsViewModel(app: app)
    #expect(accounts.snapshot.netWorth == .aed(227_568_00))
    #expect(accounts.snapshot.everydayTotal == .aed(38_163_00))
    #expect(!accounts.hidden)
    app.toggleAmountsHidden()
    #expect(accounts.hidden)
  }
}
