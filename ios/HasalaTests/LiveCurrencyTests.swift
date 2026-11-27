import CoreDomain
import CoreJSON
import CoreProjection
import CoreReplay
import CoreStore
import CoreTime
import Foundation
import HasalaMocks
import HasalaModels
import Testing

@testable import Hasala

@MainActor
@Suite("Live currency change")
struct LiveCurrencyTests {
  typealias Mapper = LiveLedgerMapperTests

  struct Live {
    let a: Mapper.Account
    let author: LedgerEditAuthor
    let store: LiveLedgerStore
  }

  static let refused = LedgerEditAuthor.Failure.refused(CurrencyChange.refusedText)

  static func live(suite: String, _ extra: (inout OpAuthor) throws(AuthorError) -> Void) async throws -> Live {
    let a = try Mapper.account()
    for b in try await Mapper.seed(a) { try await a.outbox.enqueue(b.ops) }
    if let b = try a.observer.stamps.build(try await a.observer.authorContext(), extra) { try await a.outbox.enqueue(b.ops) }
    try await a.observer.reproject()
    let author = LedgerEditAuthor(observer: a.observer, outbox: a.outbox)
    let store = LiveLedgerStore(
      reader: a.projection.reader, author: author, profile: Mapper.context().profile,
      prefs: DevicePrefsStore(defaults: UserDefaults(suiteName: suite)!), clock: { MayaLedger.now })
    await store.reload()
    return Live(a: a, author: author, store: store)
  }

  static func manual(_ o: inout OpAuthor, minor: Int64 = 1_500_00, currency: String = "AED") throws(AuthorError) -> String {
    try o.manualEntry(
      amountMinor: minor, currency: currency, direction: "debit", localWallMs: 1_791_633_600_000, merchant: "Test Kiosk",
      category: "dining")
  }

  static func payload(_ p: PendingOp) throws -> JSONObject {
    let json = try #require(try JSONParser.parse(p.opJSON).objectValue)
    return try #require(json["payload"]?.objectValue)
  }

  @Test func theOpCarriesOnlyTheCurrencyAndTheAmountStays() async throws {
    var id = ""
    let l = try await Self.live(suite: "currency.op.tests") { o throws(AuthorError) in
      try o.setRate(currency: "JPY", rateMicro: 24_500)
      id = try Self.manual(&o)
    }
    var failed = false
    l.store.onWriteFailed = { failed = true }
    let shown = try #require(l.store.state.txn(id))
    #expect(CurrencyChange.options(for: shown, in: l.store.state) == ["JPY", "USD"])
    let pending = try l.a.context.store.pendingCount()
    let token = try #require(try l.store.apply(.changeCurrency(id, to: "JPY")))
    #expect(token.title == "Changed to JPY" && l.store.canUndo(token))
    let patched = try #require(l.store.state.txn(id))
    #expect(patched.amount == Money(minor: 1_500_00, currency: "JPY"))
    #expect(patched.homeMinor == 36_75 && patched.homeSource == .rate && patched.homeRateMicro == 24_500)

    try await Mapper.eventually { try l.a.projection.reader.txn(id)?.currency == "JPY" }
    let row = try #require(try l.a.projection.reader.txn(id))
    #expect(row.currency == "JPY" && row.amountMinor == 1_500_00)
    #expect(row.amountHomeMinor == 36_75 && row.homeSource == .rate && row.homeRateMicro == 24_500)
    #expect(try l.a.context.store.pendingCount() == pending + 1)
    let op = try #require(try l.a.context.store.pendingOps().last)
    #expect(op.opType == "txn_edited" && op.entityID == id)
    #expect(try Self.payload(op) == JSONObject([("currency", .string("JPY"))]))

    await l.store.writesFinished()
    let mapped = try #require(l.store.state.txn(id))
    #expect(mapped.amount == Money(minor: 1_500_00, currency: "JPY") && mapped.homeMinor == 36_75)
    #expect(try l.a.projection.reader.forkNotices(kind: "txn").isEmpty)
    #expect(!failed)
  }

  @Test func undoWritesTheOldCurrencyBack() async throws {
    var id = ""
    let l = try await Self.live(suite: "currency.undo.tests") { o throws(AuthorError) in
      id = try Self.manual(&o, minor: 25_00, currency: "USD")
    }
    var failed = false
    l.store.onWriteFailed = { failed = true }
    #expect(try l.a.projection.reader.txn(id)?.amountHomeMinor == 91_81)
    let app = AppModel(store: l.store)
    let model = TransactionViewModel(app: app, id: id)
    #expect(model.currencyOptions == ["AED"])
    #expect(model.changeCurrency("AED"))
    #expect(app.toast?.title == "Changed to AED" && app.toast?.actionTitle == "Undo")
    #expect(l.store.state.txn(id)?.amount == .aed(25_00))
    try await Mapper.eventually { try l.a.projection.reader.txn(id)?.currency == "AED" }
    let home = try #require(try l.a.projection.reader.txn(id))
    #expect(home.amountMinor == 25_00 && home.amountHomeMinor == 25_00 && home.homeSource == .identity)

    app.toastAction()
    try await Mapper.eventually { try l.a.projection.reader.txn(id)?.currency == "USD" }
    let back = try #require(try l.a.projection.reader.txn(id))
    #expect(back.currency == "USD" && back.amountMinor == 25_00)
    #expect(back.amountHomeMinor == 91_81 && back.homeSource == .rate && back.homeRateMicro == 3_672_500)
    let op = try #require(try l.a.context.store.pendingOps().last)
    #expect(op.opType == "txn_edited")
    #expect(try Self.payload(op) == JSONObject([("currency", .string("USD"))]))
    #expect(try l.a.projection.reader.forkNotices(kind: "txn").isEmpty)
    #expect(!failed)
  }

  @Test func aChoiceThatIsNotOfferedWritesNothing() async throws {
    var id = ""
    let l = try await Self.live(suite: "currency.refused.tests") { o throws(AuthorError) in id = try Self.manual(&o) }
    let pending = try l.a.context.store.pendingCount()
    let before = l.store.state
    let today = MayaLedger.now.date
    for code in ["AED", "EUR", "usd", "", "DIRHAM"] {
      #expect(throws: ActionError.refused(CurrencyChange.refusedText)) { try l.store.apply(.changeCurrency(id, to: code)) }
      await #expect(throws: Self.refused) { try await l.author.author(.changeCurrency(id, to: code), before: before, today: today) }
    }
    #expect(throws: ActionError.notFound) { try l.store.apply(.changeCurrency("nope", to: "USD")) }
    await #expect(throws: LedgerEditAuthor.Failure.notFound) {
      try await l.author.author(.changeCurrency("nope", to: "USD"), before: before, today: today)
    }
    #expect(l.store.state.txns == before.txns)

    var stale = before
    stale.rates.append(CurrencyRate(currency: "JPY", rateMicro: 24_500))
    await #expect(throws: Self.refused) { try await l.author.author(.changeCurrency(id, to: "JPY"), before: stale, today: today) }
    #expect(try l.a.context.store.pendingCount() == pending)
    #expect(try l.a.projection.reader.txn(id)?.currency == "AED")
  }

  @Test func aHeldCopyKeepsItsCurrency() async throws {
    var copy = ""
    let l = try await Self.live(suite: "currency.held.tests") { o throws(AuthorError) in
      try o.ingest(
        payload: LiveUndoTests.alert(grant: "u/mbx-a", message: "m1", at: "08:00:00"), ingestID: String(repeating: "c", count: 64))
      copy = try o.ingest(
        payload: LiveUndoTests.alert(grant: "u/mbx-b", message: "m2", at: "08:05:00"), ingestID: String(repeating: "d", count: 64))
    }
    let pending = try l.a.context.store.pendingCount()
    #expect(l.store.state.txn(copy)?.isHeldCopy == true)
    #expect(TransactionViewModel(app: AppModel(store: l.store), id: copy).currencyOptions.isEmpty)
    #expect(throws: ActionError.refused(CurrencyChange.refusedText)) { try l.store.apply(.changeCurrency(copy, to: "USD")) }
    await #expect(throws: Self.refused) {
      try await l.author.author(.changeCurrency(copy, to: "USD"), before: l.store.state, today: MayaLedger.now.date)
    }
    var open = l.store.state
    let i = try #require(open.txns.firstIndex { $0.id == copy })
    open.txns[i].heldCopy = nil
    await #expect(throws: Self.refused) {
      try await l.author.author(.changeCurrency(copy, to: "USD"), before: open, today: MayaLedger.now.date)
    }
    #expect(try l.a.context.store.pendingCount() == pending)
  }

  @Test func aSamePurchasePairKeepsItsCurrencies() async throws {
    var foreign = ""
    var home = ""
    let l = try await Self.live(suite: "currency.same.tests") { o throws(AuthorError) in
      foreign = try o.ingest(
        payload: LiveUndoTests.alert(grant: "u/mbx-a", message: "m3", at: "08:00:00", merchant: "AMAZON", minor: "2500", currency: "USD"),
        ingestID: String(repeating: "e", count: 64))
      home = try o.ingest(
        payload: LiveUndoTests.alert(grant: "u/mbx-a", message: "m4", at: "09:00:00", merchant: "AMAZON MKTPLACE", minor: "9300"),
        ingestID: String(repeating: "f", count: 64))
    }
    let today = MayaLedger.now.date
    #expect(l.store.state.txn(home)?.samePurchase?.of == foreign)
    #expect(TransactionViewModel(app: AppModel(store: l.store), id: home).currencyOptions.isEmpty)
    await #expect(throws: Self.refused) {
      try await l.author.author(.changeCurrency(home, to: "USD"), before: l.store.state, today: today)
    }
    try l.store.apply(.resolveSamePurchase(home, same: true))
    try await Mapper.eventually { try l.a.projection.reader.txn(foreign)?.homeSource == .stated }
    await l.store.writesFinished()
    let pending = try l.a.context.store.pendingCount()
    #expect(TransactionViewModel(app: AppModel(store: l.store), id: foreign).currencyOptions.isEmpty)
    #expect(throws: ActionError.refused(CurrencyChange.refusedText)) { try l.store.apply(.changeCurrency(foreign, to: "AED")) }
    var loose = l.store.state
    let i = try #require(loose.txns.firstIndex { $0.id == foreign })
    loose.txns[i].homeSource = .rate
    await #expect(throws: Self.refused) {
      try await l.author.author(.changeCurrency(foreign, to: "AED"), before: loose, today: today)
    }
    #expect(try l.a.context.store.pendingCount() == pending)
    #expect(try l.a.projection.reader.txn(foreign)?.currency == "USD")
  }

  @Test func rowsTheFoldWouldRefuseAreNeverWritten() async throws {
    var id = ""
    let l = try await Self.live(suite: "currency.rows.tests") { o throws(AuthorError) in id = try Self.manual(&o) }
    let row = try #require(try l.a.projection.reader.txn(id))
    #expect(LedgerEditAuthor.takesCurrency(row))
    var unparsed = row
    unparsed.unparsed = true
    var superseded = row
    superseded.supersededBy = "01JC0000000000000000000001"
    var held = row
    held.heldCopy = true
    var ingest = row
    ingest.provenance = "ingest"
    var stated = row
    stated.homeSource = .stated
    for r in [unparsed, superseded, held, ingest, stated] { #expect(!LedgerEditAuthor.takesCurrency(r)) }
  }

  @Test func theSheetOffersACurrencyOnlyWhenThereIsAChoice() throws {
    var s = MayaLedger.state
    s.rates = [CurrencyRate(currency: "USD", rateMicro: 3_672_500), CurrencyRate(currency: "JPY", rateMicro: 24_500)]
    var merged = try #require(s.txn("carrefour"))
    merged.id = "merged"
    merged.mergedInto = "carrefour"
    s.txns.append(merged)
    let ledger = InMemoryLedger(state: s)
    let app = AppModel(store: ledger)
    let model = TransactionViewModel(app: app, id: "carrefour")
    #expect(model.currencyOptions == ["JPY", "USD"])
    #expect(TransactionViewModel(app: app, id: "merged").currencyOptions.isEmpty)
    #expect(TransactionViewModel(app: app, id: "nope").currencyOptions.isEmpty)
    let amount = try #require(ledger.state.txn("carrefour")).amount
    #expect(model.changeCurrency("JPY"))
    #expect(ledger.state.txn("carrefour")?.amount == Money(minor: amount.minor, currency: "JPY"))
    #expect(app.toast?.title == "Changed to JPY" && app.toast?.actionTitle == "Undo")
    #expect(model.currencyOptions == ["AED", "USD"])
    #expect(!model.changeCurrency("EUR"))
    #expect(app.toast?.title == CurrencyChange.refusedText)
    #expect(ledger.state.txn("carrefour")?.amount.currency == "JPY")

    var none = MayaLedger.state
    none.rates = []
    #expect(TransactionViewModel(app: AppModel(store: InMemoryLedger(state: none)), id: "carrefour").currencyOptions.isEmpty)
  }
}
