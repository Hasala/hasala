import XCTest

final class CoreScreensTests: XCTestCase {
  override func setUp() {
    continueAfterFailure = false
  }

  @MainActor
  private func launchHome(_ scenario: String = "maya", motion: String? = nil) -> XCUIApplication {
    let app = launch(scenario: scenario, motion: motion)
    XCTAssertTrue(app.descendants(matching: .any)["home.hero.left"].waitForExistence(timeout: 15))
    return app
  }

  @MainActor
  private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    app.descendants(matching: .any)[id].firstMatch
  }

  @MainActor
  private func drag(_ app: XCUIApplication, to point: CGVector) {
    element(app, "review.card").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
      .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: point))
  }

  @MainActor
  func testActivityFiltersSearchAndTransactionSheet() throws {
    let app = launchHome()
    app.tabBars.firstMatch.buttons["Activity"].tap()
    let count = element(app, "activity.count")
    XCTAssertTrue(count.waitForExistence(timeout: uiWait))
    XCTAssertEqual(count.label, "26 transactions this month")
    XCTAssertTrue(element(app, "activity.startReview").label.contains("6 to sort"))
    XCTAssertTrue(app.staticTexts["Coming up"].exists)
    attach(app, "Activity · Overview")
    try audit(app)

    element(app, "activity.chip.toReview").tap()
    XCTAssertTrue(element(app, "txn.lulu").waitForExistence(timeout: uiWait))
    XCTAssertFalse(element(app, "txn.carrefour").exists)
    attach(app, "Activity · To review")
    element(app, "activity.chip.all").tap()

    app.buttons["header.search"].firstMatch.tap()
    let search = app.searchFields.firstMatch
    XCTAssertTrue(search.waitForExistence(timeout: uiWait))
    type("carrefour", into: search)
    let seeAll = element(app, "search.seeAll")
    XCTAssertTrue(seeAll.waitForExistence(timeout: uiWait))
    seeAll.tap()
    XCTAssertTrue(element(app, "activity.query").waitForExistence(timeout: uiWait))
    let carrefour = element(app, "txn.carrefour")
    XCTAssertTrue(carrefour.waitForExistence(timeout: uiWait))
    XCTAssertFalse(element(app, "txn.talabat").exists)
    attach(app, "Activity · Search")

    carrefour.tap()
    let merchant = element(app, "txn.merchant")
    XCTAssertTrue(merchant.waitForExistence(timeout: uiWait))
    XCTAssertEqual(merchant.label, "Carrefour")
    XCTAssertEqual(element(app, "txn.amount").label, "AED 342.15")
    XCTAssertTrue(app.staticTexts["Groceries this month"].exists)
    XCTAssertTrue(element(app, "txn.rawMerchant").exists)
    attach(app, "Transaction · Carrefour")
    try audit(app)

    element(app, "txn.category").tap()
    XCTAssertTrue(element(app, "picker.save").waitForExistence(timeout: uiWait))
    XCTAssertTrue(element(app, "picker.alwaysUse").exists)
    XCTAssertEqual(element(app, "picker.alwaysUse").value as? String, "0")
    XCTAssertTrue(element(app, "picker.groceries").isSelected)
    attach(app, "Transaction · Category")
    try audit(app)
    app.navigationBars["Category"].buttons.firstMatch.tap()
    XCTAssertTrue(merchant.waitForExistence(timeout: uiWait))

    element(app, "txn.note").tap()
    let field = element(app, "note.field")
    XCTAssertTrue(field.waitForExistence(timeout: uiWait))
    type("Weekly shop", into: field)
    element(app, "note.save").tap()
    XCTAssertTrue(element(app, "txn.note").waitForLabel(containing: "Weekly shop"))

    let split = element(app, "txn.split")
    XCTAssertTrue(reveal(app, split))
    split.tap()
    XCTAssertTrue(element(app, "split.verdict").waitForExistence(timeout: uiWait))
    XCTAssertTrue(element(app, "split.verdict").waitForLabel("Every line needs an amount"))
    XCTAssertFalse(element(app, "split.save").isEnabled)
    let second = element(app, "split.amount.2")
    second.tap()
    for key in ["4", "5", "decimal", "1", "5"] { element(app, "keypad.\(key)").tap() }
    XCTAssertEqual(second.value as? String, "45.15")
    XCTAssertEqual(element(app, "split.amount.1").value as? String, "297.00")
    XCTAssertTrue(element(app, "split.verdict").waitForLabel("Choose a category for each line"))
    XCTAssertFalse(element(app, "split.save").isEnabled)
    element(app, "split.done").tap()
    XCTAssertTrue(element(app, "keypad.4").waitForNonExistence(timeout: uiWait))
    element(app, "split.category.2").tap()
    app.buttons["Shopping"].firstMatch.tap()
    XCTAssertTrue(element(app, "split.verdict").waitForLabel("Adds up exactly"))
    attach(app, "Transaction · Split")
    try audit(app)
    element(app, "split.save").tap()
    XCTAssertTrue(element(app, "txn.category").waitForLabel(containing: "Split · 2"))
    element(app, "txn.close").tap()
  }

  @MainActor
  func testReviewDeckOffersMergeOrKeepBothForACopy() throws {
    let app = launch(scenario: "mayaCopy", screen: "review.copy")
    let line = element(app, "review.copy")
    XCTAssertTrue(line.waitForExistence(timeout: 15))
    XCTAssertEqual(line.label, "Same amount at Starbucks DIFC, 4 minutes apart, in your other inbox. Merge counts it once.")
    XCTAssertTrue(element(app, "review.reason.probable_copy").exists)
    XCTAssertTrue(element(app, "review.merge").isHittable && element(app, "review.keepBoth").isHittable)
    for pill in ["need", "want", "save", "transfer"] {
      XCTAssertFalse(element(app, "review.pill.\(pill)").exists, "the \(pill) pill shows over the question")
    }
    attach(app, "Review · Copy")
    try audit(app)
    drag(app, to: CGVector(dx: 0.5, dy: 0.05))
    XCTAssertTrue(element(app, "pick.close").waitForExistence(timeout: uiWait))
    XCTAssertEqual(element(app, "pick.keepsBoth").label, "Sorting keeps both transactions.")
    attach(app, "Review · Pick · From a copy card")
    element(app, "pick.mergeInstead").tap()
    XCTAssertTrue(element(app, "pick.close").waitForNonExistence(timeout: uiWait))
    XCTAssertTrue(line.waitForNonExistence(timeout: uiWait), "the copy stayed on the deck")
    attach(app, "Review · Copy merged")
  }

  @MainActor
  func testSortingACopyCardSaysItKeptBoth() throws {
    let app = launch(scenario: "mayaCopy", screen: "review.copy")
    XCTAssertTrue(element(app, "review.copy").waitForExistence(timeout: 15))
    drag(app, to: CGVector(dx: 0.5, dy: 0.05))
    XCTAssertTrue(element(app, "pick.close").waitForExistence(timeout: uiWait))
    element(app, "pick.transfer").tap()
    XCTAssertTrue(app.staticTexts["Kept both, sorted into Transfer"].waitForExistence(timeout: uiWait))
  }

  @MainActor
  private func sortedRowOnAllCaughtUp(_ app: XCUIApplication) -> XCUIElement {
    XCTAssertTrue(element(app, "review.copy").waitForExistence(timeout: 15))
    drag(app, to: CGVector(dx: 0.5, dy: 0.05))
    XCTAssertTrue(element(app, "pick.close").waitForExistence(timeout: uiWait))
    element(app, "pick.transfer").tap()
    XCTAssertTrue(element(app, "pick.close").waitForNonExistence(timeout: uiWait))
    let done = element(app, "review.done")
    let skip = element(app, "review.skip")
    while !done.waitForExistence(timeout: 1), skip.isHittable { skip.tap() }
    XCTAssertTrue(done.waitForExistence(timeout: uiWait))
    let row = app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier BEGINSWITH 'review.done.row.'")).firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: uiWait))
    return row
  }

  @MainActor
  func testArchivingARowFromAllCaughtUpOffersUndoOnThatScreen() throws {
    let app = launch(scenario: "mayaCopy", screen: "review.copy")
    let row = sortedRowOnAllCaughtUp(app)
    XCTAssertFalse(element(app, "toast").exists)
    row.tap()
    let archive = element(app, "txn.archive")
    XCTAssertTrue(element(app, "txn.note").waitForExistence(timeout: uiWait))
    XCTAssertTrue(reveal(app, archive), "could not reach txn.archive")
    archive.tap()
    XCTAssertTrue(element(app, "txn.close").waitForNonExistence(timeout: uiWait))
    let undo = element(app, "toast").buttons["Undo"]
    XCTAssertTrue(undo.waitForExistence(timeout: uiWait))
    XCTAssertTrue(undo.isHittable)
    XCTAssertTrue(element(app, "review.seeActivity").isHittable)
    undo.tap()
    XCTAssertTrue(element(app, "toast").waitForNonExistence(timeout: uiWait))
  }

  @MainActor
  func testATransactionOpenedAfterASwipeDownStartsAtItsRoot() throws {
    let app = launch(scenario: "mayaCopy", screen: "review.copy")
    let row = sortedRowOnAllCaughtUp(app)
    row.tap()
    XCTAssertTrue(element(app, "txn.note").waitForExistence(timeout: uiWait))
    element(app, "txn.note").tap()
    XCTAssertTrue(element(app, "note.field").waitForExistence(timeout: uiWait))
    app.navigationBars.element(boundBy: 0).swipeDown(velocity: .fast)
    XCTAssertTrue(element(app, "note.field").waitForNonExistence(timeout: uiWait))
    row.tap()
    XCTAssertTrue(element(app, "txn.close").waitForExistence(timeout: uiWait))
    XCTAssertFalse(element(app, "note.field").exists)
  }

  @MainActor
  func testReviewDeckAsksSamePurchase() throws {
    let app = launch(scenario: "mayaSamePurchase", screen: "review.samePurchase")
    let line = element(app, "review.copy")
    XCTAssertTrue(line.waitForExistence(timeout: 15))
    XCTAssertEqual(line.label, "Same purchase as USD 25.00 (about AED 91.81) at Amazon on Wed 7 Oct?")
    XCTAssertTrue(element(app, "review.reason.same_purchase").exists)
    XCTAssertTrue(element(app, "review.same").isHittable && element(app, "review.keepBoth").isHittable)
    XCTAssertFalse(element(app, "review.pill.want").exists)
    attach(app, "Review · Same purchase")
    try audit(app)
    element(app, "review.same").tap()
    XCTAssertTrue(line.waitForNonExistence(timeout: uiWait), "the card stayed on the deck")
  }

  @MainActor
  func testReviewDeckSortsUndoesAndCatchesUp() throws {
    let app = launchHome()
    app.tabBars.firstMatch.buttons["Review"].tap()
    let start = element(app, "review.tab.start")
    XCTAssertTrue(start.waitForExistence(timeout: uiWait))
    XCTAssertEqual(element(app, "review.tab.count").label, "6 to sort · about a minute")
    attach(app, "Review · Tab")
    try audit(app)
    start.tap()
    let position = element(app, "review.position")
    XCTAssertTrue(position.waitForExistence(timeout: uiWait))
    XCTAssertEqual(position.label, "1 of 6")
    attach(app, "Review · Deck")
    try audit(app)

    drag(app, to: CGVector(dx: 0.5, dy: 0.05))
    let sheet = element(app, "pick.close")
    XCTAssertTrue(sheet.waitForExistence(timeout: uiWait))
    XCTAssertTrue(app.staticTexts["Transfer · which one?"].exists)
    attach(app, "Review · Pick transfer")
    try audit(app)
    element(app, "pick.transfer").tap()
    XCTAssertTrue(app.staticTexts["Sorted into Transfer"].waitForExistence(timeout: uiWait))
    XCTAssertTrue(sheet.waitForNonExistence(timeout: uiWait))
    XCTAssertEqual(position.label, "2 of 6")
    attach(app, "Review · Deck after a one-tap sort")

    element(app, "toast").buttons["Undo"].tap()
    XCTAssertTrue(position.waitForLabel("1 of 6"))

    element(app, "review.pill.transfer").tap()
    XCTAssertTrue(sheet.waitForExistence(timeout: uiWait))
    element(app, "pick.transfer").tap()
    XCTAssertTrue(position.waitForLabel("2 of 6"))

    XCTAssertTrue(sheet.waitForNonExistence(timeout: uiWait))
    let skip = element(app, "review.skip")
    XCTAssertTrue(skip.waitForExistence(timeout: uiWait) && skip.isHittable)
    skip.tap()
    let merchant = element(app, "review.merchant")
    XCTAssertTrue(merchant.waitForLabel(containing: "Apple.com"), merchant.debugDescription)

    for _ in 0..<3 {
      let use = element(app, "review.use")
      XCTAssertTrue(use.waitForExistence(timeout: uiWait))
      use.tap()
    }
    XCTAssertTrue(merchant.waitForLabel(containing: "Steam"), merchant.debugDescription)
    XCTAssertTrue(element(app, "review.use").exists)
    element(app, "review.pill.want").tap()
    XCTAssertTrue(sheet.waitForExistence(timeout: uiWait))
    XCTAssertFalse(element(app, "pick.alwaysUse").isSelected)
    element(app, "pick.entertainment").tap()
    XCTAssertTrue(element(app, "review.done").waitForExistence(timeout: uiWait))
    XCTAssertEqual(element(app, "review.done").label, "Done for now")
    XCTAssertEqual(element(app, "review.done.tally").label, "5 sorted")
    XCTAssertEqual(element(app, "review.done.skipped").label, "1 skipped, back tomorrow")
    XCTAssertFalse(element(app, "toast").exists, "a toast covers the done screen")
    attach(app, "Review · Done for now")
    try audit(app)
    let doneRow = app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier BEGINSWITH 'review.done.row.'")).firstMatch
    XCTAssertTrue(doneRow.isHittable)
    doneRow.tap()
    XCTAssertTrue(element(app, "txn.close").waitForExistence(timeout: uiWait))
    element(app, "txn.close").tap()
    XCTAssertTrue(element(app, "txn.close").waitForNonExistence(timeout: uiWait))
    element(app, "review.undoLast").tap()
    XCTAssertTrue(merchant.waitForLabel(containing: "Steam"), merchant.debugDescription)
    element(app, "review.pill.want").tap()
    XCTAssertTrue(sheet.waitForExistence(timeout: uiWait))
    element(app, "pick.entertainment").tap()
    XCTAssertTrue(element(app, "review.done").waitForExistence(timeout: uiWait))
    element(app, "review.seeActivity").tap()
    XCTAssertTrue(element(app, "activity.count").waitForExistence(timeout: uiWait))
    let chip = app.buttons["activity.chip.toReview"]
    XCTAssertTrue(chip.waitForExistence(timeout: uiWait))
    XCTAssertTrue(chip.label.contains("1"), chip.label)
    XCTAssertFalse(app.staticTexts["1 to sort"].exists)
    XCTAssertEqual(app.buttons["header.notifications"].firstMatch.label, "Notifications, 3 need a look")
  }

  @MainActor
  func testAToSortRowOpensTheDeckAtItsCard() throws {
    let app = launchHome()
    app.tabBars.firstMatch.buttons["Review"].tap()
    let row = element(app, "review.tab.row.lulu")
    XCTAssertTrue(row.waitForExistence(timeout: uiWait))
    XCTAssertTrue(reveal(app, row))
    row.tap()
    let merchant = element(app, "review.merchant")
    XCTAssertTrue(merchant.waitForLabel(containing: "Lulu Hypermarket"), merchant.debugDescription)
    XCTAssertEqual(element(app, "review.position").label, "1 of 6")
    XCTAssertTrue(merchant.label.contains("Looks like Groceries. Suggested by Cloudflare AI."), merchant.label)
    attach(app, "Review · Cloudflare suggestion")

    drag(app, to: CGVector(dx: 0.02, dy: 0.5))
    XCTAssertTrue(app.staticTexts["Want · which one?"].waitForExistence(timeout: uiWait))
    element(app, "pick.close").tap()
    XCTAssertTrue(element(app, "pick.close").waitForNonExistence(timeout: uiWait))
    XCTAssertTrue(merchant.waitForLabel(containing: "Lulu Hypermarket"))
    XCTAssertEqual(element(app, "review.position").label, "1 of 6")

    element(app, "review.use").tap()
    XCTAssertTrue(merchant.waitForLabel(containing: "Dubai Taxi"), merchant.debugDescription)
    XCTAssertEqual(element(app, "review.position").label, "2 of 6")
    element(app, "review.close").tap()
    XCTAssertTrue(element(app, "review.tab.count").waitForLabel("5 to sort · about a minute"))
  }

  @MainActor
  func testAShortDragSpringsBack() throws {
    let app = launchHome()
    app.tabBars.firstMatch.buttons["Review"].tap()
    let start = element(app, "review.tab.start")
    XCTAssertTrue(start.waitForExistence(timeout: uiWait))
    start.tap()
    let merchant = element(app, "review.merchant")
    XCTAssertTrue(merchant.waitForLabel(containing: "ADCB ATM withdrawal"), merchant.debugDescription)
    let middle = element(app, "review.card").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    for offset in [CGVector(dx: 60, dy: 0), CGVector(dx: -60, dy: 0), CGVector(dx: 0, dy: -50), CGVector(dx: 0, dy: 50)] {
      middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(offset), withVelocity: 120,
                   thenHoldForDuration: 0.3)
      XCTAssertFalse(element(app, "pick.close").waitForExistence(timeout: 1), "a short drag committed")
    }
    XCTAssertTrue(merchant.label.contains("ADCB ATM withdrawal"))
    XCTAssertEqual(element(app, "review.position").label, "1 of 6")
  }

  @MainActor
  func testReviewDeckWithReduceMotion() throws {
    let app = launchHome(motion: "reduce")
    app.tabBars.firstMatch.buttons["Review"].tap()
    let start = element(app, "review.tab.start")
    XCTAssertTrue(start.waitForExistence(timeout: uiWait))
    start.tap()
    let position = element(app, "review.position")
    XCTAssertTrue(position.waitForLabel("1 of 6"))

    let card = element(app, "review.card")
    let rest = card.frame
    drag(app, to: CGVector(dx: 0.98, dy: 0.5))
    let sheet = element(app, "pick.close")
    XCTAssertTrue(sheet.waitForExistence(timeout: uiWait))
    XCTAssertEqual(card.frame.midX, rest.midX, accuracy: 1, "the card leans with Reduce Motion")
    XCTAssertEqual(card.frame.midY, rest.midY, accuracy: 1, "the card leans with Reduce Motion")
    attach(app, "Reduce Motion · Pick a need")
    element(app, "pick.alwaysUse").tap()
    element(app, "pick.rent").tap()
    XCTAssertTrue(position.waitForLabel("2 of 6"))
    attach(app, "Reduce Motion · Deck")
    try audit(app)

    let second = card.frame
    element(app, "review.pill.transfer").tap()
    XCTAssertTrue(sheet.waitForExistence(timeout: uiWait))
    XCTAssertEqual(card.frame.midY, second.midY, accuracy: 1, "the card rises with Reduce Motion")
    element(app, "pick.salary").tap()
    for _ in 0..<3 {
      let use = element(app, "review.use")
      XCTAssertTrue(use.waitForExistence(timeout: uiWait))
      use.tap()
    }
    element(app, "review.pill.want").tap()
    XCTAssertTrue(sheet.waitForExistence(timeout: uiWait))
    element(app, "pick.entertainment").tap()
    XCTAssertTrue(element(app, "review.done").waitForExistence(timeout: uiWait))
    XCTAssertEqual(element(app, "review.done.tally").label, "6 sorted · 1 new rule")
    attach(app, "Reduce Motion · All caught up")
    element(app, "review.close").tap()
    XCTAssertTrue(element(app, "review.tab.count").waitForLabel("Everything is sorted"))
  }

  @MainActor
  func testCoreScreensAtLargeTextSizes() throws {
    let app = launch(arguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
    XCTAssertTrue(element(app, "home.hero.left").waitForExistence(timeout: 15))

    app.tabBars.firstMatch.buttons["Activity"].tap()
    XCTAssertTrue(element(app, "activity.count").waitForExistence(timeout: uiWait))
    for id in ["activity.startReview", "bill.dewa", "txn.talabat", "txn.carrefour"] {
      let target = element(app, id)
      XCTAssertTrue(reveal(app, target), "could not reach \(id)")
      attach(app, "AX3 · Activity · \(id)")
      try audit(app, atLargeText: true)
    }
    element(app, "txn.carrefour").tap()
    XCTAssertTrue(element(app, "txn.merchant").waitForExistence(timeout: uiWait))
    attach(app, "AX3 · Transaction")
    try audit(app, atLargeText: true)
    for id in ["txn.note", "txn.rawMerchant", "txn.archive"] {
      XCTAssertTrue(reveal(app, element(app, id)), "could not reach \(id)")
      try audit(app, atLargeText: true)
    }
    element(app, "txn.close").tap()

    app.tabBars.firstMatch.buttons["Review"].tap()
    let start = element(app, "review.tab.start")
    XCTAssertTrue(start.waitForExistence(timeout: uiWait))
    attach(app, "AX3 · Review tab")
    try audit(app, atLargeText: true)
    XCTAssertTrue(reveal(app, start))
    start.tap()
    XCTAssertTrue(element(app, "review.card").waitForExistence(timeout: uiWait))
    attach(app, "AX3 · Review")
    try audit(app, atLargeText: true)
    for id in ["review.use", "review.pill.save", "review.skip"] {
      XCTAssertTrue(reveal(app, element(app, id)), "could not reach \(id)")
      try audit(app, atLargeText: true)
    }
    element(app, "review.close").tap()
  }

  @MainActor
  func testDebugSearchReadyThenResults() throws {
    let app = launchHome()
    app.buttons["header.search"].firstMatch.tap()
    XCTAssertTrue(element(app, "search.placeholder").waitForExistence(timeout: uiWait))
    let title = app.navigationBars.staticTexts["Search"]
    XCTAssertTrue(title.waitForExistence(timeout: uiWait) && title.isHittable, "Ready has no large title")
    attach(app, "Search · Ready")
    app.buttons.matching(NSPredicate(
      format: "identifier != 'search.close' AND (label ==[c] 'Close' OR label ==[c] 'Cancel')")).firstMatch.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: uiWait), "the keyboard stayed up")
    try audit(app)

    let field = app.searchFields.firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: uiWait))
    type("carre", into: field)
    let result = element(app, "search.txn.carrefour")
    XCTAssertTrue(result.waitForExistence(timeout: uiWait))
    XCTAssertTrue(element(app, "search.top").exists)
    XCTAssertFalse(element(app, "search.placeholder").exists)
    let titleGone = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false OR hittable == false"), object: title)
    XCTAssertEqual(XCTWaiter().wait(for: [titleGone], timeout: uiWait), .completed, "results kept the large title")
    attach(app, "Search · Results as you type")

    result.tap()
    XCTAssertTrue(element(app, "txn.merchant").waitForLabel("Carrefour"))
    element(app, "txn.close").tap()
    XCTAssertTrue(element(app, "txn.merchant").waitForNonExistence(timeout: uiWait))
    XCTAssertTrue(result.waitForExistence(timeout: uiWait), "closing the transaction lost the results")
    XCTAssertEqual(field.value as? String, "carre")
    XCTAssertTrue(element(app, "search.top").exists)
    attach(app, "Search · Results after a transaction")
  }

  @MainActor
  func testCaughtUpScenarioHasNothingToReview() throws {
    let app = launchHome("mayaCaughtUp")
    app.tabBars.firstMatch.buttons["Review"].tap()
    XCTAssertTrue(element(app, "review.tab.count").waitForLabel("Everything is sorted"))
    XCTAssertTrue(element(app, "review.tab.empty").exists)
    XCTAssertFalse(element(app, "review.tab.start").exists)
    app.tabBars.firstMatch.buttons["Activity"].tap()
    XCTAssertTrue(element(app, "activity.count").waitForExistence(timeout: uiWait))
    XCTAssertFalse(app.staticTexts["To review"].exists)
  }

  @MainActor
  func testAnUnverifiedSenderShowsNoWarning() throws {
    let app = launchHome()
    app.tabBars.firstMatch.buttons["Review"].tap()
    let row = element(app, "review.tab.row.steam")
    XCTAssertTrue(row.waitForExistence(timeout: uiWait))
    XCTAssertTrue(reveal(app, row))
    XCTAssertFalse(row.label.localizedCaseInsensitiveContains("verify"), row.label)
    row.tap()

    let merchant = element(app, "review.merchant")
    XCTAssertTrue(merchant.waitForLabel(containing: "Steam"), merchant.debugDescription)
    XCTAssertFalse(merchant.label.localizedCaseInsensitiveContains("verify"), merchant.label)
    XCTAssertFalse(element(app, "review.reason.sender_unverified").exists)
    XCTAssertFalse(element(app, "review.reasonStrip.sender_unverified").exists)
    attach(app, "Unverified sender · Deck")
    element(app, "review.close").tap()

    app.tabBars.firstMatch.buttons["Activity"].tap()
    XCTAssertTrue(element(app, "activity.count").waitForExistence(timeout: uiWait))
    element(app, "activity.chip.toReview").tap()
    let steam = element(app, "txn.steam")
    XCTAssertTrue(steam.waitForExistence(timeout: uiWait))
    XCTAssertTrue(steam.label.contains("To review"), steam.label)
    steam.tap()
    XCTAssertTrue(element(app, "txn.source").waitForExistence(timeout: uiWait))
    XCTAssertFalse(element(app, "txn.reviewReason.sender_unverified").exists)
    XCTAssertFalse(element(app, "txn.senderCheck").exists)
    attach(app, "Unverified sender · Transaction")
    element(app, "txn.close").tap()
  }
}
