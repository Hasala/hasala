import HasalaDesign
import HasalaModels
import SwiftUI

struct BudgetEditSheet: View {
  let model: any BudgetSheetModel
  @State private var draft = ""
  @State private var source: CategoryID?
  @State private var picking = false
  @State private var fitted: CGFloat = 0
  @State private var opensLarge: Bool?
  @State private var askingDiscard = false
  @FocusState private var typing: Bool
  @Environment(\.dismiss) private var dismiss
  private let openedDraft: String
  private let openedSource: CategoryID?
  @Environment(\.dynamicTypeSize) private var typeSize

  init(model: any BudgetSheetModel) {
    self.model = model
    var openedDraft = ""
    var openedSource: CategoryID?
    if let row = model.row {
      openedDraft = PlanAmountField.text(for: row.budget.minor)
      openedSource = model.sources(to: row.id).first?.id
      _draft = State(initialValue: openedDraft)
      _source = State(initialValue: openedSource)
    }
    self.openedDraft = openedDraft
    self.openedSource = openedSource
  }

  static func isDirty(draft: String, openedDraft: String, source: CategoryID?, openedSource: CategoryID?) -> Bool {
    MoneyFormat.parseMinor(draft) != MoneyFormat.parseMinor(openedDraft) || source != openedSource
  }

  private var isDirty: Bool {
    model.row != nil && Self.isDirty(draft: draft, openedDraft: openedDraft, source: source, openedSource: openedSource)
  }

  private var amount: Int64? { MoneyFormat.parseMinor(draft) }

  var body: some View {
    NavigationStack {
      Group {
        if let row = model.row {
          ScrollView {
            content(row)
              .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fitted = $0 }
          }
          .scrollBounceBehavior(.basedOnSize)
          .ignoresSafeArea(.container, edges: (opensLarge ?? typeSize.isAccessibilitySize) ? [] : .bottom)
        } else {
          EmptyStateCard(icon: .tag, tone: .neutral, title: "This category is gone",
                         message: "It was archived or removed.")
        }
      }
      .background(HColor.sheetSurface)
      .toolbar(.hidden, for: .navigationBar)
      .navigationDestination(isPresented: $picking) {
        SourcePickerPage(title: "Take it from", sources: sources, selected: source, hidden: model.hidden,
                         onCard: false) { id in
          source = id
          picking = false
        }
      }
    }
    .discardGuard(isDirty, title: "Discard this change?", asking: $askingDiscard) { dismiss() }
    .planMediumSheet(height: fitted, large: opensLarge ?? typeSize.isAccessibilitySize)
    .onAppear { if opensLarge == nil { opensLarge = typeSize.isAccessibilitySize } }
  }

  private func content(_ row: PlanRowModel) -> some View {
    VStack(spacing: 20) {
      PlanSheetHeader(title: "\(Bidi.isolate(row.name)) budget", closeID: "budget.close") {
        DiscardGuard.close(isDirty: isDirty, asking: $askingDiscard) { dismiss() }
      }
      mathRow(row)
      VStack(alignment: .leading, spacing: 12) {
        PlanOverline("New budget")
        stepper
        chips(row)
      }
      sourceField(row)
      commit(row)
    }
    .padding(.top, 33)
    .padding(.horizontal, HSpacing.sheetPadding)
    .padding(.bottom, 28)
    .toolbar {
      ToolbarItemGroup(placement: .keyboard) {
        Spacer()
        Button("Done") { typing = false }
      }
    }
  }

  private func mathRow(_ row: PlanRowModel) -> some View {
    let left = row.leftMinor
    let cells: [(String, Money, MoneyStyle)] = [
      ("Budget", row.budget, .compact), ("Spent", row.spent, .exact),
      (left < 0 ? "Over" : "Left", .aed(abs(left)), .exact),
    ]
    let stacked = typeSize.isAccessibilitySize
    func figure(_ i: Int) -> some View {
      MoneyText(cells[i].1, figure: .stat, style: cells[i].2, hidden: model.hidden, hiddenGlyphs: 4,
                color: i == 2 && left < 0 ? HColor.statusErrorForeground : HColor.textPrimary)
    }
    let layout = stacked ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
    return layout {
      ForEach(Array(cells.enumerated()), id: \.offset) { i, cell in
        if i > 0 {
          Rectangle().fill(HColor.appleSeparatorsNonOpaque)
            .frame(width: stacked ? nil : 1, height: stacked ? 1 : 32)
        }
        Group {
          if stacked {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
              Text(cell.0).hType(.footnote).foregroundStyle(HColor.textSecondary)
              Spacer(minLength: 0)
              figure(i)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
          } else {
            VStack(spacing: 2) {
              Text(cell.0).hType(.footnote).foregroundStyle(HColor.textSecondary)
              figure(i)
            }
            .frame(maxWidth: .infinity)
          }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
      }
    }
    .padding(.vertical, stacked ? 4 : 14)
    .padding(.horizontal, 4)
    .background(HColor.surfaceSecondary, in: RoundedRectangle(cornerRadius: HRadius.tile, style: .continuous))
  }

  private var stepper: some View {
    HStack(spacing: 8) {
      stepButton(.minus, label: "Less") { step(-100_00) }
      PlanAmountField(text: $draft, identifier: "budget.amount", label: "New budget", focus: $typing)
        .frame(maxWidth: .infinity)
      stepButton(.add, label: "More") { step(100_00) }
    }
  }

  private func stepButton(_ icon: HIcon, label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HIconView(icon, size: HSpacing.iconGlass, color: HColor.textLink)
        .frame(width: HSpacing.glassButton, height: HSpacing.glassButton)
        .background(HColor.actionAccentSubtle, in: Circle())
    }
    .buttonStyle(HPressStyle(in: Circle()))
    .accessibilityLabel(label)
  }

  private func chips(_ row: PlanRowModel) -> some View {
    GrowingChipRows(spacing: 8, lineSpacing: 8 - 2 * QuickChip.reach) {
      QuickChip(title: "+ 200", hidden: model.hidden, titleIsFigure: true) { step(200_00) }
        .accessibilityLabel("Add 200")
      if let last = model.lastMonth {
        QuickChip(title: "Match \(last.name)", figure: MoneyPhrase([.amount(last.spent, .rounded, hidden: 3)]),
                  hidden: model.hidden) { set(last.spent.minor.plus(50) / 100 * 100) }
      }
      if let projected = model.projected, projected.minor != row.budget.minor {
        QuickChip(title: "Cover the pace", figure: MoneyPhrase([.amount(projected, .compact, hidden: 3)]),
                  hidden: model.hidden) { set(projected.minor) }
      }
    }
    .padding(.top, 4 - QuickChip.reach)
    .padding(.bottom, -QuickChip.reach)
  }

  private var sources: [MoveSource] { model.sources(to: model.row?.id) }
  private var pick: BudgetSource<MoveSource> { PlanEngine.budgetSource(picked: source, offered: sources) }
  private var chosen: MoveSource? {
    if case .offered(let s) = pick { s } else { nil }
  }
  private var gone: CategoryID? {
    if case .gone(let id) = pick { id } else { nil }
  }
  private var sourceName: String {
    if let gone { return model.plan.row(gone)?.name ?? "Choose a category" }
    return chosen?.name ?? "Ready to assign"
  }

  private func rise(_ row: PlanRowModel) -> Int64? { amount.map { $0 - row.budget.minor } }

  @ViewBuilder private func sourceField(_ row: PlanRowModel) -> some View {
    let cut = (rise(row) ?? 0) < 0
    let choosable = !cut && (sources.count > 1 || (gone != nil && !sources.isEmpty))
    let label = Text(cut ? "Goes back to" : "Take it from").hType(.callout).foregroundStyle(HColor.textSecondary)
    let value = SideBySideOrStacked(spacing: 6, spreads: false) {
      Text(cut ? "Ready to assign" : sourceName)
        .hType(.rowTitle).foregroundStyle(HColor.textPrimary)
      if !cut, let chosen {
        MoneyText(chosen.available, figure: HFigure.row.weight(.semibold), hidden: model.hidden, hiddenGlyphs: 3,
                  color: HColor.textSecondary)
      }
    }
    let content = HStack(spacing: 6) {
      SideBySideOrStacked(spacing: 12) {
        label
        value
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if choosable {
        HIconView(.chevronRight, size: HSpacing.iconSmall, color: HColor.listRowChevron)
      }
    }
    .padding(.leading, 16)
    .padding(.trailing, 12)
    .padding(.vertical, 6)
    .frame(minHeight: HSpacing.fieldMinHeight)
    .background(HColor.fieldSurface, in: RoundedRectangle(cornerRadius: HRadius.field, style: .continuous))
    .hContrastEdge(RoundedRectangle(cornerRadius: HRadius.field, style: .continuous))

    if !choosable {
      content
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(cut ? "Goes back to Ready to assign" : "Take it from \(sourceName)")
        .accessibilityIdentifier("budget.source")
    } else {
      Button { picking = true } label: { content.contentShape(Rectangle()) }
        .buttonStyle(HPressStyle(in: RoundedRectangle(cornerRadius: HRadius.field, style: .continuous), scales: false))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Take it from")
        .accessibilityValue(chosen.map { "\($0.name), \($0.detail.spoken(hidden: model.hidden))" } ?? sourceName)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("budget.source")
    }
  }

  private func commit(_ row: PlanRowModel) -> some View {
    VStack(spacing: 12) {
      if let refusal {
        InlineStatus(tone: .error, text: refusal, size: .regular)
          .frame(maxWidth: .infinity)
          .accessibilityIdentifier("budget.refusal")
      } else if let preview = preview(row) {
        preview
          .multilineTextAlignment(.center)
          .frame(maxWidth: .infinity)
          .accessibilityIdentifier("budget.consequence")
      }
      Button(amount.map { "Set to AED \(MoneyFormat.string($0, style: .compact))" } ?? "Enter a budget") {
        guard let amount, refusal == nil else { return }
        typing = false
        _ = model.setBudget(.aed(amount), takingFrom: chosen?.id)
      }
      .buttonStyle(.pill(.primary, fill: true))
      .disabled(amount == nil || amount == row.budget.minor || refusal != nil)
      .accessibilityIdentifier("budget.save")
    }
  }

  private var refusal: String? {
    guard let row = model.row, let rise = rise(row), rise > 0 else { return nil }
    if let gone { return model.refusal(noLongerOffered: gone) }
    guard let from = chosen?.id else { return nil }
    return model.refusal(moving: .aed(rise), from: from)
  }

  private func preview(_ row: PlanRowModel) -> AnyView? {
    guard let rise = rise(row) else { return nil }
    let rta = model.plan.readyToAssign.minor
    let (words, after): (String, Int64)
    if rise > 0, let from = chosen, from.id != nil {
      (words, after) = ("\(from.name) keeps", from.available.minor - rise)
    } else {
      (words, after) = ("Ready to assign becomes", rta - rise)
    }
    let sign = after < 0 && !model.hidden ? "\u{2212}" : ""
    let figure = MoneyPhrase([.text("\(sign)AED "), .amount(.aed(abs(after)), hidden: 3)])
    return AnyView(
      SideBySideOrStacked(spacing: 4, spreads: false, stackedAlignment: .center) {
        Text(words).hType(.subheadline).foregroundStyle(HColor.textSecondary)
        Text(figure.rendered(hidden: model.hidden)).hFigure(.compact)
          .foregroundStyle(after < 0 ? HColor.statusErrorForeground : HColor.textPrimary)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("\(words) \(figure.spoken(hidden: model.hidden))")
      .accessibilityAddTraits(.isStaticText)
    )
  }

  private func step(_ by: Int64) {
    set((amount ?? 0) + by)
  }

  private func set(_ minor: Int64) {
    draft = PlanAmountField.text(for: AmountEntry.clamped(minor))
  }
}
