import HasalaDesign
import HasalaModels
import SwiftUI

#if HASALA_MOCKS
  import HasalaMocks
#endif

struct ActivityView: View {
  @Bindable var app: AppModel
  let model: any ActivityModel

  var body: some View {
    NavigationStack(path: Bindable(app.router).activity) {
      TabScreen(app: app, title: "Activity") {
        ActivityFilterBar(model: model)
      } content: {
        ActivityContent(model: model, showsChips: false)
      }
      .navigationDestination(for: ActivityRoute.self) { route in
        switch route {
        case .bill(let id): BillDetailView(app: app, bill: id)
        }
      }
    }
    .onAppear(perform: takeRequest)
    .onChange(of: app.router.pendingActivityFilter) { takeRequest() }
  }

  private func takeRequest() {
    if let filter = app.router.takeActivityFilter() { model.apply(filter) }
  }
}

struct ActivityFilterBar: View {
  let model: any ActivityModel

  private var snap: ActivitySnapshot { model.snapshot }

  var body: some View {
    if let summary = snap.summary, let category = snap.filter.category {
      VStack(alignment: .leading, spacing: 16) {
        periodRow
        ActiveFilterChip(title: summary.title, hue: summary.hue) { model.show(category: nil) }
          .accessibilityIdentifier("activity.filter.\(category)")
      }
    } else {
      VStack(alignment: .leading, spacing: 20) {
        periodRow
        if let query = Self.queryTitle(model.searchText) {
          ActiveFilterChip(title: query, icon: .magnifier, label: "Searching for \(model.searchText.trimmedSpaces)") {
            model.search("")
          }
          .accessibilityIdentifier("activity.query")
        }
        chips
          .padding(.horizontal, -HSpacing.insetPage)
      }
    }
  }

  static func queryTitle(_ text: String) -> String? {
    let q = text.trimmedSpaces
    return q.isEmpty ? nil : "\u{201C}\(q)\u{201D}"
  }

  private var pill: some View {
    PeriodPill(snap.period.title, tinted: !snap.isThisMonth) { model.choosePeriod() }
      .hContrastEdge(Capsule())
      .accessibilityIdentifier("activity.period")
  }

  private var countLine: some View {
    Text(snap.countLine)
      .hType(.subheadline)
      .foregroundStyle(HColor.textSecondary)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityIdentifier("activity.count")
  }

  @ViewBuilder private var periodRow: some View {
    if snap.allTime {
      countLine
        .frame(minHeight: HSpacing.targetMinimum, alignment: .leading)
    } else if snap.isThisMonth, snap.summary != nil {
      pill
    } else if snap.isThisMonth {
      ReflowingRow(spacing: 12) {
        pill
      } trailing: {
        countLine
      }
    } else {
      ReflowingRow(spacing: 12) {
        pill
      } trailing: {
        BackToThisMonthLink { model.backToThisMonth() }
          .accessibilityIdentifier("activity.backToThisMonth")
      }
    }
  }

  private var chips: some View {
    ScrollView(.horizontal) {
      HStack(spacing: HSpacing.chipGap) {
        ForEach(snap.chips) { chip in
          FilterChip(chip.kind.title, count: chip.count.flatMap { $0 > 0 ? $0 : nil },
                     countStyle: chip.accentCount ? .accent : .plain,
                     selected: snap.filter.kind == chip.kind) { model.select(chip.kind) }
            .accessibilityIdentifier("activity.chip.\(chip.kind.rawValue)")
        }
      }
      .padding(.horizontal, HSpacing.insetPage)
      .padding(.vertical, 2)
    }
    .scrollIndicators(.hidden)
  }
}

struct ActiveFilterChip: View {
  let title: String
  var hue: Hue?
  var icon: HIcon?
  var label: String?
  let clear: () -> Void

  init(title: String, hue: Hue, clear: @escaping () -> Void) {
    self.title = title
    self.hue = hue
    self.clear = clear
  }

  init(title: String, icon: HIcon, label: String, clear: @escaping () -> Void) {
    self.title = title
    self.icon = icon
    self.label = label
    self.clear = clear
  }

  var body: some View {
    Button(action: clear) {
      HStack(spacing: 7) {
        if let hue {
          Circle().fill(hue.dotGradient).frame(width: 8, height: 8)
        } else if let icon {
          HIconView(icon, size: 14, color: HColor.widgetOnInverseSecondary, strokeWidth: 2.4)
        }
        Text(title).lineLimit(1).hType(.smallButton).foregroundStyle(HColor.chipTextSelected)
        HIconView(.close, size: 16, color: HColor.widgetOnInverseSecondary, strokeWidth: 2.4)
      }
      .padding(.leading, 14)
      .padding(.trailing, 12)
      .frame(minHeight: HSpacing.chipHeight)
      .background(HColor.chipSurfaceSelected, in: Capsule())
      .contentShape(Capsule().inset(by: -2))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label ?? "Filtered by \(title)")
    .accessibilityHint(icon == nil ? "Shows every transaction again" : "Clears the search")
    .accessibilityAddTraits(.isSelected)
  }
}

struct ActivityContent: View {
  let model: any ActivityModel
  var showsChips = true
  @State private var openRow: TxnID?

  private var snap: ActivitySnapshot { model.snapshot }

  var body: some View {
    VStack(alignment: .leading, spacing: HSpacing.gapScreenSection) {
      if showsChips {
        ActivityFilterBar(model: model).padding(.horizontal, HSpacing.insetPage)
      }
      if let summary = snap.summary {
        filtered(summary)
      } else {
        overview
      }
    }
    .onChange(of: snap.filter) { openRow = nil }
  }

  @ViewBuilder private var overview: some View {
    if let review = snap.review {
      ToReviewRow(review: review, hidden: model.hidden) { model.startReview() }
        .padding(.horizontal, HSpacing.insetPage)
    }

    if !snap.comingUp.isEmpty {
      let shown = Self.comingUpShown(snap.comingUp)
      VStack(alignment: .leading, spacing: 12) {
        header("Coming up") {
          Text("next 7 days").hType(.subheadline).foregroundStyle(HColor.textSecondary)
        }
        HListCard {
          ForEach(Array(shown.rows.enumerated()), id: \.element.id) { i, row in
            if i > 0 { HDivider(inset: .disc68) }
            Button { model.openBill(row.id) } label: {
              BillRowView(row, hidden: model.hidden).contentShape(Rectangle())
            }
            .buttonStyle(HRowPressStyle())
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("bill.\(row.id)")
          }
          if shown.more > 0 {
            HDivider(inset: .text16)
            Button { model.openBills() } label: {
              HStack(spacing: 8) {
                Text("See all bills").hType(.rowTitle).foregroundStyle(HColor.textLink)
                  .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(MoneyFormat.count(shown.more)) more").hType(.subheadline)
                  .foregroundStyle(HColor.textSecondary)
                HIconView(.chevronRight, size: HSpacing.iconSmall, color: HColor.listRowChevron)
              }
              .padding(.horizontal, 16)
              .frame(minHeight: 52)
              .contentShape(Rectangle())
            }
            .buttonStyle(HRowPressStyle())
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("activity.allBills")
          }
        }
      }
      .padding(.horizontal, HSpacing.insetPage)
    }

    VStack(alignment: .leading, spacing: 12) {
      header(model.searchText.isEmpty ? "History" : "Results") {
        ExportLink(rows: model.exportRows, title: "Export")
      }
      if !snap.isThisMonth, snap.filter.kind == .all, !snap.filter.isSearching {
        Text(snap.countLine)
          .hType(.subheadline)
          .foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("activity.count")
      }
      if snap.days.isEmpty {
        EmptyListCard(kind: snap.filter.kind, query: model.searchText, period: snap.period, isThisMonth: snap.isThisMonth)
      } else {
        LazyVStack(alignment: .leading, spacing: 20) {
          ForEach(snap.days) { day in
            VStack(alignment: .leading, spacing: 8) {
              DayHeader(day: day, hidden: model.hidden)
              rows(day.rows)
            }
          }
        }
      }
    }
    .padding(.horizontal, HSpacing.insetPage)
  }

  static func comingUpShown(_ rows: [BillRowModel], limit: Int = 2) -> (rows: [BillRowModel], more: Int) {
    (Array(rows.prefix(limit)), max(0, rows.count - limit))
  }

  static func minutes(_ n: Int) -> String {
    let m = max(1, (n + 5) / 6)
    if m > 60 {
      let h = (m + 30) / 60
      return "about \(MoneyFormat.count(h)) hour\(h == 1 ? "" : "s")"
    }
    return "about \(m) minute\(m == 1 ? "" : "s")"
  }

  private func filtered(_ summary: FilterSummary) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      FilterSummaryCard(summary: summary, hidden: model.hidden)
      if !snap.rows.isEmpty {
        rows(snap.rows)
        ExportLink(rows: model.exportRows, title: "Export these \(snap.rows.count)", prominent: true)
      } else {
        EmptyListCard(kind: .all, query: "", period: snap.period, isThisMonth: snap.isThisMonth,
                      category: summary.title)
      }
    }
    .padding(.horizontal, HSpacing.insetPage)
  }

  private func header<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
    ReflowingRow(alignment: .firstTextBaseline) {
      Text(title).hType(.section).foregroundStyle(HColor.textPrimary).accessibilityAddTraits(.isHeader)
    } trailing: {
      trailing()
    }
  }

  private func rows(_ rows: [MiniTxnRow]) -> some View {
    HListCard {
      ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
        if i > 0 { HDivider(inset: .disc68) }
        SwipeActionRow(id: row.id, open: $openRow, action: swipe(row.id)) {
          Button {
            if openRow != nil { openRow = nil } else { model.open(row.id) }
          } label: {
            TransactionRow(row, hidden: model.hidden).contentShape(Rectangle())
          }
          .buttonStyle(HRowPressStyle())
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier("txn.\(row.id)")
        }
      }
    }
  }

  private func swipe(_ id: TxnID) -> SwipeAction {
    if snap.filter.kind == .archived {
      SwipeAction(title: "Restore", icon: .archive, fill: HColor.actionAccent, ink: HColor.textOnAccent) {
        model.setArchived(id, false)
      }
    } else {
      SwipeAction(title: "Archive", icon: .archive, fill: HColor.neutral600, ink: HColor.textOnAccent) {
        model.setArchived(id, true)
      }
    }
  }
}

private struct DayHeader: View {
  let day: DayGroup
  let hidden: Bool

  var body: some View {
    OverlineHeader(day.title) {
      MoneyText(day.total, figure: HFigure.badge.weight(.semibold), hidden: hidden, hiddenGlyphs: 3,
                color: HColor.textSecondary, sign: day.total.isNegative ? .income : .none)
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
  }
}

private struct EmptyListCard: View {
  let kind: TxnFilter.Kind
  let query: String
  let period: Period
  let isThisMonth: Bool
  var category: String?

  private var when: String { isThisMonth ? "this month" : period.isAllTime ? "yet" : "in \(period.title)" }

  var body: some View {
    VStack(spacing: 8) {
      Text(copy.title).hType(.rowTitle).foregroundStyle(HColor.textPrimary)
      Text(copy.detail).hType(.footnote).foregroundStyle(HColor.textSecondary)
    }
    .multilineTextAlignment(.center)
    .fixedSize(horizontal: false, vertical: true)
    .padding(.vertical, 24)
    .padding(.horizontal, 20)
    .frame(maxWidth: .infinity)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.listGroup, style: .continuous))
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("activity.empty")
  }

  private var copy: (title: String, detail: String) {
    if !query.trimmingCharacters(in: .whitespaces).isEmpty {
      return ("No matches for “\(query)”", "Try a merchant name or a category.")
    }
    if let category {
      return ("Nothing in \(category) \(when)", "Transactions you sort into \(category) show here.")
    }
    switch kind {
    case .all:
      return (isThisMonth ? "Nothing yet this month" : "Nothing \(when)",
              "Card payments usually show here a minute after your bank's email.")
    case .toReview: return ("Nothing to sort", "Transactions Hasala can't sort show up here.")
    case .bills:
      return (isThisMonth ? "No bills paid this month yet" : "No bills paid \(when)",
              "Payments to bills you track show here.")
    case .transfers: return ("No transfers \(when)", "Money moved between your accounts shows here.")
    case .income:
      return (isThisMonth ? "No income this month yet" : "No income \(when)",
              "Salary and other money in shows here.")
    case .archived: return ("Nothing archived", "Archived transactions wait here, outside your plan.")
    }
  }
}

struct ToReviewRow: View {
  let review: ReviewSummary
  let hidden: Bool
  let start: () -> Void

  static func phrase(_ review: ReviewSummary) -> MoneyPhrase {
    MoneyPhrase([.text("AED "), .amount(review.unplanned), .text(" · \(ActivityContent.minutes(review.count))")]
                + (review.mark?.caption.map { [.text(" · \($0)")] } ?? []))
  }

  var body: some View {
    Button(action: start) {
      HStack(spacing: 12) {
        ReviewDeckArt()
          .scaleEffect(44.0 / 72.0)
          .frame(width: 44, height: 44)
        VStack(alignment: .leading, spacing: 1) {
          Text("\(MoneyFormat.count(review.count)) to sort").hType(.rowTitle).foregroundStyle(HColor.listRowTitle)
          PhraseText(Self.phrase(review), hidden: hidden)
            .hType(.subheadline).foregroundStyle(HColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        HIconView(.chevronRight, size: HSpacing.iconSmall, color: HColor.listRowChevron)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      .frame(minHeight: 64)
      .contentShape(Rectangle())
    }
    .buttonStyle(HRowPressStyle())
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
    .clipShape(RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
    .accessibilityElement(children: .combine)
    .accessibilityHint("Starts review")
    .accessibilityIdentifier("activity.startReview")
  }
}

struct FilterSummaryCard: View {
  let summary: FilterSummary
  let hidden: Bool
  @State private var phase = PaceFillPhase()
  @Environment(\.hMotion) private var policy

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text("\(MoneyFormat.count(summary.count)) transaction\(summary.count == 1 ? "" : "s")").hType(.subheadline)
          .foregroundStyle(HColor.textSecondary)
        MoneyText(summary.total, figure: .large, unit: .unit, hidden: hidden, color: HColor.moneyOut,
                  unitColor: HColor.textPrimary, unitGap: 5)
          .accessibilityIdentifier("activity.summary.total")
      }
      if summary.budgeted {
        CategoryPaceBar(spent: summary.progress, tick: summary.today, verdict: summary.verdict, phase: phase)
          .paceFillSequence($phase, target: min(1, summary.progress.fraction), policy: policy)
        ReflowingRow(spacing: 12) {
          PhraseText(summary.caption, hidden: hidden).hType(.footnote).foregroundStyle(HColor.textSecondary)
        } trailing: {
          StatusDotLine(words: summary.verdict.label, verdict: summary.verdict)
        }
      } else {
        PhraseText(summary.caption, hidden: hidden).hType(.footnote).foregroundStyle(HColor.textSecondary)
      }
    }
    .padding(16)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
  }
}

struct StatusDotLine: View {
  let words: String
  let verdict: Verdict

  var body: some View {
    HStack(spacing: 6) {
      Circle().fill(verdict == .overPace ? HColor.paceFillOverPace : verdict.foreground).frame(width: 7, height: 7)
      Text(words)
        .hType(.footnote.weight(.semibold))
        .foregroundStyle(verdict.foreground)
    }
    .accessibilityElement(children: .combine)
  }
}

struct ExportLink: View {
  let rows: [ExportRow]
  let title: String
  var prominent = false

  var body: some View {
    let file = CSVFile(rows: rows, name: CSVExport.fileName(rows.first?.date ?? LocalDate(2026, 1, 1)))
    Group {
      if prominent {
        ShareLink(item: file, preview: SharePreview(file.name)) { Text(title) }
          .buttonStyle(.pill(.onGrouped, fill: true, leadingIcon: .download))
      } else {
        ShareLink(item: file, preview: SharePreview(file.name)) { Text(title) }
          .buttonStyle(.inlineLink)
      }
    }
    .disabled(rows.isEmpty)
    .accessibilityIdentifier("activity.export")
  }
}

#if HASALA_MOCKS
  #Preview("Activity · Overview") {
    let app = AppModel(store: InMemoryLedger())
    ActivityView(app: app, model: ActivityViewModel(app: app))
  }
#endif
