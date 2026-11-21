import HasalaDesign
import HasalaModels
import SwiftUI

extension View {
  func planMediumSheet(height: CGFloat, large: Bool = false) -> some View {
    presentationDetents([large ? .large : (height > 0 ? .height(height) : .medium)])
      .presentationCornerRadius(HRadius.sheet)
      .presentationBackground(HColor.sheetSurface)
      .presentationDragIndicator(.visible)
      .background {
        if !large { FittedSheetDetent(height: height).frame(width: 0, height: 0) }
      }
  }

  func planLargeSheet() -> some View {
    presentationDetents([.large])
      .presentationCornerRadius(HRadius.sheetLarge)
      .presentationBackground(HColor.sheetSurfaceLarge)
      .presentationDragIndicator(.visible)
  }
}

struct FittedSheetDetent: UIViewControllerRepresentable {
  let height: CGFloat

  func makeUIViewController(context: Context) -> Controller { Controller() }

  func updateUIViewController(_ controller: Controller, context: Context) {
    controller.height = height
    controller.apply()
  }

  final class Controller: UIViewController {
    var height: CGFloat = 0
    private var applied: CGFloat = 0
    private static let fitted = UISheetPresentationController.Detent.Identifier("hasala.plan.fitted")

    override func viewWillAppear(_ animated: Bool) {
      super.viewWillAppear(animated)
      applied = 0
      apply()
    }

    override func viewDidAppear(_ animated: Bool) {
      super.viewDidAppear(animated)
      applied = 0
      apply()
    }

    func apply() {
      guard height > 0, height != applied, let sheet = presentingSheet else { return }
      applied = height
      let h = max(1, height - (sheet.presentedViewController.view.safeAreaInsets.bottom))
      let change = {
        sheet.detents = [.custom(identifier: Self.fitted) { context in min(h, context.maximumDetentValue) }]
        sheet.selectedDetentIdentifier = Self.fitted
      }
      if sheet.detents.contains(where: { $0.identifier == Self.fitted }) {
        sheet.animateChanges(change)
      } else {
        change()
      }
    }

    private var presentingSheet: UISheetPresentationController? {
      var vc: UIViewController? = self
      while let current = vc {
        if current.presentingViewController != nil, let sheet = current.sheetPresentationController {
          return sheet
        }
        vc = current.parent
      }
      return nil
    }
  }
}

struct PlanSheetHeader: View {
  let title: String
  let closeID: String
  let close: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      GlassIconButton(.close, label: "Close", action: close)
        .accessibilityIdentifier(closeID)
      Text(title).hType(.headline).foregroundStyle(HColor.textPrimary)
        .singleLineAtDefaultTextSize()
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .accessibilityAddTraits(.isHeader)
      Color.clear.frame(width: HSpacing.glassButton, height: HSpacing.glassButton)
        .accessibilityHidden(true)
    }
    .frame(minHeight: HSpacing.glassButton)
  }
}

struct PlanAmountField: View {
  @Binding var text: String
  let identifier: String
  let label: String
  var focus: FocusState<Bool>.Binding

  @ScaledMetric(relativeTo: .largeTitle) private var figure: CGFloat = 44
  @ScaledMetric(relativeTo: .largeTitle) private var line: CGFloat = 46
  @ScaledMetric(relativeTo: .body) private var unit: CGFloat = 17
  @Environment(\.dynamicTypeSize) private var typeSize

  private var shownFigure: CGFloat { min(figure, 50) }
  private var shownLine: CGFloat { line * shownFigure / figure }

  var body: some View {
    let layout = typeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 6))
    layout {
      Text("AED")
        .font(.system(size: unit, weight: .semibold, design: .rounded))
        .foregroundStyle(HColor.textPrimary)
        .fixedSize()
        .accessibilityHidden(true)
      TextField("", text: $text, prompt: .fieldPrompt("0"))
        .font(.system(size: shownFigure, weight: .bold, design: .rounded))
        .tracking(-0.8 * shownFigure / 44)
        .foregroundStyle(HColor.textPrimary)
        .keyboardType(.decimalPad)
        .focused(focus)
        .fixedSize()
        .frame(height: shownLine)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
        .onChange(of: text) { old, new in
          let shown = Self.shown(new, after: old)
          if shown != new { text = shown }
        }
    }
    .contentShape(Rectangle())
    .onTapGesture { focus.wrappedValue = true }
  }

  static func shown(_ typed: String, after previous: String,
                    decimalSeparator: String = Locale.current.decimalSeparator ?? ".") -> String {
    shown(AmountEntry(editing: typed, previous: previous, decimalSeparator: decimalSeparator))
  }

  private static func shown(_ entry: AmountEntry) -> String {
    entry.isEmpty ? "" : entry.display
  }

  static func text(for minor: Int64, style: MoneyStyle = .compact) -> String {
    shown(AmountEntry(typing: MoneyFormat.string(AmountEntry.clamped(minor), style: style)))
  }
}

struct RadioMark: View {
  let selected: Bool

  var body: some View {
    ZStack {
      if selected {
        Circle().fill(HColor.actionAccent)
        HIconView(.check, size: 14, color: HColor.white, strokeWidth: 3.2)
      } else {
        Circle().strokeBorder(HColor.appleGraysGray3, lineWidth: 2)
      }
    }
    .frame(width: 24, height: 24)
    .accessibilityHidden(true)
  }
}

struct SourceDisc: View {
  let source: MoveSource

  var body: some View {
    if source.id == nil {
      Circle().fill(Hue.mint.perceptualGradient).frame(width: 40, height: 40)
        .overlay { PlanGlyph(kind: .wallet, size: 20, color: Hue.mint.ink) }
        .accessibilityHidden(true)
    } else {
      CategoryDisc(hue: source.hue, glyph: source.glyph)
    }
  }
}

struct SourceRow: View {
  let source: MoveSource
  let selected: Bool
  let hidden: Bool

  var body: some View {
    HStack(spacing: HSpacing.listRowGap) {
      SourceDisc(source: source)
      VStack(alignment: .leading, spacing: 2) {
        Text(source.name).hType(.rowTitle).foregroundStyle(HColor.listRowTitle)
        PhraseText(source.detail, hidden: hidden).hType(.footnote).foregroundStyle(HColor.listRowSupporting)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      RadioMark(selected: selected)
    }
    .padding(.horizontal, HSpacing.listRowInsetInline)
    .padding(.vertical, 8)
    .frame(minHeight: 60)
    .contentShape(Rectangle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(source.name), \(source.detail.spoken(hidden: hidden))")
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

struct SourcePickerPage: View {
  let title: String
  let sources: [MoveSource]
  let selected: CategoryID?
  let hidden: Bool
  let onCard: Bool
  let pick: (CategoryID?) -> Void

  var body: some View {
    ScrollView {
      Group {
        if onCard {
          PlanListCard { rows }
        } else {
          VStack(spacing: 0) {
            Group(subviews: rows) { subviews in
              ForEach(Array(subviews.enumerated()), id: \.offset) { i, row in
                if i > 0 { HDivider(inset: .disc68) }
                row
              }
            }
          }
        }
      }
      .padding(.horizontal, onCard ? HSpacing.insetPage : 0)
      .padding(.vertical, 8)
    }
    .background(onCard ? HColor.sheetSurfaceLarge : HColor.sheetSurface)
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
  }

  @ViewBuilder private var rows: some View {
    ForEach(sources) { s in
      Button { pick(s.id) } label: { SourceRow(source: s, selected: s.id == selected, hidden: hidden) }
        .buttonStyle(HRowPressStyle())
        .accessibilityIdentifier("source.\(s.id ?? "rta")")
    }
  }
}

struct DestinationPickerPage: View {
  let destinations: [CategoryOption]
  let selected: CategoryID?
  let pick: (CategoryID) -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        ForEach([Bucket.needs, .wants, .savings], id: \.self) { bucket in
          let options = destinations.filter { $0.bucket == bucket }
          if !options.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
              PlanOverline(bucket.title)
              PlanListCard {
                ForEach(options) { o in
                  Button { pick(o.id) } label: {
                    HListRow(leading: .disc(o.hue, o.glyph.icon), title: o.name, trailing: .check(o.id == selected))
                  }
                  .buttonStyle(HRowPressStyle())
                  .accessibilityIdentifier("destination.\(o.id)")
                }
              }
            }
          }
        }
      }
      .padding(.horizontal, HSpacing.insetPage)
      .padding(.vertical, 8)
    }
    .background(HColor.sheetSurfaceLarge)
    .navigationTitle("To")
    .navigationBarTitleDisplayMode(.inline)
  }
}

struct GrowingChipRows: Layout {
  var spacing: CGFloat = 8
  var lineSpacing: CGFloat = 8

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? .infinity
    let lines = self.lines(subviews, width: width)
    let height = lines.reduce(CGFloat(0)) { sum, line in
      sum + placements(line, subviews, width: width).map(\.height).max()!
    } + lineSpacing * CGFloat(max(0, lines.count - 1))
    return CGSize(width: proposal.width ?? lines.map { lineWidth($0, subviews) }.max() ?? 0, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var y = bounds.minY
    for line in lines(subviews, width: bounds.width) {
      let sizes = placements(line, subviews, width: bounds.width)
      let height = sizes.map(\.height).max() ?? 0
      var x = bounds.minX
      for (k, i) in line.enumerated() {
        subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: sizes[k].width, height: height))
        x += sizes[k].width + spacing
      }
      y += height + lineSpacing
    }
  }

  private func placements(_ line: [Int], _ subviews: Subviews, width: CGFloat) -> [CGSize] {
    let natural = line.map { subviews[$0].sizeThatFits(.unspecified).width }
    let room = width.isFinite ? width : natural.reduce(0, +) + spacing * CGFloat(line.count - 1)
    let extra = max(0, room - natural.reduce(0, +) - spacing * CGFloat(line.count - 1)) / CGFloat(line.count)
    return line.enumerated().map { k, i in
      let w = min(natural[k] + extra, room)
      return CGSize(width: w, height: subviews[i].sizeThatFits(ProposedViewSize(width: w, height: nil)).height)
    }
  }

  private func lines(_ subviews: Subviews, width: CGFloat) -> [[Int]] {
    var out: [[Int]] = []
    var current: [Int] = []
    var used: CGFloat = 0
    for i in subviews.indices {
      let w = subviews[i].sizeThatFits(.unspecified).width
      if !current.isEmpty, used + spacing + w > width {
        out.append(current)
        current = []
        used = 0
      }
      used += (current.isEmpty ? 0 : spacing) + w
      current.append(i)
    }
    if !current.isEmpty { out.append(current) }
    return out
  }

  private func lineWidth(_ line: [Int], _ subviews: Subviews) -> CGFloat {
    line.map { subviews[$0].sizeThatFits(.unspecified).width }.reduce(0, +) + spacing * CGFloat(max(0, line.count - 1))
  }
}

struct QuickChip: View {
  let title: String
  var figure: MoneyPhrase?
  let hidden: Bool
  var titleIsFigure = false
  let action: () -> Void

  static let reach: CGFloat = (HSpacing.targetMinimum + 2 - HSpacing.chipHeight) / 2

  var body: some View {
    Button(action: action) {
      SideBySideOrStacked(spacing: 6, lineSpacing: 0, spreads: false, stackedAlignment: .center) {
        if titleIsFigure {
          Text(title).hFigure(.compact)
        } else {
          Text(title).hType(.smallButton).multilineTextAlignment(.center)
        }
        if let figure {
          Text(figure.rendered(hidden: hidden)).hFigure(HFigure.compact.weight(.semibold))
            .foregroundStyle(HColor.chipCount)
        }
      }
      .foregroundStyle(HColor.chipText)
      .padding(.horizontal, HSpacing.chipInset)
      .padding(.vertical, 4)
      .frame(maxWidth: .infinity, minHeight: HSpacing.chipHeight)
      .fixedSize(horizontal: false, vertical: true)
    }
    .buttonStyle(ChipStyle())
    .accessibilityLabel(figure.map { "\(title), \($0.spoken(hidden: hidden))" } ?? title)
  }

  private struct ChipStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
      configuration.label
        .background(HColor.chipSurfaceOnCard, in: Capsule())
        .overlay { Capsule().fill(HColor.stateLayerPressed).opacity(configuration.isPressed ? 1 : 0) }
        .hAnimation(.highlight, value: configuration.isPressed)
        .padding(.vertical, QuickChip.reach)
        .contentShape(Rectangle())
    }
  }
}

extension View {
  func discardGuard(_ isDirty: Bool, title: String, asking: Binding<Bool>, discard: @escaping () -> Void) -> some View {
    modifier(DiscardGuard(isDirty: isDirty, title: title, asking: asking, discard: discard))
  }
}

struct DiscardGuard: ViewModifier {
  let isDirty: Bool
  let title: String
  @Binding var asking: Bool
  let discard: () -> Void

  func body(content: Content) -> some View {
    content
      .interactiveDismissDisabled(isDirty)
      .background {
        DismissAttempt(enabled: isDirty) { asking = true }.frame(width: 0, height: 0)
      }
      .confirmationDialog(title, isPresented: $asking, titleVisibility: .visible) {
        Button("Discard", role: .destructive, action: discard)
          .accessibilityIdentifier("discard.confirm")
        Button("Keep editing", role: .cancel) {}
          .accessibilityIdentifier("discard.keep")
      }
  }

  static func close(isDirty: Bool, asking: Binding<Bool>, dismiss: () -> Void) {
    if isDirty { asking.wrappedValue = true } else { dismiss() }
  }
}

struct DismissAttempt: UIViewControllerRepresentable {
  let enabled: Bool
  let attempted: () -> Void

  func makeUIViewController(context: Context) -> Controller { Controller() }

  func updateUIViewController(_ controller: Controller, context: Context) {
    controller.proxy.attempted = attempted
    controller.setEnabled(enabled)
  }

  static func dismantleUIViewController(_ controller: Controller, coordinator: Coordinator) {
    controller.setEnabled(false)
  }

  final class Controller: UIViewController {
    let proxy = Proxy()
    private weak var held: UIPresentationController?

    override func viewDidAppear(_ animated: Bool) {
      super.viewDidAppear(animated)
      setEnabled(proxy.enabled)
    }

    func setEnabled(_ enabled: Bool, on presentation: UIPresentationController? = nil) {
      proxy.enabled = enabled
      if !enabled {
        release()
      } else if let pc = presentation ?? sheetPresentation, pc.delegate !== proxy {
        proxy.original = pc.delegate
        pc.delegate = proxy
        held = pc
      }
    }

    private func release() {
      if let held, held.delegate === proxy { held.delegate = proxy.original }
      held = nil
      proxy.original = nil
    }

    private var sheetPresentation: UIPresentationController? {
      var vc: UIViewController? = self
      while let current = vc {
        if current.presentingViewController != nil, let pc = current.presentationController { return pc }
        vc = current.parent
      }
      return nil
    }
  }

  final class Proxy: NSObject, UIAdaptivePresentationControllerDelegate {
    nonisolated(unsafe) weak var original: UIAdaptivePresentationControllerDelegate?
    var enabled = false
    var attempted: () -> Void = {}

    func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
      if enabled { attempted() }
      original?.presentationControllerDidAttemptToDismiss?(presentationController)
    }

    nonisolated override func responds(to aSelector: Selector!) -> Bool {
      super.responds(to: aSelector) || original?.responds(to: aSelector) == true
    }

    nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
      original?.responds(to: aSelector) == true ? original : nil
    }
  }
}
