import CoreDomain
import CoreInvariants
import CoreReplay
import CoreTime
import CoreWire
import Foundation
import HasalaMocks
import HasalaModels
import Testing

@testable import Hasala

@MainActor
@Suite("Live net worth history (#310)")
struct LiveNetWorthHistoryTests {
  static let october = CivilMonth(year: 2026, month: 10)!

  static func at(_ year: Int, _ month: Int, _ day: Int, plusMs: Int64 = 0) -> String {
    Instant.iso(LocalClock.startOfDay(CivilDate(year: year, month: month, day: day)!) + plusMs)!
  }

  static func account(_ id: String, currency: String = "AED") -> CoreReplay.Account {
    CoreReplay.Account(id: id, name: id, kind: "current", inPlan: true, currency: currency, active: true, firstSeq: 1)
  }

  static func checkin(_ account: String, _ asOf: String, _ minor: Int64, void: Bool = false) -> Checkin {
    Checkin(id: "ck_\(account)_\(asOf)", account: account, asOf: asOf, balanceMinor: minor, source: "checkin", void: void, atSeq: 1)
  }

  static func history(
    _ accounts: [CoreReplay.Account], _ checkins: [Checkin], rates: [CurrencyRate] = []
  ) -> NetWorthHistory {
    LedgerStateMapper.netWorthHistory(accounts: accounts, checkins: checkins, rates: rates, month: october)
  }

  @Test func noCheckInGivesNoHistory() {
    #expect(Self.history([Self.account("a")], []) == NetWorthHistory())
    #expect(Self.history([], [Self.checkin("gone", Self.at(2025, 1, 1), 5)]) == NetWorthHistory())
  }

  @Test func twelveCoveredMonthsGiveTheChartAndTheChange() {
    let got = Self.history([Self.account("a")], [
      Self.checkin("a", Self.at(2026, 10, 5), 450_00),
      Self.checkin("a", Self.at(2025, 11, 10), 100_00),
      Self.checkin("a", Self.at(2026, 9, 20), 300_00),
    ])
    #expect(got.monthChange == .aed(150_00))
    #expect(got.spark == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 571, 1000])
  }

  @Test func aMonthEndsWhenTheNextOneStartsInUAETime() {
    let a = Self.account("a")
    let late = Self.history([a], [Self.checkin("a", Self.at(2025, 12, 1), 100_00)])
    #expect(late.spark.isEmpty && late.monthChange == .aed(0))
    let inTime = Self.history([a], [Self.checkin("a", Self.at(2025, 12, 1, plusMs: -1), 100_00)])
    #expect(inTime.spark == Array(repeating: 500, count: 12) && inTime.monthChange == .aed(0))
    let thisMonth = Self.history([a], [Self.checkin("a", Self.at(2026, 10, 1), 100_00)])
    #expect(thisMonth == NetWorthHistory())
  }

  @Test func anAccountFirstCheckedInThisMonthLeavesBothAbsent() {
    let got = Self.history([Self.account("a"), Self.account("b")], [
      Self.checkin("a", Self.at(2025, 6, 1), 100_00),
      Self.checkin("b", Self.at(2026, 10, 2), 900_00),
    ])
    #expect(got == NetWorthHistory())
  }

  @Test func anAccountFirstCheckedInLastMonthGivesTheChangeAndNoChart() {
    let got = Self.history([Self.account("a"), Self.account("b")], [
      Self.checkin("a", Self.at(2025, 6, 1), 100_00),
      Self.checkin("b", Self.at(2026, 9, 2), 900_00),
      Self.checkin("b", Self.at(2026, 10, 2), 850_00),
    ])
    #expect(got.monthChange == .aed(-50_00))
    #expect(got.spark.isEmpty)
  }

  @Test func aVoidCheckInAndAnUnreadableDateDoNotCover() {
    let a = Self.account("a")
    let got = Self.history([a], [
      Self.checkin("a", Self.at(2025, 6, 1), 100_00, void: true),
      Self.checkin("a", "not a date", 100_00),
      Self.checkin("a", Self.at(2026, 9, 2), 200_00),
    ])
    #expect(got.monthChange == .aed(0))
    #expect(got.spark.isEmpty)
  }

  @Test func anAccountWithNoCheckInDoesNotHideTheHistory() {
    let got = Self.history([Self.account("a"), Self.account("empty")], [
      Self.checkin("a", Self.at(2025, 6, 1), 100_00),
      Self.checkin("a", Self.at(2026, 10, 3), 50_00),
    ])
    #expect(got.monthChange == .aed(-50_00))
    #expect(got.spark == [1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000, 1000, 0])
  }

  @Test func debtAndOtherCurrenciesAddUpAsTheNetWorthDoes() {
    let accounts = [Self.account("card"), Self.account("usd", currency: "USD"), Self.account("eur", currency: "EUR")]
    let got = Self.history(accounts, [
      Self.checkin("card", Self.at(2025, 6, 1), -500_00),
      Self.checkin("usd", Self.at(2025, 6, 1), 100_00),
      Self.checkin("eur", Self.at(2025, 6, 1), 70_00),
      Self.checkin("usd", Self.at(2026, 10, 3), 200_00),
    ], rates: [CurrencyRate(currency: "USD", rateMicro: 3_672_500)])
    #expect(got.monthChange == .aed(367_25))
    #expect(got.spark == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1000])
  }

  @Test func theSampleLedgerHasNoHistoryUntilEachAccountIsCovered() async throws {
    let a = try LiveLedgerMapperTests.account()
    var blobs = try await LiveLedgerMapperTests.seed(a)
    func project() throws -> LedgerState {
      let rows = blobs.enumerated().map { i, b in
        FoldRow(
          seq: Int64(i + 1), writerID: LiveLedgerMapperTests.writer.string, counter: Int64(i + 1),
          outcome: .opened(plaintext: Data((try? OpCodec.encodeBlobOps(b.ops)) ?? []), ops: b.ops))
      }
      try a.projection.project(
        try LedgerFold.page(rows, onto: State()), pending: [], writerID: LiveLedgerMapperTests.writer.string,
        dictionary: AccountRuntime.dictionary, projectedAtMs: LiveLedgerMapperTests.anchor)
      return try LedgerStateMapper.map(a.projection.reader, context: LiveLedgerMapperTests.context())
    }
    let seeded = try project()
    #expect(seeded.netWorth == NetWorthHistory())
    let before = AccountsEngine.snapshot(seeded, now: MayaLedger.now)
    #expect(before.netWorth == .aed(227_568_00) && before.monthChange == nil && before.chart == nil)

    let ids = seeded.accounts.map(\.id)
    let yearAgo = LocalClock.startOfDay(CivilDate(year: 2025, month: 10, day: 15)!)
    let more = try a.observer.stamps.build(try await a.observer.authorContext()) { o throws(AuthorError) in
      for id in ids { try o.checkIn(account: id, asOfMs: yearAgo, balanceMinor: 1_000_00, source: .update) }
    }
    blobs.append(try #require(more))
    let covered = try project()
    #expect(seeded.accounts.allSatisfy { $0.balance.currency == "AED" } && ids.count == 4)
    #expect(covered.netWorth.monthChange == .aed(223_568_00))
    #expect(covered.netWorth.spark == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1000])
    let after = AccountsEngine.snapshot(covered, now: MayaLedger.now)
    #expect(after.netWorth == .aed(227_568_00) && after.monthChange == .aed(223_568_00))
    #expect(after.chart?.points.count == 12 && after.chart?.months.count == 12)
  }
}
