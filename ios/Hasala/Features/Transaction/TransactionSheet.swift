import HasalaDesign
import HasalaModels
import SwiftUI

#if HASALA_MOCKS
  import HasalaMocks
#endif

struct TransactionSheet: View {
  @Bindable var app: AppModel
  let model: any TransactionModel
  @State private var confirmApart = false
  @ScaledMetric(relativeTo: .subheadline) private var senderLane: CGFloat = 20
  @Environment(\.dismiss) private var dismiss
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    NavigationStack(path: Bindable(app.router).transaction) {
      Group {
        if let d = model.detail {
          content(d)
        } else {
          Text("This transaction is no longer here.")
            .hType(.subheadline).foregroundStyle(HColor.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .background(HColor.sheetSurfaceLarge)
      .navigationTitle("Transaction")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        SheetCloseButton(identifier: "txn.close") { dismiss() }
        if let d = model.detail {
          ToolbarItem(placement: .topBarTrailing) {
            Menu {
              Button(d.archived ? "Restore" : "Archive") { model.setArchived(!d.archived) }
            } label: {
              HIconView(.more, size: HSpacing.iconGlass, color: HColor.iconGlass)
            }
            .accessibilityLabel("More")
            .accessibilityIdentifier("txn.more")
          }
        }
      }
      .navigationDestination(for: TransactionRoute.self) { route in
        switch route {
        case .category: CategoryPickerView(model: model) { app.router.transaction.removeAll() }
        case .note:
          NoteEditorView(note: model.detail?.note ?? "") {
            if model.setNote($0) { app.router.transaction.removeAll() }
          }
        case .rename:
          RenameMerchantView(name: model.merchantName) {
            if model.rename($0) { app.router.transaction.removeAll() }
          }
        case .split: SplitEditorView(model: model) { app.router.transaction.removeAll() }
        case .project:
          if let d = model.detail {
            ProjectPickerView(app: app, txn: d.id) { app.router.transaction.removeAll() }
          }
        case .reviewReason(let reason):
          ReviewReasonPage(
            reason: reason, sort: { model.resolve(reason, merge: false) },
            archive: { model.setArchived(true) },
            merge: { model.resolve(reason, merge: true) },
            keepBoth: { model.resolve(reason, merge: false) })
        }
      }
      .confirmationDialog("Keep as two transactions?", isPresented: $confirmApart, titleVisibility: .visible) {
        Button("Keep both") { model.keepApart() }
      } message: {
        Text("Both emails will count. Do this only if you made two payments.")
      }
    }
    .overlay(alignment: .bottom) { ToastHost(app: app, placement: .bottom) }
    .presentationBackground(HColor.sheetSurfaceLarge)
    .presentationDragIndicator(.visible)
  }

  private func push(_ route: TransactionRoute) { app.router.transaction.append(route) }

  private func content(_ d: TransactionDetail) -> some View {
    ScrollView {
      VStack(spacing: 16) {
        summary(d)
        if let reason = d.reviewReason { reasonCallout(reason, line: d.reasonLine) }
        details(d)
        if d.isSample {
          sampleNote
        } else if let p = d.provenance {
          provenance(p, d)
        }
        if d.combined { combined }
        actions(d)
        archive(d)
      }
      .padding(.horizontal, HSpacing.insetPage)
      .padding(.top, 8)
      .padding(.bottom, 40)
    }
    .scrollEdgeEffectStyle(.soft, for: .bottom)
  }

  private func summary(_ d: TransactionDetail) -> some View {
    VStack(spacing: 12) {
      if let m = d.monogram {
        MerchantMonogram(letter: m, size: 56)
      } else {
        CategoryDisc(hue: d.hue, icon: d.glyph.icon, size: .s56)
      }
      VStack(spacing: 2) {
        Text(d.merchant).hType(.section).foregroundStyle(HColor.textPrimary)
          .multilineTextAlignment(.center)
          .accessibilityAddTraits(.isHeader)
          .accessibilityIdentifier("txn.merchant")
        let home = d.home ?? HomeAmount(shown: d.amount)
        MoneyText(home.shown, figure: .large, unit: .unit, hidden: model.hidden,
                  color: d.isIncome ? HColor.moneyIn : HColor.moneyOut,
                  unitColor: d.isIncome ? HColor.moneyIn : HColor.textPrimary, unitGap: 5,
                  sign: d.isIncome ? .income : .none, approx: home.estimate)
          .accessibilityIdentifier("txn.amount")
        if home.notCounted {
          Text("Not counted").hType(.subheadline.weight(.semibold)).foregroundStyle(HColor.textSecondary)
            .accessibilityIdentifier("txn.notCounted")
        } else if let o = home.original, !model.hidden {
          Text("\(o.currency) \(MoneyFormat.string(o))").hType(.subheadline).foregroundStyle(HColor.textSecondary)
            .accessibilityIdentifier("txn.original")
        }
        Text(d.meta).hType(.subheadline).foregroundStyle(HColor.textSecondary)
          .multilineTextAlignment(.center)
          .padding(.top, 2)
        if let line = home.estimateLine {
          Text(line).hType(.footnote).foregroundStyle(HColor.textSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
            .accessibilityIdentifier("txn.estimate")
        }
      }
      let tags = tags(d)
      if !tags.isEmpty {
        let layout = typeSize.isAccessibilitySize
          ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 6))
        layout { pills(tags) }
      }
    }
    .frame(maxWidth: .infinity)
  }

  private func pills(_ tags: [StatusPill]) -> some View {
    ForEach(tags, id: \.text) { StatusPillView($0, size: .s26, surface: .tinted) }
  }

  private func tags(_ d: TransactionDetail) -> [StatusPill] {
    var out: [StatusPill] = []
    if d.needsReview { out.append(StatusPill("To review", tone: .accent)) }
    if d.isRefund { out.append(StatusPill("Refund", tone: .success)) }
    if d.isTransfer { out.append(StatusPill("Transfer", tone: .accent, showsDot: false)) }
    if d.archived { out.append(StatusPill("Archived", tone: .warning)) }
    return out
  }

  private func reasonCallout(_ reason: TxnReviewReason, line: String?) -> some View {
    let ink = ReviewReasonStyle.ink
    return Button { push(.reviewReason(reason)) } label: {
      HStack(alignment: .top, spacing: 12) {
        HIconView(ReviewReasonStyle.icon(reason), size: 20, color: ink, strokeWidth: 1.9)
          .frame(height: senderLane)
        VStack(alignment: .leading, spacing: 2) {
          Text(reason.title)
            .hType(.subheadline.weight(.semibold))
            .foregroundStyle(ink)
          Text(line ?? reason.detail)
            .hType(.footnote)
            .foregroundStyle(ink)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        HIconView(.chevronRight, size: 16, color: ink)
          .frame(maxHeight: .infinity)
      }
      .padding(.vertical, 14)
      .padding(.horizontal, 16)
      .background(ReviewReasonStyle.surface, in: RoundedRectangle(cornerRadius: HRadius.tile, style: .continuous))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(reason.title). \(line ?? reason.detail)")
    .accessibilityHint("Explains this and your choices")
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier("txn.reviewReason.\(reason.rawValue)")
  }

  private func details(_ d: TransactionDetail) -> some View {
    VStack(spacing: 0) {
      Button { push(d.splits.isEmpty ? .category : .split) } label: {
        categoryRow(d).contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Category, \(categoryValue(d))")
      .accessibilityAddTraits(.isButton)
      .accessibilityIdentifier("txn.category")

      if let pace = d.pace {
        HDivider(inset: .none)
        BudgetContext(pace: pace, hidden: model.hidden)
      }

      HDivider(inset: .none)
      KeyValueRow("Account", value: d.account ?? "Not set", placeholder: d.account == nil)

      HDivider(inset: .none)
      if d.canEditNote {
        Button { push(.note) } label: {
          KeyValueRow("Note", value: d.note.isEmpty ? "Add a note" : d.note, chevron: true, placeholder: d.note.isEmpty)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(d.note.isEmpty ? "Note, Add a note" : "Note, \(d.note)")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("txn.note")
      } else {
        KeyValueRow("Note", value: d.note)
          .accessibilityIdentifier("txn.note")
      }

      if d.project != nil || !model.projects.isEmpty {
        HDivider(inset: .none)
        Button { push(.project) } label: {
          KeyValueRow("Project", value: d.project ?? "None", chevron: true, placeholder: d.project == nil)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Project, \(d.project ?? "None")")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("txn.project")
      }
    }
    .padding(.horizontal, 16)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
  }

  private func categoryValue(_ d: TransactionDetail) -> String {
    if !d.splits.isEmpty { return "Split · \(d.splits.count)" }
    return d.category?.name ?? "Choose a category"
  }

  @ViewBuilder private func categoryRow(_ d: TransactionDetail) -> some View {
    if d.splits.isEmpty, let c = d.category {
      KeyValueRow("Category", value: c.name, dot: c.hue, chevron: true)
    } else {
      KeyValueRow("Category", value: categoryValue(d), chevron: true, placeholder: d.category == nil && d.splits.isEmpty)
    }
  }

  private func provenance(_ p: Provenance, _ d: TransactionDetail) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .center) {
        Text("From your bank").hType(.overline).foregroundStyle(HColor.textGroupedHeader)
          .accessibilityAddTraits(.isHeader)
        Spacer(minLength: 8)
        if BuildSurface.showsUnfinished, !p.isText {
          Button {
            app.say("Coming in a later build", icon: .envelope)
          } label: {
            HStack(spacing: 2) {
              Text("View the email").hType(.subheadline.weight(.semibold))
              HIconView(.chevronRight, size: 14, color: HColor.textLink, strokeWidth: 2.6)
            }
            .foregroundStyle(HColor.textLink)
            .frame(minHeight: HSpacing.targetMinimum)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .padding(.vertical, -12)
          .accessibilityIdentifier("txn.viewEmail")
        }
      }
      .padding(.horizontal, 4)

      VStack(alignment: .leading, spacing: 0) {
        HStack(alignment: .top, spacing: 14) {
          HIconView(p.isText ? .chat : .envelope, size: 22, color: HColor.iconPrimary)
          VStack(alignment: .leading, spacing: 2) {
            Text(p.title).hType(.rowTitle).foregroundStyle(HColor.textPrimary)
              .accessibilityIdentifier("txn.source")
            Text(p.readAt).hType(.footnote).foregroundStyle(HColor.textSecondary)
            if !p.rawMerchant.isEmpty {
              Text(verbatim: p.rawMerchant)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(HColor.textPrimary)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(HColor.surfaceSecondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.top, 8)
                .accessibilityLabel("Bank text: \(p.rawMerchant)")
                .accessibilityIdentifier("txn.rawMerchant")
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 16)
        if let sortedBy = d.sortedBy, Self.showsSource(sortedBy) {
          HColor.borderSubtle.frame(height: 1).padding(.leading, 36).accessibilityHidden(true)
          sortedRow(sortedBy, opensRules: d.sortedByRule)
        }
      }
      .padding(.horizontal, 16)
      .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
    }
  }

  static func showsSource(_ s: SortedBy) -> Bool {
    s.title != "Sorted by you" && s.title != "Added by you"
  }

  static func offersSplit(_ d: TransactionDetail) -> Bool { !d.isTransfer }

  @ViewBuilder private func sortedRow(_ s: SortedBy, opensRules: Bool) -> some View {
    let row = HStack(spacing: 14) {
      HIconView(.rule, size: 22, color: HColor.iconPrimary)
      VStack(alignment: .leading, spacing: 0) {
        Text(s.title).hType(.subheadline.weight(.medium)).foregroundStyle(HColor.textPrimary)
        Text(s.detail).hType(.footnote).foregroundStyle(HColor.textSecondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      if opensRules {
        HIconView(.chevronRight, size: HSpacing.iconSmall, color: HColor.listRowChevron)
      }
    }
    .padding(.vertical, 12)
    .frame(minHeight: 48)
    .contentShape(Rectangle())

    if opensRules {
      Button { app.router.open(.profile, profile: [.rules]) } label: { row }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens your rules")
        .accessibilityIdentifier("txn.rule")
    } else {
      row.accessibilityElement(children: .combine)
    }
  }

  private var sampleNote: some View {
    HStack(alignment: .top, spacing: 14) {
      HIconView(.info, size: 22, color: HColor.iconPrimary)
      Text("Sample data. No bank email behind it.")
        .hType(.rowTitle).foregroundStyle(HColor.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("txn.sample")
    }
    .padding(16)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
  }

  private var combined: some View {
    VStack(spacing: 0) {
      HStack(alignment: .top, spacing: 14) {
        HIconView(.envelope, size: 22, color: HColor.iconPrimary)
        VStack(alignment: .leading, spacing: 2) {
          Text("Combined with a second bank email").hType(.rowTitle).foregroundStyle(HColor.textPrimary)
          Text("Transfer notice and account alert, counted once.")
            .hType(.footnote).foregroundStyle(HColor.textSecondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(16)
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("txn.combined")
      HDivider(inset: .icon52)
      ActionRow(icon: .linkOff, title: "Keep as two transactions") { confirmApart = true }
        .accessibilityIdentifier("txn.keepApart")
    }
    .background(HColor.surfacePrimary)
    .clipShape(RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
  }

  private func actions(_ d: TransactionDetail) -> some View {
    VStack(spacing: 0) {
      if Self.offersSplit(d) {
        ActionRow(icon: .split, title: "Split across categories", pushes: true) { push(.split) }
          .accessibilityIdentifier("txn.split")
        HDivider(inset: .icon52)
      }
      ActionRow(icon: .pencil, title: "Rename merchant", pushes: true) { push(.rename) }
        .accessibilityIdentifier("txn.rename")
      HDivider(inset: .icon52)
      ActionRow(icon: .refund, title: d.isRefund ? "Not a refund" : "This is a refund") { model.toggleRefund() }
        .accessibilityIdentifier("txn.refund")
      if !d.isTransfer {
        HDivider(inset: .icon52)
        ActionRow(icon: .swap, title: "Mark as a transfer") { model.markTransfer() }
          .accessibilityIdentifier("txn.transfer")
      }
    }
    .background(HColor.surfacePrimary)
    .clipShape(RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
  }

  private func archive(_ d: TransactionDetail) -> some View {
    ActionRow(icon: .archive, title: d.archived ? "Restore" : "Archive",
              tint: d.archived ? HColor.textLink : HColor.listRowAction) {
      model.setArchived(!d.archived)
    }
    .accessibilityIdentifier("txn.archive")
    .background(HColor.surfacePrimary)
    .clipShape(RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
  }
}

private struct BudgetContext: View {
  let pace: EmbeddedPace
  let hidden: Bool
  @State private var phase = PaceFillPhase()
  @Environment(\.hMotion) private var policy

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ReflowingRow(spacing: 12, alignment: .firstTextBaseline) {
        Text(pace.title).hType(.subheadline).foregroundStyle(HColor.textSecondary)
      } trailing: {
        PhraseText(MoneyPhrase([.amount(pace.left.isNegative ? .aed(pace.left.minor.negated) : pace.left),
                                .text(pace.left.isNegative ? " over " : " left of "),
                                .amount(pace.budget, .compact)]), hidden: hidden)
          .hFigure(HFigure.compact.weight(.semibold))
          .foregroundStyle(HColor.textPrimary)
      }
      GeometryReader { geo in
        ZStack(alignment: .leading) {
          Capsule().fill(HColor.paceTrack)
          Capsule().fill(pace.verdict.fill)
            .frame(width: max(phase.fill > 0 ? 6 : 0, geo.size.width * phase.fill))
        }
      }
      .frame(height: 6)
      .accessibilityHidden(true)
      .paceFillSequence($phase, target: min(1, pace.progress.fraction), policy: policy)
      ReflowingRow(spacing: 12) {
        StatusDotLine(words: pace.verdict.label, verdict: pace.verdict)
      } trailing: {
        if let projection = pace.projection {
          PhraseText(projection, hidden: hidden).hType(.footnote).foregroundStyle(HColor.textSecondary)
        }
      }
    }
    .padding(.vertical, 14)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("txn.pace")
  }
}

struct ActionRow: View {
  let icon: HIcon
  let title: String
  var pushes = false
  var tint: Color = HColor.listRowTitle
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 14) {
        HIconView(icon, size: 22, color: tint == HColor.listRowTitle ? HColor.iconPrimary : tint)
        Text(title).hType(.rowTitle).foregroundStyle(tint)
          .frame(maxWidth: .infinity, alignment: .leading)
        if pushes {
          HIconView(.chevronRight, size: HSpacing.iconSmall, color: HColor.listRowChevron)
        }
      }
      .padding(.horizontal, 16)
      .frame(minHeight: 52)
      .contentShape(Rectangle())
    }
    .buttonStyle(HRowPressStyle())
    .accessibilityLabel(title)
  }
}

#if HASALA_MOCKS
  #Preview("Transaction · Carrefour") {
    let app = AppModel(store: InMemoryLedger())
    TransactionSheet(app: app, model: TransactionViewModel(app: app, id: "carrefour"))
  }
#endif
