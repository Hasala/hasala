import XCTest

class ReleaseSurfaceTestCase: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  func launchRelease(_ scenario: String = "maya", waitForHome: Bool = true, screen: String? = nil) -> XCUIApplication {
    let app = launch(scenario: scenario, screen: screen, release: true)
    if waitForHome {
      XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 15), "Home did not appear")
    }
    return app
  }

  @MainActor
  func assertNoPlaceholders(_ app: XCUIApplication, _ screen: String, line: UInt = #line) {
    let predicate = NSPredicate(
      format: "label CONTAINS[c] 'later build' OR label CONTAINS[c] 'coming soon' OR label CONTAINS[c] 'coming in a'"
        + " OR label CONTAINS[c] 'in this build' OR label CONTAINS[c] 'in this beta' OR label CONTAINS[c] 'arrives with'"
        + " OR label CONTAINS[c] 'arrives in' OR label CONTAINS[c] 'arrive in'")
    let hits = app.descendants(matching: .any).matching(predicate).allElementsBoundByIndex.map(\.label)
    XCTAssertTrue(hits.isEmpty, "\(screen) shows placeholder text: \(hits)", line: line)
  }

  @MainActor
  func assertPersonalAccountsOnly(_ app: XCUIApplication, _ screen: String, line: UInt = #line) {
    assertNoText(app, ["work or school", "Work or school", "Microsoft 365", "Entra", "organisation"], screen, line: line)
  }

  @MainActor
  func assertAbsent(_ app: XCUIApplication, _ ids: [String], _ screen: String, line: UInt = #line) {
    for id in ids {
      XCTAssertFalse(app.descendants(matching: .any)[id].exists, "\(screen) offers \(id)", line: line)
    }
  }

  @MainActor
  func assertNoButtons(_ app: XCUIApplication, _ labels: [String], _ screen: String, line: UInt = #line) {
    for label in labels {
      XCTAssertFalse(app.buttons[label].exists, "\(screen) has a \(label) button", line: line)
    }
  }

  @MainActor
  func assertPresent(_ app: XCUIApplication, _ ids: [String], _ screen: String, line: UInt = #line) {
    for id in ids {
      XCTAssertTrue(el(app, id).waitForExistence(timeout: uiWait), "\(screen) is missing \(id)", line: line)
    }
  }

  @MainActor
  func assertNoText(_ app: XCUIApplication, _ phrases: [String], _ screen: String, line: UInt = #line) {
    for phrase in phrases {
      let hits = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@", phrase))
      XCTAssertEqual(hits.count, 0, "\(screen) says '\(phrase)'", line: line)
    }
  }

  @MainActor
  func assertText(_ app: XCUIApplication, _ phrase: String, _ screen: String, line: UInt = #line) {
    let hit = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", phrase)).firstMatch
    XCTAssertTrue(hit.waitForExistence(timeout: uiWait), "\(screen) does not say '\(phrase)'", line: line)
  }
}
