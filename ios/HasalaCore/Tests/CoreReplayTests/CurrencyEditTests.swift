import CoreWire
import Foundation
import Testing

@testable import CoreReplay

@Suite("CoreReplay currency edit")
struct CurrencyEditTests {
  static let home = op("home_currency_set", #"{"currency":"AED"}"#, id: 1)
  static let jpyRate = op("rate_set", #"{"currency":"JPY","rate_micro":"24500"}"#, id: 2)
  static let usdRate = op("rate_set", #"{"currency":"USD","rate_micro":"3672500"}"#, id: 3)

  static func toCurrency(_ ccy: String, id: Int, txn: String = Ids.t1, parent: Int = 1) -> String {
    op("txn_edited", #"{"currency":"\#(ccy)"}"#, id: id, entity: ("txn", txn), parent: parent)
  }

  @Test("a currency-only edit keeps the amount in hundredths and converts it at the new currency's rate")
  func keepsTheAmount() throws {
    var log = Log()
    try log.blob(Self.home, Self.jpyRate)
    try log.blob(ingest(1, id: Ids.t1, amount: "150000"))
    try log.blob(Self.toCurrency("JPY", id: 10))
    let t = try #require(log.state.txns[Ids.t1])
    #expect(t.currency == "JPY")
    #expect(t.amountMinor == 150_000)
    #expect(t.amountHomeMinor == 36_75)
    #expect(t.homeSource == .rate)
    #expect(t.homeRateMicro == 24_500)
    #expect(t.version == 2)
    #expect(log.kinds.isEmpty)
    #expect(log.state.anomalies.isEmpty && log.state.forks.isEmpty)
  }

  @Test("two currency edits of one version from two writers: one wins whole, with a fork notice and no anomaly")
  func forkedEdits() throws {
    var log = Log()
    try log.blob(Self.home, Self.jpyRate, Self.usdRate)
    try log.blob(ingest(1, id: Ids.t1, amount: "150000"))
    try log.blob(Self.toCurrency("JPY", id: 10))
    try log.blob(Self.toCurrency("USD", id: 11), as: Log.w2)
    #expect(log.kinds.isEmpty)
    #expect(log.state.forks.count == 1)
    let fork = try #require(log.state.forks.first)
    #expect(fork.entityKind == "txn" && fork.entityID == Ids.t1)
    #expect(Set([fork.winnerOp, fork.loserOp]) == ["op-10", "op-11"])
    let wonJPY = fork.winnerOp == "op-10"
    let t = try #require(log.state.txns[Ids.t1])
    #expect(t.currency == (wonJPY ? "JPY" : "USD"))
    #expect(t.amountMinor == 150_000)
    #expect(t.amountHomeMinor == (wonJPY ? 36_75 : 5_508_75))
    #expect(t.homeSource == .rate)
    #expect(t.homeRateMicro == (wonJPY ? 24_500 : 3_672_500))
    #expect(log.state.pendingByCurrency.isEmpty)
  }

  @Test("with no rate the row waits for one, and a later rate fills it")
  func waitsForARate() throws {
    var log = Log()
    try log.blob(Self.home)
    try log.blob(ingest(1, id: Ids.t1, amount: "150000"))
    try log.blob(Self.toCurrency("JPY", id: 10))
    #expect(log.state.txns[Ids.t1]?.amountHomeMinor == nil)
    #expect(log.state.txns[Ids.t1]?.homeSource == nil)
    #expect(log.state.pendingByCurrency["JPY"]?.contains(Ids.t1) == true)
    try log.blob(Self.jpyRate)
    #expect(log.state.txns[Ids.t1]?.amountHomeMinor == 36_75)
    #expect(log.state.pendingByCurrency["JPY"] == nil)
    #expect(log.kinds.isEmpty)
  }

  @Test("a change to the home currency counts the amount as it is")
  func backToHome() throws {
    var log = Log()
    try log.blob(Self.home, Self.usdRate)
    try log.blob(usd(1, id: Ids.t1))
    #expect(log.state.txns[Ids.t1]?.amountHomeMinor == 9181)
    try log.blob(Self.toCurrency("AED", id: 10))
    let t = try #require(log.state.txns[Ids.t1])
    #expect(t.currency == "AED")
    #expect(t.amountMinor == 2500)
    #expect(t.amountHomeMinor == 2500)
    #expect(t.homeSource == .identity)
    #expect(t.homeRateMicro == nil)
    #expect(log.kinds.isEmpty)
  }

  @Test("a split row takes a currency-only edit and keeps its parts; an amount edit is refused")
  func splitRow() throws {
    var log = Log()
    try log.blob(Self.home, Self.jpyRate)
    try log.blob(ingest(1, id: Ids.t1, amount: "34215"))
    try log.blob(
      op(
        "txn_split", #"{"parts":[{"category":"groceries","amount_minor":"29700"},{"category":"shopping","amount_minor":"4515"}]}"#,
        id: 10, entity: ("txn", Ids.t1), parent: 1))
    try log.blob(Self.toCurrency("JPY", id: 11, parent: 2))
    let t = try #require(log.state.txns[Ids.t1])
    #expect(t.currency == "JPY")
    #expect(t.splits.map(\.amountMinor) == [29_700, 4_515])
    #expect(t.amountHomeMinor == 8_38)
    #expect(log.kinds.isEmpty)
    try log.blob(op("txn_edited", #"{"amount_minor":"342","currency":"USD"}"#, id: 12, entity: ("txn", Ids.t1), parent: 3))
    #expect(log.kinds == ["unsupported_edit_field"])
    #expect(log.state.txns[Ids.t1]?.currency == "JPY")
    #expect(log.state.txns[Ids.t1]?.amountMinor == 34_215)
  }

  @Test("a currency edit drops a home amount the bank stated")
  func dropsAStatedHome() throws {
    var log = Log()
    try log.blob(Self.home, Self.usdRate)
    try log.blob(usd(1, id: Ids.t1))
    try log.blob(op("txn_edited", #"{"amount_home_minor":"9250"}"#, id: 10, entity: ("txn", Ids.t1), parent: 1))
    #expect(log.state.txns[Ids.t1]?.homeSource == .stated)
    try log.blob(Self.toCurrency("EUR", id: 11, parent: 2))
    #expect(log.state.txns[Ids.t1]?.amountHomeMinor == nil)
    #expect(log.state.txns[Ids.t1]?.homeSource == nil)
    #expect(log.kinds.isEmpty)
  }

  @Test("an unparsed row refuses a currency edit")
  func unparsedRefuses() throws {
    var log = Log()
    try log.blob(Self.home)
    try log.blob(
      op(
        "txn_ingested", #"{"posted_at":"2026-10-03T08:00:00.000Z","unparsed":true,"tier":"none","needs_review":true}"#, id: 5,
        entity: ("txn", Ids.t1), ingest: Ids.ingest(1)))
    try log.blob(Self.toCurrency("JPY", id: 10))
    #expect(log.kinds == ["unsupported_edit_field"])
    #expect(log.state.txns[Ids.t1]?.currency == "")
  }

  @Test("a row the old ingest writer made refuses a currency edit")
  func ingestWriterRefuses() throws {
    var log = Log()
    try log.blob(Self.home)
    try log.blob(ingest(1, id: Ids.t1), as: ingestWriterID)
    try log.blob(Self.toCurrency("JPY", id: 10))
    #expect(log.kinds == ["unsupported_edit_field"])
    #expect(log.state.txns[Ids.t1]?.currency == "AED")
  }
}
