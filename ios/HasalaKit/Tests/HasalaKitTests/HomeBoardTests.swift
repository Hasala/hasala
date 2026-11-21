import HasalaMocks
import HasalaModels
import Testing

@testable import HasalaDesign

@Suite("Home canvas")
struct CanvasTests {
  @Test func mediumsStandAloneAndSmallsPair() {
    let rows = Maya.home.widgets.canvasRows
    #expect(rows.map(\.count) == [1, 2, 2, 1])
    #expect(rows[1].map(\.id) == ["nextBill", "netWorth"])
  }

  @Test func anUnpairedSmallSitsAlone() {
    let w = Maya.home.widgets
    let rows = [w[1], w[0], w[2]].canvasRows
    #expect(rows.map(\.count) == [1, 1, 1])
  }
}

@Suite("Maya scenario")
struct MayaTests {
  @Test func heroMatchesTheBoard() {
    let hero = Maya.home.hero
    #expect(hero.overline == "Day 10 of 31")
    #expect(MoneyFormat.string(hero.spent.minor) == "11,115.62")
    #expect(hero.caption.rendered(hidden: false) == "spent of 19,000 planned")
    #expect(hero.word.rendered(hidden: false) == "On track")
    #expect(hero.fact?.rendered(hidden: false) == "AED 7,884.38 left")
    #expect(hero.verdict == .onTrack)
    #expect(hero.wash == .sky)
    #expect(Permille.ratio(hero.spent.minor, of: hero.plan.minor).value == 585)
    #expect(hero.tick.map { Permille.ratio($0.minor, of: hero.plan.minor).value } == 590)
    #expect(hero.tiles.map { MoneyFormat.string($0.value.minor, style: $0.style) } == ["9,040.80", "1,247.54", "5,000.00"])
  }

  @Test func theBellCountsFour() {
    #expect(Maya.home.notifications.count == 4)
  }

  @Test func bucketRowsAddUp() throws {
    guard case .budgetPace(let pace) = Maya.home.widgets[0] else {
      Issue.record("first widget is not Budget pace")
      return
    }
    #expect(pace.rows.map { MoneyFormat.string($0.left.minor, style: .rounded) } == ["3,309", "5,402", "0"])
    #expect(pace.rows.map { MoneyFormat.string($0.spent.minor, style: .rounded) } == ["9,041", "1,248", "5,000"])
    #expect(pace.rows.last?.verdict == .done)
  }

  @Test func scenarioFromLaunchArguments() {
    #expect(Scenario.fromLaunchArguments(["app"]) == .maya)
    #expect(Scenario.fromLaunchArguments(["app", "-HasalaScenario", "mayaHidden"]) == .mayaHidden)
    #expect(Scenario.fromLaunchArguments(["app", "-HasalaScenario", "nope"]) == .maya)
    #expect(Scenario.fromLaunchArguments(["app", "-HasalaScenario"]) == .maya)
  }

  @Test func goalPercentRoundsDown() {
    #expect(GoalWidget(name: "x", glyph: .flag, progress: Permille(999), caption: "").percentLabel == "99%")
  }
}

@Suite("Notification rows")
struct NotificationRowTests {
  @Test func whenReadsInWords() {
    #expect(NotificationRow.spokenWhen("Thu") == "Thursday")
    #expect(NotificationRow.spokenWhen("28 Sep") == "28 September")
    #expect(NotificationRow.spokenWhen("Today") == "Today")
    #expect(NotificationRow.spokenWhen("9:12") == "9:12")
  }
}
