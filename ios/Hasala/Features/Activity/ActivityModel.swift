import HasalaDesign
import HasalaModels
import Observation

@MainActor
protocol ActivityModel: AnyObject, Observable {
  var snapshot: ActivitySnapshot { get }
  var hidden: Bool { get }
  var searchText: String { get }
  var exportRows: [ExportRow] { get }
  func select(_ kind: TxnFilter.Kind)
  func search(_ text: String)
  func show(category: CategoryID?)
  func apply(_ filter: TxnFilter)
  func choosePeriod()
  func backToThisMonth()
  func open(_ txn: TxnID)
  func setArchived(_ txn: TxnID, _ archived: Bool)
  func openBill(_ bill: BillID)
  func openBills()
  func startReview()
}

@MainActor
@Observable
final class ActivityViewModel: ActivityModel {
  private let app: AppModel
  private(set) var filter: TxnFilter
  @ObservationIgnored private var memo = Memo<[AnyHashable], ActivitySnapshot>()
  @ObservationIgnored private var exportMemo = Memo<[AnyHashable], [ExportRow]>()

  init(app: AppModel, filter: TxnFilter = .all) {
    self.app = app
    self.filter = filter
  }

  var snapshot: ActivitySnapshot {
    let period = app.period
    return memo.value(for: [app.store.revision, filter, period]) {
      ActivityEngine.snapshot(app.store.state, now: app.store.now, filter: filter, period: period)
    }
  }
  var hidden: Bool { app.amountsHidden }
  var searchText: String { filter.text }

  var exportRows: [ExportRow] {
    exportMemo.value(for: [app.store.revision, filter, app.period]) {
      let s = app.store.state
      let snap = snapshot
      let ids = Set(snap.days.flatMap(\.rows).map(\.id) + snap.rows.map(\.id))
      return s.txns.filter { ids.contains($0.id) }.map { ExportRow($0, s) }
    }
  }

  func select(_ kind: TxnFilter.Kind) { filter.kind = kind }
  func search(_ text: String) { filter.text = text }

  func show(category: CategoryID?) {
    filter = TxnFilter(kind: .all, category: category, text: "")
  }

  func apply(_ filter: TxnFilter) { self.filter = filter }

  func choosePeriod() { app.sheet = .period }
  func backToThisMonth() { app.period = .month(app.store.now.date.yearMonth) }

  func open(_ txn: TxnID) { app.open(txn) }
  func setArchived(_ txn: TxnID, _ archived: Bool) { app.perform(.archive(txn, archived)) }
  func openBill(_ bill: BillID) { app.router.activity.append(.bill(bill)) }
  func openBills() {
    app.router.home = [.bills]
    app.tab = .home
  }
  func startReview() { ReviewEntry.open(app, at: nil) }
}

@MainActor
@Observable
final class ActivityRequests {
  static let shared = ActivityRequests()

  private(set) var pending: (app: ObjectIdentifier, filter: TxnFilter)?

  func show(_ filter: TxnFilter, in app: AppModel) {
    pending = (ObjectIdentifier(app), filter)
    app.router.activity = []
    app.tab = .activity
    if app.router.sheet == .search || app.router.sheet == .profile { app.router.sheet = nil }
  }

  func take(for app: AppModel) -> TxnFilter? {
    guard let p = pending, p.app == ObjectIdentifier(app) else { return nil }
    pending = nil
    return p.filter
  }
}
