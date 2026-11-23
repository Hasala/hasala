import HasalaDesign
import HasalaModels
import SwiftUI

struct CategoryDetailView: View {
  @Bindable var app: AppModel
  let category: CategoryID
  @State private var model: CategoryDetailViewModel

  init(app: AppModel, category: CategoryID) {
    self.app = app
    self.category = category
    _model = State(initialValue: CategoryDetailViewModel(app: app, category: category))
  }

  var body: some View {
    if let d = model.detail {
      PlanDetailScreen(
        app: app, title: d.name, wash: .hue(d.hue),
        more: [
          PlanMenuItem(title: "Change budget") { model.changeBudget() },
          PlanMenuItem(title: "Move money in") { model.moveMoneyIn() },
        ]
      ) {
        CategoryHero(detail: d, hidden: model.hidden)
        ChartCard(chart: d.chart, name: d.name, hue: d.hue, bucket: d.bucket, hidden: model.hidden)
        if !d.transactions.isEmpty { ThisMonth(detail: d, model: model) }
        if !d.rules.isEmpty || BuildSurface.showsUnfinished { Rules(detail: d, model: model) }
        actions
      }
    } else {
      PlanDetailScreen(app: app, title: "Category", wash: .onTrack) {
        EmptyStateCard(icon: .tag, tone: .neutral, title: "This category is gone",
                       message: "It was archived or removed.")
          .padding(.horizontal, HSpacing.insetPage)
      }
    }
  }

  private var actions: some View {
    VStack(spacing: 12) {
      Button("Change budget") { model.changeBudget() }
        .buttonStyle(.pill(.primary, fill: true))
        .accessibilityIdentifier("category.changeBudget")
      Button("Move money in") { model.moveMoneyIn() }
        .buttonStyle(.pill(.onGrouped, fill: true))
        .accessibilityIdentifier("category.moveMoney")
    }
    .padding(.horizontal, HSpacing.insetPage)
  }
}

private struct CategoryHero: View {
  let detail: CategoryDetail
  let hidden: Bool
  @Environment(\.hMotion) private var policy
  @State private var phase = PaceFillPhase()

  private var over: Bool { detail.left.isNegative }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 14) {
        CategoryDisc(hue: detail.hue, glyph: detail.glyph, size: .s56)
          .hElevation(.near)
        VStack(alignment: .leading, spacing: 4) {
          MoneyText(phase.figure(.aed(Int64(clamping: detail.left.minor.magnitude))), figure: .hero, unit: .unit, hidden: hidden,
                    hiddenGlyphs: 6, color: over ? HColor.statusErrorForeground : HColor.textPrimary, unitGap: 6)
          PhraseText(caption, hidden: hidden).hType(.body).foregroundStyle(HColor.textOnWashSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      VStack(alignment: .leading, spacing: 10) {
        CategoryPaceBar(spent: detail.progress, tick: detail.tick, verdict: detail.verdict, onWash: true,
                        phase: phase)
        verdict.opacity(phase.verdictVisible ? 1 : 0)
      }
    }
    .padding(.horizontal, HSpacing.insetPage)
    .paceFillSequence($phase, target: min(1, detail.progress.fraction), policy: policy)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(spoken)
    .accessibilityAddTraits(.isStaticText)
    .accessibilityIdentifier("category.hero")
  }

  private var caption: MoneyPhrase {
    MoneyPhrase([.text(over ? "over " : "left of "), .amount(detail.budget, .compact, hidden: 3),
                 .text(" this month")])
  }

  private var verdict: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(alignment: .top, spacing: 6) {
        Circle().fill(dotColor).frame(width: 8, height: 8).frame(height: lane)
        Text("\(Text(detail.verdictWord).font(HType.subheadline.weight(.semibold).font))\(factText)")
          .hType(.subheadline)
          .foregroundStyle(detail.verdict.foreground)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let advice = detail.advice {
        PhraseText(advice, hidden: hidden).hType(.subheadline).foregroundStyle(HColor.textOnWashSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  @ScaledMetric(relativeTo: .subheadline) private var lane: CGFloat = 20

  private var factText: Text {
    Text(verbatim: detail.verdictFact.map { " · " + $0.rendered(hidden: hidden) } ?? "")
  }

  private var dotColor: Color {
    detail.verdict == .overPace ? HColor.paceFillOverPace : detail.verdict.foreground
  }

  private var spoken: String {
    let amount = hidden ? "Amount hidden" : "AED \(MoneyFormat.string(detail.left.minor))"
    var out = "\(detail.name), \(amount) \(caption.spoken(hidden: hidden)). \(detail.verdictWord)"
    if let fact = detail.verdictFact { out += ", \(fact.spoken(hidden: hidden))" }
    out += "."
    if let advice = detail.advice { out += " \(advice.spoken(hidden: hidden))." }
    return out
  }
}

private struct ChartCard: View {
  let chart: DayByDay
  let name: String
  let hue: Hue
  let bucket: Bucket
  let hidden: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      ReflowingRow(alignment: .firstTextBaseline) {
        Text("Day by day").hType(.headline).foregroundStyle(HColor.textPrimary).accessibilityAddTraits(.isHeader)
      } trailing: {
        Text(chart.range).hType(.footnote).foregroundStyle(HColor.textSecondary)
      }
      DayByDayChart(chart: chart, name: name, hue: hue, bucket: bucket, hidden: hidden)
      if let caption = chart.caption {
        Text(caption).hType(.footnote).foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .listCard()
    .padding(.horizontal, HSpacing.insetPage)
  }
}

private struct ThisMonth: View {
  let detail: CategoryDetail
  let model: any CategoryDetailModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      CountedTitle(title: "This month", count: detail.transactions.count)
      HListCard {
        LazyVStack(spacing: 0) {
          ForEach(Array(detail.transactions.enumerated()), id: \.element.id) { i, row in
            if i > 0 { HDivider(inset: .disc68) }
            Button { model.open(row.id) } label: { TransactionRow(row, hidden: model.hidden) }
              .buttonStyle(HRowPressStyle())
              .accessibilityIdentifier("plan.txn.\(row.id)")
          }
        }
      }
    }
    .padding(.horizontal, HSpacing.insetPage)
  }
}

struct CountedTitle: View {
  let title: String
  let count: Int

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(title).hType(.section).foregroundStyle(HColor.textPrimary)
      Text("\(count)").hFigure(HFigure.small.weight(.semibold)).foregroundStyle(HColor.textSecondary)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(title), \(count)")
    .accessibilityAddTraits(.isHeader)
  }
}

private struct Rules: View {
  let detail: CategoryDetail
  let model: any CategoryDetailModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Rules that sort into \(detail.name)").hType(.section).foregroundStyle(HColor.textPrimary)
        .accessibilityAddTraits(.isHeader)
        .fixedSize(horizontal: false, vertical: true)
      PlanListCard(inset: .icon52) {
        ForEach(detail.rules) { rule in
          Button { model.openRules() } label: {
            HListRow(leading: .icon22(.wand, color: HColor.iconPrimary), title: rule.title,
                     supporting: .text(rule.detail), trailing: .chevron)
          }
          .buttonStyle(HRowPressStyle())
          .accessibilityIdentifier("plan.rule.\(rule.id)")
        }
        if BuildSurface.showsUnfinished {
          Button { model.addRule() } label: {
            SettingsRow(icon: .add, title: "Add a rule", accessory: .none, role: .action)
          }
          .buttonStyle(HRowPressStyle())
          .accessibilityIdentifier("plan.addRule")
        }
      }
    }
    .padding(.horizontal, HSpacing.insetPage)
  }
}
