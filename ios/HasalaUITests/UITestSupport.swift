import UIKit
import XCTest

let uiWait: TimeInterval = 15
let splitHandleSlot: CGFloat = 20

extension XCTestCase {
  @MainActor
  func launch(
    scenario: String? = "maya", screen: String? = nil, release: Bool = false, motion: String? = nil,
    reviewOrder: String? = "oldest", arguments: [String] = [], pasteboard: String? = nil
  ) -> XCUIApplication {
    if let pasteboard {
      UIPasteboard.general.string = pasteboard
    } else {
      UIPasteboard.general.items = []
    }
    let app = XCUIApplication()
    var args: [String] = []
    if let scenario { args += ["-HasalaScenario", scenario] }
    if let screen { args += ["-HasalaScreen", screen] }
    if release { args.append("-HasalaReleaseSurface") }
    if let motion { args += ["-HasalaMotion", motion] }
    if let reviewOrder { args += ["-HasalaReviewOrder", reviewOrder] }
    app.launchArguments = args + arguments
    app.launch()
    return app
  }

  @MainActor
  func el(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    app.descendants(matching: .any)[id].firstMatch
  }

  @MainActor
  func tap(
    _ app: XCUIApplication, _ id: String, timeout: TimeInterval = 15, file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let e = el(app, id)
    XCTAssertTrue(e.waitForExistence(timeout: timeout), "\(id) is missing", file: file, line: line)
    dragUntilHittable(app, e, file: file, line: line)
    e.tap()
  }

  @MainActor
  func answerPastEmail(_ app: XCUIApplication, _ id: String = "mail.pastMail.import") {
    tap(app, id, timeout: uiWait)
  }

  @MainActor
  func tap(
    _ app: XCUIApplication, _ id: String, opening next: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    tap(app, id, file: file, line: line)
    let shown = el(app, next)
    if shown.waitForExistence(timeout: uiWait) { return }
    let again = el(app, id)
    if again.exists, again.isHittable { again.tap() }
    XCTAssertTrue(shown.waitForExistence(timeout: uiWait), "\(id) did not open \(next)", file: file, line: line)
  }

  @MainActor
  func type(
    _ app: XCUIApplication, _ id: String, _ text: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    let e = el(app, id)
    XCTAssertTrue(e.waitForExistence(timeout: 15), "\(id) is missing", file: file, line: line)
    type(text, into: e, file: file, line: line)
  }

  @MainActor
  func replaceText(
    _ app: XCUIApplication, _ id: String, _ text: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    let e = el(app, id)
    XCTAssertTrue(e.waitForExistence(timeout: 10), "\(id) is missing", file: file, line: line)
    e.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
    let current = (e.value as? String) ?? ""
    e.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
    XCTAssertEqual((e.value as? String).map { $0 == (e.placeholderValue ?? "") || $0.isEmpty }, true,
                   "\(id) was not cleared", file: file, line: line)
    e.typeText(text)
  }

  @MainActor
  func openPlan(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    app.buttons["header.profile"].firstMatch.tap()
    let row = el(app, "profile.plan")
    XCTAssertTrue(row.waitForExistence(timeout: uiWait), "Profile has no Plan row", file: file, line: line)
    XCTAssertTrue(reveal(app, row), "could not reach Profile's Plan row", file: file, line: line)
    row.tap()
    XCTAssertTrue(el(app, "plan.readyToAssign").waitForExistence(timeout: uiWait), "Plan did not open",
                  file: file, line: line)
  }

  @MainActor
  func back(_ app: XCUIApplication) {
    app.navigationBars.buttons.firstMatch.tap()
  }

  @MainActor
  func reveal(_ app: XCUIApplication, _ element: XCUIElement) -> Bool {
    for _ in 0..<12 {
      if element.exists, element.isHittable, element.frame.maxY < app.frame.height - 120 { return true }
      let down = element.exists && element.frame.maxY < 160
      let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.4 : 0.75))
      let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.65 : 0.45))
      from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .default, thenHoldForDuration: 0.3)
    }
    waitForStill(app)
    return element.exists && element.isHittable
  }

  @MainActor
  func scroll(_ app: XCUIApplication, toShow element: XCUIElement) -> Bool {
    let height = app.frame.height
    for _ in 0..<24 {
      let top = element.frame.minY
      if top >= 120 && top <= height * 0.5 { return true }
      let up = top > height * 0.5
      let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.7 : 0.35))
      let distance = min(0.35, abs(top - height * 0.3) / height)
      let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.7 - distance : 0.35 + distance))
      from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .default, thenHoldForDuration: 0.3)
    }
    return false
  }

  @MainActor
  @discardableResult
  func dragUntilHittable(
    _ app: XCUIApplication, _ element: XCUIElement, limit: Int = 8, file: StaticString = #filePath, line: UInt = #line
  ) -> Bool {
    for i in 0..<limit {
      if element.isHittable, !isUnderKeyboard(app, element) {
        if i > 0 { waitForStill(app) }
        return true
      }
      let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
      let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
      from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .default, thenHoldForDuration: 0.3)
    }
    waitForStill(app)
    let hittable = element.isHittable && !isUnderKeyboard(app, element)
    XCTAssertTrue(hittable, "\(element) is not hittable after \(limit) drags", file: file, line: line)
    return hittable
  }

  @MainActor
  private func isUnderKeyboard(_ app: XCUIApplication, _ element: XCUIElement) -> Bool {
    let keyboard = app.keyboards.firstMatch
    guard keyboard.exists else { return false }
    return element.frame.midY > keyboard.frame.minY
  }

  @MainActor
  func audit(
    _ app: XCUIApplication, atLargeText: Bool = false, overSheet: Bool = false, file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    var reported: [[String]] = []
    for attempt in 1...3 {
      waitForStill(app)
      do {
        let issues = try auditIssues(app, atLargeText: atLargeText, overSheet: overSheet)
        if issues.isEmpty { return }
        reported.append(issues)
        if reported.count == 2 { break }
        print("audit attempt \(attempt) reported, auditing again:\n" + issues.joined(separator: "\n"))
      } catch let error as NSError where error.domain == "com.apple.xcode.xctest.accessibilityAudit"
        && error.code == -56 && attempt < 3
      {
        print("audit attempt \(attempt) did not finish in time, auditing again")
      }
    }
    if let issues = reported.last {
      XCTFail("accessibility audit:\n" + issues.joined(separator: "\n"), file: file, line: line)
    }
  }

  @MainActor
  private func auditIssues(_ app: XCUIApplication, atLargeText: Bool, overSheet: Bool) throws -> [String] {
    let bars = [app.navigationBars.firstMatch, app.tabBars.firstMatch].filter(\.exists).map(\.frame)
    let underHeader = contentUnderHeader(app)
    let keyboard = app.keyboards.firstMatch
    let keyboardTop = keyboard.exists ? keyboard.frame.minY : nil
    var types = XCUIAccessibilityAuditType.all.subtracting(.contrast)
    if !atLargeText { types.remove(.textClipped) }
    var issues: [String] = []
    try app.performAccessibilityAudit(for: types) { issue in
      if let e = issue.element, e.elementType == .key || e.elementType == .keyboard { return true }
      if issue.auditType == .sufficientElementDescription, let e = issue.element, e.label.isEmpty,
        let keyboardTop, e.frame.minY >= keyboardTop - 44
      {
        return true
      }
      if issue.auditType == .textClipped, issue.element?.elementType == .searchField { return true }
      if issue.auditType == .dynamicType, let element = issue.element {
        if element.identifier == "hasala.cappedFigure" { return true }
        if ["budget.amount", "move.amount"].contains(element.identifier) { return true }
        if bars.contains(where: { $0.intersects(element.frame) }) { return true }
      }
      if issue.element == nil, underHeader || overSheet { return true }
      let element = issue.element.map { "'\($0.label)' [\($0.identifier)] \($0.elementType.rawValue) \($0.frame)" }
      issues.append("\(issue.compactDescription): \(element ?? "no element") — \(issue.detailedDescription)")
      return true
    }
    return issues
  }

  @MainActor
  func waitForStill(_ app: XCUIApplication, timeout: TimeInterval = 10) {
    let deadline = Date(timeIntervalSinceNow: timeout)
    var last: [CGRect]?
    while Date() < deadline {
      guard let root = try? app.snapshot() else { return }
      var frames: [CGRect] = []
      var stack = [root]
      while let node = stack.popLast() {
        frames.append(node.frame)
        stack.append(contentsOf: node.children)
      }
      if frames == last { return }
      last = frames
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
    }
  }

  @MainActor
  func type(_ text: String, into field: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
    for _ in 0..<3 {
      field.tap()
      if field.waitForKeyboardFocus() {
        field.typeText(text)
        return
      }
    }
    XCTFail("\(field) did not get the keyboard focus after 3 taps", file: file, line: line)
  }

  @MainActor
  func contentUnderHeader(_ app: XCUIApplication) -> Bool {
    let header = app.navigationBars.firstMatch
    guard header.exists, let root = try? app.snapshot() else { return false }
    let band = CGRect(x: 0, y: 0, width: app.frame.width, height: header.frame.maxY + 16)
    var stack = [root]
    while let node = stack.popLast() {
      switch node.elementType {
      case .navigationBar, .tabBar, .statusBar: continue
      case .application, .window: break
      default:
        if !node.label.isEmpty, node.frame.intersects(band), node.frame.height < band.height * 2 { return true }
      }
      stack.append(contentsOf: node.children)
    }
    return false
  }

  @MainActor
  func assertMailboxAdded(_ app: XCUIApplication, _ id: String, file: StaticString = #filePath, line: UInt = #line) {
    let row = el(app, "bankAlerts.mailbox.\(id)")
    XCTAssertTrue(row.waitForExistence(timeout: uiWait), "\(id) is not listed", file: file, line: line)
    let checking = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value IN %@", ["Syncing", "Connected"]), object: row)
    XCTAssertEqual(XCTWaiter().wait(for: [checking], timeout: uiWait), .completed,
                   "\(id) reads \(row.value ?? "nothing"), not Syncing or Connected", file: file, line: line)
  }

  @MainActor
  func assertClearOfKeyboard(
    _ app: XCUIApplication, shown: [String], button: String? = nil, hidden: [String], _ name: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let keyboard = app.keyboards.firstMatch
    XCTAssertTrue(keyboard.waitForExistence(timeout: uiWait), "\(name): the keyboard did not open", file: file,
                  line: line)
    waitForStill(app)
    for id in hidden {
      XCTAssertTrue(el(app, id).waitForNonExistence(timeout: uiWait), "\(name): \(id) stayed over the keyboard",
                    file: file, line: line)
    }
    let top = keyboard.frame.minY
    let dock = button.map { el(app, $0) }
    if let button, let dock {
      XCTAssertTrue(dock.exists && dock.isHittable, "\(name): \(button) can't be reached", file: file, line: line)
      XCTAssertLessThanOrEqual(dock.frame.maxY, top + 1, "\(name): \(button) is under the keyboard", file: file,
                               line: line)
    }
    for id in shown {
      let e = el(app, id)
      XCTAssertTrue(e.exists && e.isHittable, "\(name): \(id) can't be reached", file: file, line: line)
      XCTAssertLessThanOrEqual(e.frame.maxY, (dock?.frame.minY ?? top) + 1, "\(name): \(id) is covered",
                               file: file, line: line)
    }
    attach(app, name)
  }

  @MainActor
  func attach(_ app: XCUIApplication, _ name: String) {
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = name
    shot.lifetime = .keepAlways
    add(shot)
  }

  @MainActor
  func typeOnKeypad(_ app: XCUIApplication, _ digits: String, file: StaticString = #filePath, line: UInt = #line) {
    for d in digits { tap(app, "keypad.\(d)", file: file, line: line) }
  }

  @MainActor
  func incomeFigure(_ app: XCUIApplication) -> String {
    let e = el(app, "income.figure")
    guard e.waitForExistence(timeout: uiWait) else { return "" }
    return [e.label, e.value as? String].compactMap { $0 }.joined(separator: " ")
  }

  @MainActor
  func nudge(_ app: XCUIApplication, _ handle: XCUIElement, steps: Int) {
    let track = el(app, "plan.split.bar").frame.width - 2 * splitHandleSlot
    let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    let end = start.withOffset(CGVector(dx: track / 20 * CGFloat(steps), dy: 0))
    start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
  }
}

extension XCUIElement {
  func waitForKeyboardFocus(timeout: TimeInterval = 5) -> Bool {
    let predicate = NSPredicate(format: "hasKeyboardFocus == true")
    return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: self)], timeout: timeout)
      == .completed
  }

  func waitForValue(_ value: String, timeout: TimeInterval = 5) -> Bool {
    let predicate = NSPredicate(format: "value == %@", value)
    return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: self)], timeout: timeout)
      == .completed
  }

  func waitForLabel(_ label: String, timeout: TimeInterval = uiWait) -> Bool {
    let predicate = NSPredicate(format: "label == %@", label)
    return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: self)], timeout: timeout)
      == .completed
  }

  func waitForLabel(containing text: String, timeout: TimeInterval = uiWait) -> Bool {
    let predicate = NSPredicate(format: "label CONTAINS %@", text)
    return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: self)], timeout: timeout)
      == .completed
  }
}
