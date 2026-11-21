import HasalaDesign
import HasalaModels
import Observation

@MainActor
protocol PlanModel: AnyObject, Observable {
  var snapshot: PlanSnapshot { get }
  var hidden: Bool { get }
  func editBudget(_ category: CategoryID)
  func moveMoney(to category: CategoryID?)
  func autoAssign()
  func copyLastMonth()
  func keepExpiredMoves()
  func open(_ category: CategoryID)
  func open(project: ProjectID)
  func newProject()
  func openProjects()
  var hold: ReadingHold? { get }
  func openReading(_ link: ReadingHold.Link)
}

@MainActor
@Observable
final class PlanViewModel: PlanModel {
  private let app: AppModel

  @ObservationIgnored private var memo = Memo<Int, PlanSnapshot>()

  init(app: AppModel) { self.app = app }

  var hold: ReadingHold? {
    let h = ReadingOnScreen.hold(app.store.state.reading, month: snapshot.month)
    return h?.warns == true ? h : nil
  }

  func openReading(_ link: ReadingHold.Link) { app.router.open(.profile, profile: [.bankAlerts]) }

  var snapshot: PlanSnapshot {
    memo.value(for: app.store.revision) { PlanEngine.snapshot(app.store.state, now: app.store.now) }
  }
  var hidden: Bool { app.amountsHidden }

  func editBudget(_ category: CategoryID) { app.openPlanSheet(.budget(category)) }
  func moveMoney(to category: CategoryID?) { app.openPlanSheet(.moveMoney(to: category)) }
  func open(_ category: CategoryID) { app.pushPlanCategory(category) }
  func open(project: ProjectID) { app.pushPlanProject(project) }

  func autoAssign() { app.say("Auto-assign isn't in this build yet", icon: .wand) }

  func copyLastMonth() {
    let snap = snapshot
    let edits = snap.lastMonthBudgets.sorted { $0.key < $1.key }.map { LedgerEdit.setBudget($0.key, snap.month, $0.value) }
    guard !edits.isEmpty else { return }
    app.perform(edits, title: edits.count == 1 ? nil : "\(edits.count) budgets copied from last month")
  }

  func keepExpiredMoves() {
    let edits = snapshot.keepExpiredMoves(app.store.state)
    guard !edits.isEmpty else { return }
    app.perform(edits, title: edits.count == 1 ? nil : "\(edits.count) budgets changed")
  }

  func newProject() { app.editProject(nil) }
  func openProjects() { app.pushPlanProjects() }
}

@MainActor
protocol CategoryDetailModel: AnyObject, Observable {
  var detail: CategoryDetail? { get }
  var hidden: Bool { get }
  func changeBudget()
  func moveMoneyIn()
  func open(_ txn: TxnID)
  func openRules()
  func addRule()
}

@MainActor
@Observable
final class CategoryDetailViewModel: CategoryDetailModel {
  private let app: AppModel
  let category: CategoryID

  @ObservationIgnored private var memo = Memo<Int, CategoryDetail?>()

  init(app: AppModel, category: CategoryID) {
    self.app = app
    self.category = category
  }

  var detail: CategoryDetail? {
    memo.value(for: app.store.revision) { PlanEngine.category(category, app.store.state, now: app.store.now) }
  }
  var hidden: Bool { app.amountsHidden }

  func changeBudget() { app.openPlanSheet(.budget(category)) }
  func moveMoneyIn() { app.openPlanSheet(.moveMoney(to: category)) }
  func open(_ txn: TxnID) { app.open(txn) }
  func openRules() {
    if app.showingProfile { app.router.profile.append(.rules) } else { app.router.open(.profile, profile: [.rules]) }
  }

  func addRule() { app.say("Adding rules isn't in this build yet", icon: .wand) }
}

@MainActor
protocol ProjectDetailModel: AnyObject, Observable {
  var detail: ProjectDetail? { get }
  var hidden: Bool { get }
  func open(_ txn: TxnID)
  func addTransactions()
  func setCountInPlan(_ on: Bool)
  func setComplete(_ done: Bool)
  func edit()
  func remove()
}

@MainActor
@Observable
final class ProjectDetailViewModel: ProjectDetailModel {
  private let app: AppModel
  let project: ProjectID

  @ObservationIgnored private var memo = Memo<Int, ProjectDetail?>()

  init(app: AppModel, project: ProjectID) {
    self.app = app
    self.project = project
  }

  var detail: ProjectDetail? {
    memo.value(for: app.store.revision) { PlanEngine.project(project, app.store.state, now: app.store.now) }
  }
  var hidden: Bool { app.amountsHidden }

  func open(_ txn: TxnID) { app.open(txn) }
  func addTransactions() { app.addToProject(project) }
  func setCountInPlan(_ on: Bool) { app.perform(.setProjectCountInPlan(project, on)) }
  func setComplete(_ done: Bool) { app.perform(.completeProject(project, done)) }
  func edit() { app.editProject(project) }

  func remove() {
    let name = app.store.state.project(project)?.name ?? "Project"
    guard app.perform(.removeProject(project)) else { return }
    app.say("\(name) removed")
    app.leaveProject(project)
  }
}

struct MoveSource: Identifiable, Hashable {
  let id: CategoryID?
  let name: String
  let glyph: Glyph
  let hue: Hue
  let available: Money
  let detail: MoneyPhrase
}

@MainActor
protocol BudgetSheetModel: AnyObject, Observable {
  var hidden: Bool { get }
  var plan: PlanSnapshot { get }
  var row: PlanRowModel? { get }
  var projected: Money? { get }
  var shortfall: Money? { get }
  var lastMonth: (name: String, spent: Money)? { get }
  func sources(to destination: CategoryID?) -> [MoveSource]
  var destinations: [CategoryOption] { get }
  func setBudget(_ amount: Money) -> Bool
  func setBudget(_ amount: Money, takingFrom source: CategoryID?) -> Bool
  func refusal(moving amount: Money, from source: CategoryID?) -> String?
  func refusal(noLongerOffered source: CategoryID) -> String
  func move(_ amount: Money, from: CategoryID?, to: CategoryID) -> Bool
  func close()
}

@MainActor
@Observable
final class BudgetSheetViewModel: BudgetSheetModel {
  private let app: AppModel
  let category: CategoryID?
  @ObservationIgnored private var memo = Memo<Int, PlanSnapshot>()

  init(app: AppModel, category: CategoryID?) {
    self.app = app
    self.category = category
  }

  var hidden: Bool { app.amountsHidden }
  var plan: PlanSnapshot {
    memo.value(for: app.store.revision) { PlanEngine.snapshot(app.store.state, now: app.store.now) }
  }
  var row: PlanRowModel? { category.flatMap { plan.row($0) } }
  private var month: YearMonth { app.store.now.date.yearMonth }

  var projected: Money? {
    guard let row, row.paced else { return nil }
    let now = app.store.now
    return .aed(Pace.projected(row.spent.minor, day: now.date.day, days: now.date.yearMonth.days) / 100 * 100)
  }

  var shortfall: Money? {
    guard let row, let projected, projected.minor > row.budget.minor else { return nil }
    return .aed(projected.minor.minus(row.budget.minor))
  }

  var lastMonth: (name: String, spent: Money)? {
    guard let category else { return nil }
    let previous = month.previous
    let spent = app.store.state.spent(category, in: previous)
    return spent.minor > 0 ? (previous.name, spent) : nil
  }

  func sources(to destination: CategoryID?) -> [MoveSource] {
    let p = plan
    var out: [MoveSource] = []
    if p.readyToAssign.minor > 0 {
      out.append(MoveSource(id: nil, name: "Ready to assign", glyph: .wallet, hue: .mint, available: p.readyToAssign,
                            detail: MoneyPhrase([.amount(p.readyToAssign, hidden: 3), .text(" not in a budget yet")])))
    }
    func rows(_ bucket: Bucket) -> [PlanRowModel] {
      p.sections.first { $0.bucket == bucket }?.rows.filter { $0.id != destination && $0.leftMinor > 0 } ?? []
    }
    let everyday = [Bucket.wants, .needs].flatMap { bucket in
      rows(bucket).enumerated()
        .filter { $0.element.paced && $0.element.verdict == .onTrack }
        .sorted { ($0.element.leftMinor, -$0.offset) > ($1.element.leftMinor, -$1.offset) }
        .map(\.element)
    }
    for r in everyday + rows(.savings) {
      let l = Money.aed(r.leftMinor)
      out.append(MoveSource(
        id: r.id, name: r.name, glyph: r.glyph, hue: r.hue, available: l,
        detail: MoneyPhrase([.amount(l, hidden: 3), .text(r.spent.isZero ? " left · nothing spent yet" : " left")])
      ))
    }
    return out
  }

  var destinations: [CategoryOption] { app.store.state.budgetCategoryOptions }

  func setBudget(_ amount: Money) -> Bool { setBudget(amount, takingFrom: nil) }

  func setBudget(_ amount: Money, takingFrom source: CategoryID?) -> Bool {
    guard let category, let row else { return false }
    let rise = amount.minor - row.budget.minor
    let ok: Bool
    if let source, source != category, rise > 0 {
      ok = app.perform(.moveMoney(from: source, to: category, month, .aed(rise)))
    } else {
      ok = app.perform(.setBudget(category, month, amount))
    }
    if ok { close() }
    return ok
  }

  func refusal(moving amount: Money, from source: CategoryID?) -> String? {
    guard amount.minor > 0 else { return nil }
    guard let source else {
      return amount.minor > plan.readyToAssign.minor ? "Ready to assign doesn't have that much" : nil
    }
    guard let r = plan.row(source) else { return nil }
    return amount.minor > r.leftMinor ? Self.notEnough(r) : nil
  }

  func refusal(noLongerOffered source: CategoryID) -> String {
    plan.row(source).map(Self.notEnough) ?? "This category is gone"
  }

  private static func notEnough(_ row: PlanRowModel) -> String { "\(row.name) doesn't have that much left" }

  func move(_ amount: Money, from: CategoryID?, to: CategoryID) -> Bool {
    guard from != to else { return false }
    let ok = app.perform(.moveMoney(from: from, to: to, month, amount))
    if ok { close() }
    return ok
  }

  func close() { app.closePlanSheet() }
}

extension PlanRowModel {
  var leftMinor: Int64 { budget.minor.minus(spent.minor) }
}

extension LedgerState {
  var budgetCategoryOptions: [CategoryOption] {
    [Bucket.needs, .wants, .savings].flatMap { categories(in: $0) }.map(CategoryOption.init)
  }
}
