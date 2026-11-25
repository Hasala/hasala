import XCTest

struct LiveE2EEnvironment {
  let api: String
  let mailDir: URL
  let stateDir: URL
  let invite: String?
  let device: String

  static func current() throws -> LiveE2EEnvironment {
    let env = ProcessInfo.processInfo.environment
    func value(_ name: String) -> String? {
      for key in [name, "TEST_RUNNER_" + name] {
        if let v = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { return v }
      }
      return nil
    }
    guard let api = value("HASALA_E2E_API") else {
      throw XCTSkip("A live end-to-end test: it runs only under ios/scripts/e2e-app.sh (TEST_RUNNER_HASALA_E2E_API is unset).")
    }
    guard let mail = value("HASALA_E2E_MAIL_DIR"), let state = value("HASALA_E2E_STATE") else {
      throw LiveE2EError("HASALA_E2E_API is set without HASALA_E2E_MAIL_DIR and HASALA_E2E_STATE")
    }
    return LiveE2EEnvironment(
      api: api, mailDir: URL(fileURLWithPath: mail, isDirectory: true),
      stateDir: URL(fileURLWithPath: state, isDirectory: true), invite: value("HASALA_E2E_INVITE"),
      device: value("HASALA_E2E_DEVICE") ?? "A")
  }
}

struct LiveE2EError: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

struct LiveE2EAccount: Codable, Equatable {
  var name: String
  var email: String
  var password: String
  var words: [String]

  static func fresh() -> LiveE2EAccount {
    let id = UUID().uuidString.lowercased()
    let salt = String(UUID().uuidString.lowercased().prefix(8))
    return LiveE2EAccount(
      name: "Maya Tester", email: "e2e+\(id)@example.test", password: "copper lantern \(salt) quietly", words: [])
  }
}

struct CapturedMail: Decodable {
  let to: String
  let subject: String
  let text: String
}

enum MayaSample {
  static let transactions = "26 transactions this month"
  static let toSort = "6 to sort"
  static let afterOneSorted = "5 to sort"
  static let bills = "9 tracked"
  static let project = "Japan trip"
}

class LiveE2ECase: XCTestCase {
  private(set) var e2e: LiveE2EEnvironment!
  private var monitoring = false

  override func setUpWithError() throws {
    try super.setUpWithError()
    continueAfterFailure = false
    e2e = try LiveE2EEnvironment.current()
  }

  static let promptButtons = [
    "Not Now", "Choose My Own Password", "Don\u{2019}t Allow", "Don't Allow", "Never for This Website",
  ]

  @MainActor
  func launchLive() -> XCUIApplication {
    if !monitoring {
      monitoring = true
      _ = addUIInterruptionMonitor(withDescription: "System prompts") { alert in
        for title in LiveE2ECase.promptButtons where alert.buttons[title].exists {
          alert.buttons[title].tap()
          return true
        }
        return false
      }
    }
    let app = XCUIApplication()
    app.launchEnvironment["HASALA_API_BASE_URL"] = e2e.api
    app.launchEnvironment["HASALA_LEDGER_NOW"] = "sample"
    app.launch()
    return app
  }

  @MainActor
  func labelled(_ app: XCUIApplication, containing text: String) -> XCUIElement {
    app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
  }

  @MainActor
  func typePassword(_ app: XCUIApplication, _ id: String, _ password: String,
                    file: StaticString = #filePath, line: UInt = #line) {
    let e = el(app, id)
    XCTAssertTrue(e.waitForExistence(timeout: 15), "\(id) is missing", file: file, line: line)
    e.tap()
    dismissSystemPrompts(app)
    let filled = (e.value as? String) ?? ""
    if !filled.isEmpty, filled != e.placeholderValue {
      e.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: filled.count + 2))
    }
    e.typeText(password)
  }

  @MainActor
  @discardableResult
  func dismissSystemPrompts(_ app: XCUIApplication) -> Bool {
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    for host in [app, springboard] {
      for title in Self.promptButtons {
        let b = host.buttons[title].firstMatch
        if b.exists, b.isHittable {
          b.tap()
          return true
        }
      }
    }
    return false
  }

  @MainActor
  @discardableResult
  func allowNotifications(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) -> Bool {
    let button = el(app, "notifications.allow")
    XCTAssertTrue(button.waitForExistence(timeout: 90), "the notifications sheet did not open", file: file, line: line)
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    var lastTap = Date.distantPast
    let deadline = Date().addingTimeInterval(30)
    repeat {
      for host in [springboard, app] {
        let allow = host.buttons["Allow"].firstMatch
        if allow.exists {
          allow.tap()
          return true
        }
      }
      if button.exists, button.isHittable, Date().timeIntervalSince(lastTap) > 5 {
        button.tap()
        lastTap = Date()
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    } while Date() < deadline
    attach(app, "No permission alert")
    let tree = XCTAttachment(string: springboard.debugDescription + "\n\n" + app.debugDescription)
    tree.name = "Hierarchies without a permission alert"
    tree.lifetime = .keepAlways
    add(tree)
    tap(app, "notifications.notNow", file: file, line: line)
    return false
  }

  @MainActor
  func waitForAny(_ app: XCUIApplication, _ ids: [String], timeout: TimeInterval) -> String? {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      for id in ids where el(app, id).exists { return id }
      RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    } while Date() < deadline
    return nil
  }

  @MainActor
  func waitForLabel(_ element: XCUIElement, containing text: String, timeout: TimeInterval) -> Bool {
    let done = NSPredicate(format: "exists == true AND label CONTAINS %@", text)
    return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: done, object: element)], timeout: timeout)
      == .completed
  }

  @MainActor
  func driveToHome(_ app: XCUIApplication, timeout: TimeInterval = 120,
                   file: StaticString = #filePath, line: UInt = #line) {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      guard let seen = waitForAny(app, ["home.hero.left", "notifications.notNow", "boot.retry"],
                                  timeout: deadline.timeIntervalSinceNow)
      else { break }
      switch seen {
      case "home.hero.left": return
      case "boot.retry":
        attach(app, "Boot · could not open the account")
        XCTFail("the account gate stopped at its retry wall", file: file, line: line)
        return
      default:
        el(app, seen).tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
      }
    }
    attach(app, "Home never opened")
    XCTFail("Home did not open within \(Int(timeout)) s", file: file, line: line)
  }

  @MainActor
  func signOut(_ app: XCUIApplication) {
    app.buttons["header.profile"].firstMatch.tap()
    tap(app, "profile.security")
    tap(app, "security.signOut", timeout: 20)
    let confirm = app.alerts.buttons["Sign out"].firstMatch
    XCTAssertTrue(confirm.waitForExistence(timeout: 10), "the sign-out confirmation did not appear")
    confirm.tap()
  }

  @MainActor
  func signInWithPassword(_ app: XCUIApplication, _ account: LiveE2EAccount) {
    tap(app, "stories.signIn", timeout: 30)
    type(app, "signIn.email", account.email)
    typePassword(app, "signIn.password", account.password)
    tap(app, "signIn.withPassword")
    dismissSystemPrompts(app)
  }

  @MainActor
  func assertMayaFigures(_ app: XCUIApplication, toSort: String = MayaSample.toSort,
                         file: StaticString = #filePath, line: UInt = #line) {
    let stop = continueAfterFailure
    continueAfterFailure = true
    defer { continueAfterFailure = stop }

    app.tabBars.firstMatch.buttons["Activity"].tap()
    let count = el(app, "activity.count")
    XCTAssertTrue(waitForLabel(count, containing: MayaSample.transactions, timeout: 90),
                  "Activity reads '\(count.exists ? count.label : "nothing")', not '\(MayaSample.transactions)'",
                  file: file, line: line)
    XCTAssertTrue(app.staticTexts[toSort].waitForExistence(timeout: 30), "Activity does not say '\(toSort)'",
                  file: file, line: line)
    attach(app, "Activity")

    app.buttons["header.profile"].firstMatch.tap()
    let bills = el(app, "profile.bills")
    XCTAssertTrue(waitForLabel(bills, containing: MayaSample.bills, timeout: 15),
                  "Profile's Bills row reads '\(bills.exists ? bills.label : "nothing")', not '\(MayaSample.bills)'",
                  file: file, line: line)
    attach(app, "Profile")
    if el(app, "profile.close").exists { el(app, "profile.close").tap() }

    app.tabBars.firstMatch.buttons["Projects"].tap()
    let project = labelled(app, containing: MayaSample.project)
    var swipes = 0
    while !project.exists && swipes < 8 {
      app.swipeUp()
      swipes += 1
    }
    XCTAssertTrue(project.waitForExistence(timeout: 10), "Projects shows no '\(MayaSample.project)'", file: file, line: line)
    attach(app, "Projects")
    app.tabBars.firstMatch.buttons["Home"].tap()
  }

  var accountURL: URL { e2e.stateDir.appendingPathComponent("account.json") }

  func saveAccount(_ account: LiveE2EAccount) throws {
    let data = try JSONEncoder().encode(account)
    try data.write(to: accountURL, options: .atomic)
  }

  func loadAccount() throws -> LiveE2EAccount {
    guard let data = try? Data(contentsOf: accountURL) else {
      throw LiveE2EError("no \(accountURL.path): test01_pathB creates the account the later tests use")
    }
    return try JSONDecoder().decode(LiveE2EAccount.self, from: data)
  }

  func markSignedIn(_ on: Bool) throws {
    let url = e2e.stateDir.appendingPathComponent("signed-in-\(e2e.device)")
    if on {
      try Data("yes\n".utf8).write(to: url, options: .atomic)
    } else {
      try? FileManager.default.removeItem(at: url)
    }
  }

  var wasLeftSignedIn: Bool {
    FileManager.default.fileExists(atPath: e2e.stateDir.appendingPathComponent("signed-in-\(e2e.device)").path)
  }

  func capturedMailNames() -> Set<String> {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: e2e.mailDir.path)) ?? []
    return Set(names.filter { $0.hasSuffix(".json") })
  }

  func waitForEmailCode(to address: String, excluding seen: Set<String>, timeout: TimeInterval = 60) throws -> String {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      for name in capturedMailNames().subtracting(seen).sorted().reversed() {
        guard let data = try? Data(contentsOf: e2e.mailDir.appendingPathComponent(name)),
          let mail = try? JSONDecoder().decode(CapturedMail.self, from: data), mail.to == address
        else { continue }
        if let match = mail.text.firstMatch(of: /code is ([0-9]{6})/) { return String(match.1) }
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    } while Date() < deadline
    throw LiveE2EError("no email with a code reached \(address) within \(Int(timeout)) s (capture: \(e2e.mailDir.path))")
  }

  func requestWake(timeout: TimeInterval = 30) throws -> String? {
    let sent = e2e.stateDir.appendingPathComponent("wake-sent")
    let failed = e2e.stateDir.appendingPathComponent("wake-failed")
    try? FileManager.default.removeItem(at: sent)
    try? FileManager.default.removeItem(at: failed)
    try Data("wake\n".utf8).write(to: e2e.stateDir.appendingPathComponent("wake-request"), options: .atomic)
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if FileManager.default.fileExists(atPath: sent.path) { return nil }
      if let why = try? String(contentsOf: failed, encoding: .utf8) {
        return why.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    } while Date() < deadline
    throw LiveE2EError("the harness sent no push within \(Int(timeout)) s (is ios/scripts/e2e-app.sh running?)")
  }

  func oplogPosition(timeout: TimeInterval = 30) throws -> Int {
    let answer = e2e.stateDir.appendingPathComponent("oplog-position")
    let failed = e2e.stateDir.appendingPathComponent("oplog-failed")
    try? FileManager.default.removeItem(at: answer)
    try? FileManager.default.removeItem(at: failed)
    try Data("oplog\n".utf8).write(to: e2e.stateDir.appendingPathComponent("oplog-request"), options: .atomic)
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if let text = try? String(contentsOf: answer, encoding: .utf8),
        let position = Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
      {
        return position
      }
      if let why = try? String(contentsOf: failed, encoding: .utf8) {
        throw LiveE2EError("the harness could not read the op log: \(why.trimmingCharacters(in: .whitespacesAndNewlines))")
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    } while Date() < deadline
    throw LiveE2EError("the harness reported no op log position within \(Int(timeout)) s (is ios/scripts/e2e-app.sh running?)")
  }

  func waitForUpload(after position: Int, timeout: TimeInterval = 60) throws -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if try oplogPosition() > position { return true }
    } while Date() < deadline
    return false
  }

  var notificationsAllowed: Bool { FileManager.default.fileExists(atPath: notificationsMarker.path) }

  func recordNotificationsAllowed(_ on: Bool) throws {
    if on {
      try Data("yes\n".utf8).write(to: notificationsMarker, options: .atomic)
    } else {
      try? FileManager.default.removeItem(at: notificationsMarker)
    }
  }

  private var notificationsMarker: URL { e2e.stateDir.appendingPathComponent("notifications-\(e2e.device)") }
}
