import HasalaModels
import Observation

@MainActor
protocol ProfileModel: AnyObject, Observable {
  var snapshot: ProfileSnapshot { get }
  var rules: [RuleRowModel] { get }
  var hidden: Bool { get }
  var exportRows: [ExportRow] { get }
  var today: LocalDate { get }
  func setNotifications(_ level: DevicePrefs.NotificationLevel)
  func setRule(_ id: RuleID, enabled: Bool)
}

@MainActor
@Observable
final class ProfileViewModel: ProfileModel {
  private let app: AppModel

  @ObservationIgnored private var memo = Memo<Int, ProfileSnapshot>()
  @ObservationIgnored private var rulesMemo = Memo<Int, [RuleRowModel]>()
  @ObservationIgnored private var planMemo = Memo<[AnyHashable], PlanSnapshot>()
  @ObservationIgnored private var exportMemo = Memo<Int, [ExportRow]>()

  init(app: AppModel) { self.app = app }

  var snapshot: ProfileSnapshot {
    memo.value(for: app.store.revision) { ProfileEngine.snapshot(app.store.state, now: app.store.now) }
  }
  var rules: [RuleRowModel] { rulesMemo.value(for: app.store.revision) { ProfileEngine.rules(app.store.state) } }
  var hidden: Bool { app.amountsHidden }
  var today: LocalDate { app.store.now.date }

  var planLine: MoneyPhrase {
    let plan = planMemo.value(for: [app.store.revision, app.store.now.date]) {
      PlanEngine.snapshot(app.store.state, now: app.store.now)
    }
    let rta = plan.readyToAssign
    if rta.isNegative {
      return MoneyPhrase([.amount(Money(minor: -rta.minor, currency: rta.currency), hidden: 3), .text(" over-assigned")])
    }
    guard rta.minor > 0 else { return MoneyPhrase(stringLiteral: "\(plan.month.name) budgets") }
    return MoneyPhrase([.amount(rta, hidden: 3), .text(" ready to assign")])
  }

  var exportRows: [ExportRow] {
    exportMemo.value(for: app.store.revision) {
      let s = app.store.state
      return s.txns.sorted { $0.postedAt > $1.postedAt }.map { ExportRow($0, s) }
    }
  }

  func setNotifications(_ level: DevicePrefs.NotificationLevel) { app.perform(.setNotifications(level)) }

  func setRule(_ id: RuleID, enabled: Bool) { app.perform(.setRuleEnabled(id, enabled)) }
}
