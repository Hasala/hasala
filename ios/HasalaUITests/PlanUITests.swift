import XCTest

final class PlanUITests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  private func launchHome(_ scenario: String = "maya", arguments: [String] = []) -> XCUIApplication {
    let app = launch(scenario: scenario, arguments: arguments)
    XCTAssertTrue(el(app, "home.hero.left").waitForExistence(timeout: 15))
    return app
  }

  @MainActor
  private func waitUntilStill(_ element: XCUIElement) {
    var last = element.frame
    for _ in 0..<20 {
      Thread.sleep(forTimeInterval: 0.25)
      let now = element.frame
      if now == last { return }
      last = now
    }
  }

  @MainActor
  func testPlanMoveMoneyAndBudget() throws {
    let app = launchHome()
    openPlan(app)
    let rta = el(app, "plan.readyToAssign")
    XCTAssertTrue(rta.waitForExistence(timeout: uiWait))
    XCTAssertEqual(rta.label, "AED 1,000.00")
    attach(app, "Plan · October")
    try audit(app)

    let groceries = el(app, "plan.row.groceries")
    XCTAssertTrue(reveal(app, groceries))
    XCTAssertTrue(groceries.label.hasPrefix("Groceries, AED 1,387.60 left. 812.40 of 2,200, Over pace"), groceries.label)
    attach(app, "Plan · Needs")
    groceries.tap()
    let hero = el(app, "category.hero")
    XCTAssertTrue(hero.waitForExistence(timeout: uiWait))
    XCTAssertTrue(hero.label.contains("AED 1,387.60 left of 2,200 this month. Over pace, on course for 2,518"),
                  hero.label)
    XCTAssertTrue(app.navigationBars["Groceries"].exists)
    attach(app, "Plan · Groceries")
    try audit(app)

    let move = el(app, "category.moveMoney")
    XCTAssertTrue(reveal(app, move))
    move.tap()
    let save = el(app, "move.save")
    XCTAssertTrue(save.waitForExistence(timeout: uiWait))
    XCTAssertEqual(save.label, "Move AED 318.00")
    XCTAssertLessThan(el(app, "move.close").frame.minY, app.frame.height * 0.2)
    XCTAssertTrue(el(app, "move.to").label.contains("On course for 2,518 of 2,200"))
    XCTAssertTrue(el(app, "move.preview").exists)
    for id in ["rta", "travel", "shopping", "entertainment"] {
      XCTAssertTrue(el(app, "move.from.\(id)").exists, "\(id) is not offered")
    }
    XCTAssertFalse(el(app, "move.from.dining").exists)
    XCTAssertFalse(el(app, "move.from.transport").exists)
    XCTAssertTrue(el(app, "move.from.rta").isSelected)
    attach(app, "Plan · Move money")
    try audit(app)
    save.tap()
    XCTAssertTrue(app.staticTexts["Moved to Groceries"].waitForExistence(timeout: uiWait))
    back(app)
    XCTAssertTrue(rta.waitForExistence(timeout: uiWait))
    XCTAssertTrue(scroll(app, toShow: rta))
    XCTAssertEqual(rta.label, "AED 682.00")

    let dining = el(app, "plan.row.dining")
    XCTAssertTrue(reveal(app, dining))
    dining.tap()
    let change = el(app, "category.changeBudget")
    XCTAssertTrue(reveal(app, change))
    change.tap()
    let field = el(app, "budget.amount")
    XCTAssertTrue(field.waitForExistence(timeout: uiWait))
    XCTAssertEqual(field.value as? String, "1,600")
    let close = el(app, "budget.close")
    waitUntilStill(close)
    let top = close.frame.minY
    XCTAssertGreaterThan(top, app.frame.height * 0.25)
    attach(app, "Plan · Dining budget")
    app.buttons["Add 200"].tap()
    XCTAssertEqual(close.frame.minY, top, accuracy: 1)
    XCTAssertEqual(el(app, "budget.save").label, "Set to AED 1,800")
    XCTAssertEqual(el(app, "budget.consequence").label, "Ready to assign becomes AED 482.00")
    for _ in 0..<4 { app.buttons["Add 200"].tap() }
    XCTAssertEqual(el(app, "budget.consequence").label, "Ready to assign becomes \u{2212}AED 318.00")
    for _ in 0..<8 { app.buttons["Less"].tap() }
    XCTAssertEqual(el(app, "budget.save").label, "Set to AED 1,800")
    el(app, "budget.save").tap()
    XCTAssertTrue(app.staticTexts["Dining budget changed"].waitForExistence(timeout: uiWait))
    XCTAssertTrue(el(app, "category.hero").label.contains("AED 1,157.25 left of 1,800 this month"))
  }

  @MainActor
  func testABudgetRiseCanComeFromAnotherCategory() throws {
    let app = launch(screen: "plan.budget")
    let field = el(app, "budget.amount")
    XCTAssertTrue(field.waitForExistence(timeout: 15))
    waitUntilStill(el(app, "budget.close"))
    try audit(app)
    for button in ["Add 200", "Less", "More", "Close"] {
      let target = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != 'plan.more'", button)).firstMatch
      XCTAssertGreaterThanOrEqual(target.frame.height, 44, button)
    }
    app.buttons["Add 200"].tap()
    attach(app, "Plan · Dining budget · 1,800")
    let source = el(app, "budget.source")
    XCTAssertTrue(source.label.hasPrefix("Take it from"))
    source.tap()
    let travel = el(app, "source.travel")
    XCTAssertTrue(travel.waitForExistence(timeout: uiWait))
    XCTAssertTrue(el(app, "source.rta").isSelected)
    attach(app, "Plan · Dining budget · Take it from")
    try audit(app)
    travel.tap()
    XCTAssertTrue(el(app, "budget.consequence").waitForExistence(timeout: uiWait))
    XCTAssertEqual(el(app, "budget.consequence").label, "Travel keeps AED 2,300.00")
    for _ in 0..<12 { app.buttons["Add 200"].tap() }
    XCTAssertTrue(el(app, "budget.refusal").waitForExistence(timeout: uiWait))
    XCTAssertFalse(el(app, "budget.save").isEnabled)
    for _ in 0..<24 { app.buttons["Less"].tap() }
    XCTAssertEqual(el(app, "budget.save").label, "Set to AED 1,800")
    el(app, "budget.save").tap()
    XCTAssertTrue(app.staticTexts["Moved to Dining"].waitForExistence(timeout: uiWait))
    back(app)
    let row = el(app, "plan.row.travel")
    XCTAssertTrue(reveal(app, row))
    XCTAssertTrue(row.label.hasPrefix("Travel, AED 2,300.00 left"), row.label)
  }

  @MainActor
  func testDiningOpensItsPaymentsAndRules() throws {
    let app = launch(screen: "plan.dining")
    let chart = el(app, "plan.chart")
    XCTAssertTrue(chart.waitForExistence(timeout: 15))
    XCTAssertEqual(chart.label, "Day by day, 1–10 Oct")
    XCTAssertEqual(chart.value as? String, "Largest day Wed 7 Oct, Zuma, AED 412.00. Daily budget AED 51.61.")
    attach(app, "Plan · Dining")
    try audit(app)

    let rule = el(app, "plan.rule.r-talabat")
    XCTAssertTrue(reveal(app, rule))
    XCTAssertTrue(rule.label.contains("Merchant contains"))
    attach(app, "Plan · Dining · Rules")
    try audit(app)
    rule.tap()
    XCTAssertTrue(el(app, "rule.r-talabat").waitForExistence(timeout: uiWait))
    back(app)

    let zuma = el(app, "plan.txn.zuma")
    XCTAssertTrue(zuma.waitForExistence(timeout: uiWait))
    XCTAssertTrue(reveal(app, zuma))
    attach(app, "Plan · Dining · This month")
    zuma.tap()
    XCTAssertTrue(el(app, "txn.merchant").waitForExistence(timeout: uiWait))
    tap(app, "txn.close")
  }

  @MainActor
  func testAssignChoosesWhereTheMoneyGoes() throws {
    let app = launch(screen: "plan.assign")
    let to = el(app, "move.to")
    XCTAssertTrue(to.waitForExistence(timeout: 15))
    XCTAssertFalse(el(app, "move.save").isEnabled)
    attach(app, "Plan · Assign")
    to.tap()
    tap(app, "destination.shopping")
    XCTAssertTrue(to.waitForLabel(containing: "Shopping"))
    XCTAssertFalse(el(app, "move.from.shopping").exists)
    XCTAssertTrue(el(app, "move.save").isEnabled)
    XCTAssertEqual(el(app, "move.save").label, "Assign AED 1,000.00")
    try audit(app)
  }

  @MainActor
  func testHiddenAmountsReachEveryPlanFigure() throws {
    let app = launch(scenario: "mayaHidden", screen: "plan.dining")
    let hero = el(app, "category.hero")
    XCTAssertTrue(hero.waitForExistence(timeout: 15))
    XCTAssertTrue(hero.label.hasPrefix("Dining, Amount hidden left of Amount hidden this month. On track"), hero.label)
    XCTAssertFalse(hero.label.contains("957"))
    XCTAssertEqual(el(app, "plan.chart").value as? String,
                   "Largest day Wed 7 Oct, Zuma, Amount hidden. Daily budget Amount hidden.")
    attach(app, "Plan · Dining · Amounts hidden")
    tap(app, "category.changeBudget")
    XCTAssertTrue(app.buttons["Cover the pace, Amount hidden"].waitForExistence(timeout: uiWait))
    XCTAssertEqual(el(app, "budget.amount").value as? String, "1,600")
    attach(app, "Plan · Dining budget · Amounts hidden")
  }

  @MainActor
  func testJapanTripFromItsCard() throws {
    let app = launchHome()
    openPlan(app)
    let card = el(app, "plan.project.japan")
    XCTAssertTrue(reveal(app, card))
    XCTAssertEqual(card.label,
                   "Japan trip, 14–28 Dec, 65 days to go. AED 7,140.00 left of 12,000. Not counted in your monthly plan.")
    card.tap()
    let hero = el(app, "project.hero")
    XCTAssertTrue(hero.waitForExistence(timeout: uiWait))
    XCTAssertEqual(hero.label, "Japan trip, AED 7,140.00 left of 12,000. 14–28 Dec, 65 days to go.")
    XCTAssertTrue(el(app, "project.countInPlan").exists)
    attach(app, "Plan · Japan trip")
    try audit(app)
    let jr = el(app, "project.txn.jr-pass")
    XCTAssertTrue(reveal(app, jr))
    attach(app, "Plan · Japan trip · Transactions")
    try audit(app)
  }

  @MainActor
  func testDayByDayKeepsItsLabelsOffTheBarsAtLargeSizes() throws {
    let plain = launch(screen: "plan.dining", motion: "off")
    XCTAssertTrue(el(plain, "plan.chart").waitForExistence(timeout: 15))
    let height = el(plain, "plan.chart").frame.height
    for (name, size) in [("AX3", "AccessibilityXL"), ("AX5", "AccessibilityXXXL")] {
      let app = launch(screen: "plan.dining", motion: "off",
                       arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategory\(size)"])
      let chart = el(app, "plan.chart")
      XCTAssertTrue(chart.waitForExistence(timeout: 15))
      XCTAssertTrue(scroll(app, toShow: chart))
      for _ in 0..<3 where chart.frame.maxY > app.frame.height - 110 {
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        let over = min(300, chart.frame.maxY - (app.frame.height - 130))
        from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: -over)))
      }
      XCTAssertLessThan(chart.frame.maxY, app.frame.height - 100, "\(name): \(chart.frame)")
      XCTAssertGreaterThan(chart.frame.height, height + 40, "\(name): \(chart.frame)")
      XCTAssertLessThanOrEqual(chart.frame.maxX, app.frame.width - 20)
      attach(app, "\(name) · Plan · Dining · Day by day")
    }
  }

  @MainActor
  func testReadyToAssignWrapsAtTheLargestSize() throws {
    let app = launch(screen: "plan", motion: "off",
                     arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
    XCTAssertTrue(el(app, "plan.readyToAssign").waitForExistence(timeout: 15))
    let overline = app.staticTexts.matching(NSPredicate(format: "label ==[c] 'Ready to assign'")).firstMatch
    XCTAssertTrue(overline.exists)
    XCTAssertGreaterThan(overline.frame.height, 70, "\(overline.frame)")
    XCTAssertLessThanOrEqual(overline.frame.maxX, app.frame.width - 20)
    attach(app, "AX5 · Plan · Ready to assign")
  }

  @MainActor
  func testPlanAtLargeTextSizes() throws {
    let large = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"]
    let app = launchHome(arguments: large)

    openPlan(app)
    XCTAssertTrue(el(app, "plan.readyToAssign").waitForExistence(timeout: uiWait))
    attach(app, "AX3 · Plan")
    try audit(app)
    try app.performAccessibilityAudit(for: .textClipped) { issue in
      issue.element?.label.localizedCaseInsensitiveCompare("Ready to assign") == .orderedSame
    }
    for id in ["plan.row.rent", "plan.row.insurance", "plan.row.dining", "plan.row.subscriptions",
               "plan.row.emergency-fund", "plan.project.japan"] {
      XCTAssertTrue(reveal(app, el(app, id)), "could not reach \(id)")
      attach(app, "AX3 · Plan · \(id)")
      try audit(app, atLargeText: true)
    }

    let dining = el(app, "plan.row.dining")
    XCTAssertTrue(scroll(app, toShow: dining) || reveal(app, dining))
    dining.tap()
    XCTAssertTrue(el(app, "category.hero").waitForExistence(timeout: uiWait))
    try audit(app, atLargeText: true)
    for id in ["plan.chart", "plan.txn.talabat-3", "plan.rule.r-zuma", "category.moveMoney"] {
      XCTAssertTrue(reveal(app, el(app, id)), "could not reach \(id)")
      attach(app, "AX3 · Plan · Dining · \(id)")
      try audit(app, atLargeText: true)
    }

    tap(app, "category.changeBudget")
    XCTAssertTrue(el(app, "budget.amount").waitForExistence(timeout: uiWait))
    attach(app, "AX3 · Plan · Dining budget")
    try audit(app, atLargeText: true)
    XCTAssertTrue(reveal(app, el(app, "budget.save")))
    try audit(app, atLargeText: true)
    tap(app, "budget.close")

    tap(app, "category.moveMoney")
    XCTAssertTrue(el(app, "move.amount").waitForExistence(timeout: uiWait))
    attach(app, "AX3 · Plan · Move money")
    try audit(app, atLargeText: true)
    XCTAssertTrue(reveal(app, el(app, "move.save")))
    try audit(app, atLargeText: true)
  }
}
