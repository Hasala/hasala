import CoreCategorize
import CoreDomain
import CoreReplay
import CoreTime
import HasalaModels
import Testing

@Suite("Pace parity with CoreDomain")
struct PaceParityTests {
  struct Case: Equatable, CustomStringConvertible {
    var budget: Int64
    var spent: Int64
    var day: Int
    var days: Int
    var largest: Int64

    var description: String { "budget \(budget) spent \(spent) day \(day)/\(days) largest \(largest)" }
  }

  static let engine = PlanEngine(
    plan: PlanState(), taxonomy: TaxonomyView(TaxonomyV1.builtins), lines: [], today: CivilDate(year: 2026, month: 10, day: 15)!)

  static let budgets: [Int64] = [1, 7, 99, 100_00, 2_500_00, 9_999_99, 123_456_789_01, Int64.max / 2, Int64.max]

  static func spends(_ budget: Int64) -> [Int64] {
    var out: Set<Int64> = [1, budget]
    for k in 1...20 { out.insert(max(1, Fils.mulDiv(budget, Int64(k), 20))) }
    for d in 28...31 {
      for day in [7, 15, d] {
        let edge = Fils.mulDiv(Fils.mulDiv(budget, Pace.marginPercent, 100), Int64(day), Int64(d))
        for s in [edge - 1, edge, min(edge, budget - 1) + 1] where s > 0 && s <= budget { out.insert(s) }
      }
    }
    return out.sorted()
  }

  static func largests(_ spent: Int64) -> [Int64] {
    Array(Set([0, spent / 3, spent / 2, spent / 2 + 1, spent - spent / 4, spent])).sorted()
  }

  static var cases: [Case] {
    var out: [Case] = []
    for budget in budgets {
      for spent in spends(budget) {
        for days in 28...31 {
          for day in 1...days {
            for largest in largests(spent) {
              out.append(Case(budget: budget, spent: spent, day: day, days: days, largest: largest))
            }
          }
        }
      }
    }
    return out
  }

  static func screen(_ v: PaceVerdict) -> Verdict? {
    switch v {
    case .onTrack: .onTrack
    case .overPace: .overPace
    case .overBudget: .overBudget
    default: nil
    }
  }

  @Test func thresholdsAreTheSame() {
    #expect(Pace.minDay == PlanEngine.paceMinDay)
    #expect(Int128(Pace.marginPercent) == PlanEngine.paceMarginPercent)
  }

  @Test func projectionIsTheSameWithinBudget() {
    let cases = Self.cases
    #expect(cases.count > 100_000)
    let differ = cases.filter {
      Pace.projected($0.spent, day: $0.day, days: $0.days, largest: $0.largest)
        != PlanEngine.projected(spent: $0.spent, largest: $0.largest, day: $0.day, days: $0.days)
    }
    #expect(differ.prefix(5).map(\.description) == [])
  }

  @Test func pacedVerdictIsTheSameWithinBudget() {
    let cases = Self.cases
    var seen: Set<Verdict> = []
    var differ: [String] = []
    for c in cases {
      let screen = Pace.verdict(spent: c.spent, budget: c.budget, day: c.day, days: c.days, paced: true, largest: c.largest)
      let core = Self.engine.pace(
        budget: c.budget, spent: c.spent, phase: .current(day: c.day, days: c.days), kind: .everyday, largest: c.largest)
      seen.insert(screen)
      if Self.screen(core.verdict) != screen { differ.append("\(c): screen \(screen.rawValue) core \(core.verdict.rawValue)") }
      let projected = Pace.projected(c.spent, day: c.day, days: c.days, largest: c.largest)
      if core.projection != projected { differ.append("\(c): screen projects \(projected) core \(String(describing: core.projection))") }
    }
    #expect(differ.prefix(5) == [])
    #expect(seen == [.onTrack, .overPace])
  }

  @Test func overBudgetIsTheSame() {
    var differ: [String] = []
    for budget in Self.budgets + [0, -1, -100_00] {
      for over in [1, 2, 100_00] as [Int64] {
        let spent = budget > 0 ? budget.addingReportingOverflow(over).partialValue : over
        guard spent > budget, spent > 0 else { continue }
        for day in [1, 6, 7, 15, 30] {
          for largest in Self.largests(spent) {
            let screen = Pace.verdict(spent: spent, budget: budget, day: day, days: 30, paced: true, largest: largest)
            let core = Self.engine.pace(budget: budget, spent: spent, phase: .current(day: day, days: 30), kind: .everyday, largest: largest)
            if screen != .overBudget || core.verdict != .overBudget {
              differ.append("budget \(budget) spent \(spent) day \(day) largest \(largest): screen \(screen.rawValue) core \(core.verdict.rawValue)")
            }
          }
        }
      }
    }
    #expect(differ.prefix(5) == [])
  }
}
