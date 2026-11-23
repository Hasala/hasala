import XCTest

final class LiveE2ETests: LiveE2ECase {
  @MainActor
  func test00_launch() throws {
    let app = launchLive()
    XCTAssertTrue(el(app, "stories.getStarted").waitForExistence(timeout: 30), "the stories did not open")
    XCTAssertTrue(el(app, "stories.signIn").exists)
    XCTAssertFalse(el(app, "boot.retry").exists)
    attach(app, "Launch · stories")
  }

  @MainActor
  func test01_pathB() throws {
    let invite = try XCTUnwrap(e2e.invite, "the harness passes a review invite (HASALA_E2E_INVITE)")
    var account = LiveE2EAccount.fresh()
    let app = launchLive()

    tap(app, "stories.getStarted", timeout: 30)
    type(app, "invite.field", invite)
    tap(app, "invite.continue")

    type(app, "about.name", account.name)
    type(app, "about.email", account.email)
    let before = capturedMailNames()
    tap(app, "about.continue")
    attach(app, "About you")

    XCTAssertTrue(el(app, "code.field").waitForExistence(timeout: 30), "the code screen did not open")
    let code = try waitForEmailCode(to: account.email, excluding: before)
    type(app, "code.field", code)

    tap(app, "method.password", timeout: 30)
    tap(app, "method.continue")
    typePassword(app, "password.new", account.password)
    typePassword(app, "password.confirm", account.password)
    XCTAssertTrue(app.staticTexts["Passwords match."].waitForExistence(timeout: 10), "the passwords do not match")
    attach(app, "Create a password")
    tap(app, "password.create")
    dismissSystemPrompts(app)

    tap(app, "phrase.start", timeout: 30)
    tap(app, "phrase.reveal")
    account.words = try readPhrase(app)
    try saveAccount(account)
    attach(app, "Recovery phrase")
    tap(app, "phrase.written")

    tap(app, "ready.continue", timeout: 90)

    tap(app, "bank.change", timeout: 30)
    tap(app, "bank.enbd")
    tap(app, "banks.done")
    let sample = el(app, "mail.sample")
    XCTAssertTrue(sample.waitForExistence(timeout: 60),
                  "no 'Use sample data': the review flag (#40 review_account) did not reach setup")
    attach(app, "Your email · sample offered")
    sample.tap()

    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 90), "the sample did not open Home")
    tap(app, "home.finish.notifications", timeout: 60)
    try recordNotificationsAllowed(allowNotifications(app))
    driveToHome(app)
    try markSignedIn(true)
    attach(app, "Home")

    assertMayaFigures(app)
    XCTAssertTrue(el(app, "home.sampleData").waitForExistence(timeout: 10),
                  "Home shows no 'Sample data' label on the review account")
  }

  @MainActor
  func test02_pathA_secondDevice() throws {
    let account = try loadAccount()
    let app = launchLive()
    signInWithPassword(app, account)

    let next = waitForAny(app, ["unlock.words", "phraseEntry.field"], timeout: 60)
    XCTAssertNotNil(next, "the unlock screen did not open after the password sign-in")
    if next == "unlock.words" { tap(app, "unlock.words") }
    attach(app, "Unlock · 12 words")
    type(app, "phraseEntry.field", account.words.joined(separator: " ") + "\n")
    tap(app, "unlock.open", timeout: 120)
    driveToHome(app)
    try markSignedIn(true)

    assertMayaFigures(app)
    continueAfterFailure = false

    app.tabBars.firstMatch.buttons["Review"].tap()
    tap(app, "review.tab.start")
    let position = el(app, "review.position")
    XCTAssertTrue(waitForLabel(position, containing: "1 of 6", timeout: 15),
                  "the deck reads '\(position.exists ? position.label : "nothing")'")
    tap(app, "review.pill.transfer")
    tap(app, "pick.transfer")
    XCTAssertTrue(waitForLabel(position, containing: "2 of 6", timeout: 15), "the card was not sorted")
    attach(app, "Review · one sorted")
    tap(app, "review.close")
    XCTAssertTrue(waitForLabel(el(app, "review.tab.count"), containing: MayaSample.afterOneSorted, timeout: 15),
                  "the Review tab does not say '\(MayaSample.afterOneSorted)'")

    RunLoop.current.run(until: Date().addingTimeInterval(10))
  }

  @MainActor
  func test03_rebind() throws {
    let account = try loadAccount()
    let app = launchLive()
    let first = waitForAny(app, ["home.hero.left", "stories.signIn"], timeout: 60)
    XCTAssertEqual(first, "home.hero.left", "A relaunched signed out: its session did not survive in the Keychain")
    signOut(app)
    XCTAssertTrue(el(app, "stories.signIn").waitForExistence(timeout: 30), "sign-out did not reach the stories")
    try markSignedIn(false)

    signInWithPassword(app, account)
    let back = waitForAny(app, ["home.hero.left", "unlock.words", "phraseEntry.field", "notifications.notNow"],
                          timeout: 90)
    XCTAssertTrue(back == "home.hero.left" || back == "notifications.notNow",
                  "signing in again on a bound iPhone asked for \(back ?? "nothing") instead of opening the kept data")
    driveToHome(app)
    try markSignedIn(true)
    attach(app, "Signed in again")

    if let refused = try requestWake() {
      if notificationsAllowed {
        XCTFail("simctl push was refused although A allowed notifications: \(refused)")
      } else {
        XCTExpectFailure("the simulator refuses a push to an app without notification permission") {
          XCTFail("simctl push was refused: \(refused)")
        }
      }
    }
    app.tabBars.firstMatch.buttons["Activity"].tap()
    XCTAssertTrue(app.staticTexts[MayaSample.afterOneSorted].waitForExistence(timeout: 60),
                  "B's sorted card did not reach A")
    XCTAssertTrue(waitForLabel(el(app, "activity.count"), containing: MayaSample.transactions, timeout: 5))
    attach(app, "Activity after the wake")
  }

  @MainActor
  func test04_delete() throws {
    let account = try loadAccount()
    let app = launchLive()
    XCTAssertEqual(waitForAny(app, ["home.hero.left", "stories.signIn"], timeout: 60), "home.hero.left",
                   "B relaunched signed out: its session did not survive in the Keychain")

    app.buttons["header.profile"].firstMatch.tap()
    if waitForAny(app, ["profile.delete"], timeout: 5) != nil {
      tap(app, "profile.delete")
    } else {
      tap(app, "profile.security")
      tap(app, "security.delete", timeout: 20)
    }
    tap(app, "delete.confirm", timeout: 20)
    let delete = app.alerts.buttons["Delete"].firstMatch
    XCTAssertTrue(delete.waitForExistence(timeout: 10), "the delete confirmation did not appear")
    delete.tap()

    typePassword(app, "confirm.password", account.password)
    attach(app, "Delete · confirm it's you")
    tap(app, "confirm.submit")
    XCTAssertTrue(el(app, "stories.getStarted").waitForExistence(timeout: 60), "deleting did not end on the stories")
    try markSignedIn(false)
    attach(app, "Deleted")
  }

  @MainActor
  func test05_deletedElsewhere() throws {
    XCTAssertTrue(wasLeftSignedIn, "A was not left signed in by test01_pathB / test03_rebind")
    let app = launchLive()
    XCTAssertTrue(el(app, "stories.getStarted").waitForExistence(timeout: 90),
                  "A did not wipe itself after the account was deleted elsewhere")
    attach(app, "Deleted elsewhere")
    try markSignedIn(false)
    app.terminate()
    let again = launchLive()
    XCTAssertTrue(el(again, "stories.getStarted").waitForExistence(timeout: 30))
  }

  @MainActor
  private func readPhrase(_ app: XCUIApplication) throws -> [String] {
    let grid = el(app, "phrase.grid")
    XCTAssertTrue(grid.waitForExistence(timeout: 10))
    var words: [Int: String] = [:]
    let deadline = Date().addingTimeInterval(10)
    while words.count < 12 && Date() < deadline {
      let cells = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Word '"))
      for cell in cells.allElementsBoundByIndex {
        if let m = cell.label.firstMatch(of: /^Word ([0-9]+), ([a-z]+)$/), let n = Int(m.1) {
          words[n] = String(m.2)
        }
      }
      if words.count < 12 { RunLoop.current.run(until: Date().addingTimeInterval(0.5)) }
    }
    let ordered = (1...12).compactMap { words[$0] }
    guard ordered.count == 12 else { throw LiveE2EError("read \(words.count) of the 12 words off the screen") }
    return ordered
  }
}
