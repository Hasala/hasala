import HasalaDesign
import HasalaModels
import SwiftUI

struct PlanMenuItem: Identifiable {
  let title: String
  let action: () -> Void
  var id: String { title }
}

struct PlanDetailScreen<Content: View>: View {
  let app: AppModel
  let title: String
  let wash: HWash
  var more: [PlanMenuItem] = []
  var hostsToast = true
  @ViewBuilder let content: () -> Content
  @Environment(\.inProfileSheet) private var inProfileSheet

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: HSpacing.gapScreenSection) {
        content()
      }
      .padding(.top, 20)
      .padding(.bottom, HSpacing.scrollContentBottom)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .washBehind(wash)
    .scrollEdgeEffectStyle(.soft, for: .bottom)
    .background(HColor.surfaceSecondary)
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
    .modifier(MoreMenu(items: more))
    .overlay(alignment: .bottom) {
      if hostsToast && !inProfileSheet { ToastHost(app: app) }
    }
  }
}

private struct MoreMenu: ViewModifier {
  let items: [PlanMenuItem]

  func body(content: Content) -> some View {
    if items.isEmpty {
      content
    } else {
      content.toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Menu {
            ForEach(items) { item in Button(item.title, action: item.action) }
          } label: {
            HIconView(.more, size: HSpacing.iconGlass, color: HColor.iconGlass)
          }
          .accessibilityLabel("More")
          .accessibilityIdentifier("plan.more")
        }
      }
    }
  }
}

struct SideBySideOrStacked: Layout {
  var spacing: CGFloat = 6
  var lineSpacing: CGFloat = 2
  var spreads = true
  var stackedAlignment: HorizontalAlignment = .leading

  private func sideBySide(_ subviews: Subviews, width: CGFloat?) -> Bool {
    let natural = subviews.map { $0.sizeThatFits(.unspecified).width }.reduce(0, +)
      + spacing * CGFloat(max(0, subviews.count - 1))
    return natural <= (width ?? .infinity)
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    if sideBySide(subviews, width: proposal.width) {
      let dims = subviews.map { $0.dimensions(in: .unspecified) }
      let ascent = dims.map { $0[VerticalAlignment.firstTextBaseline] }.max() ?? 0
      let descent = dims.map { $0.height - $0[VerticalAlignment.firstTextBaseline] }.max() ?? 0
      let natural = dims.map(\.width).reduce(0, +) + spacing * CGFloat(max(0, dims.count - 1))
      return CGSize(width: spreads ? (proposal.width ?? natural) : natural, height: ascent + descent)
    }
    let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) }
    let height = sizes.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, sizes.count - 1))
    return CGSize(width: proposal.width ?? sizes.map(\.width).max() ?? 0, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    if sideBySide(subviews, width: bounds.width) {
      let dims = subviews.map { $0.dimensions(in: .unspecified) }
      let ascent = dims.map { $0[VerticalAlignment.firstTextBaseline] }.max() ?? 0
      let natural = dims.map(\.width).reduce(0, +) + spacing * CGFloat(max(0, dims.count - 1))
      let gap = spreads && dims.count > 1
        ? spacing + max(0, bounds.width - natural) / CGFloat(dims.count - 1) : spacing
      var x = spreads ? bounds.minX : bounds.minX + max(0, bounds.width - natural) / 2
      for (i, d) in dims.enumerated() {
        let y = bounds.minY + ascent - d[VerticalAlignment.firstTextBaseline]
        subviews[i].place(at: CGPoint(x: x, y: y), proposal: .unspecified)
        x += d.width + gap
      }
      return
    }
    var y = bounds.minY
    for subview in subviews {
      let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
      let x: CGFloat = switch stackedAlignment {
      case .center: bounds.minX + (bounds.width - size.width) / 2
      case .trailing: bounds.maxX - size.width
      default: bounds.minX
      }
      subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: bounds.width, height: nil))
      y += size.height + lineSpacing
    }
  }
}

struct PlanOverline: View {
  let title: String

  init(_ title: String) { self.title = title }

  var body: some View {
    Text(title).hType(.overline).foregroundStyle(HColor.textSecondary)
      .padding(.leading, 4)
      .accessibilityAddTraits(.isHeader)
  }
}

extension Bucket {
  var splitColor: Color {
    switch self {
    case .needs: HColor.chartNeeds
    case .wants: HColor.chartWants
    case .savings: HColor.chartSavings
    case .income, .project, .other: Color(hue.dotDeep)
    }
  }

  var chartPattern: ChartPattern {
    switch self {
    case .wants: .dots
    case .savings: .hatch
    case .needs, .income, .project, .other: .solid
    }
  }
}

enum ChartPattern {
  case solid, dots, hatch
}

struct ChartPatternFill: View {
  let pattern: ChartPattern

  var body: some View {
    Canvas { context, size in
      let ink = GraphicsContext.Shading.color(.white.opacity(0.7))
      switch pattern {
      case .solid:
        break
      case .dots:
        var y: CGFloat = 2
        while y < size.height {
          var x: CGFloat = 2
          while x < size.width {
            context.fill(Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)), with: ink)
            x += 4
          }
          y += 4
        }
      case .hatch:
        var path = Path()
        var x = -size.height
        while x < size.width {
          path.move(to: CGPoint(x: x, y: size.height))
          path.addLine(to: CGPoint(x: x + size.height, y: 0))
          x += 4
        }
        context.stroke(path, with: ink, lineWidth: 1.2)
      }
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

struct PlanGlyph: View {
  enum Kind {
    case wallet
    case arrowRight
  }

  let kind: Kind
  let size: CGFloat
  let color: Color
  var stroke: CGFloat = 1.9

  private var lines: [(d: String, width: CGFloat)] {
    switch kind {
    case .wallet:
      [("M4 8V7a2.5 2.5 0 0 1 2.5-2.5H16", stroke),
       ("M6 7.5H18A2.5 2.5 0 0 1 20.5 10V17A2.5 2.5 0 0 1 18 19.5H6A2.5 2.5 0 0 1 3.5 17V10A2.5 2.5 0 0 1 6 7.5Z",
        stroke),
       ("M15.5 13.5h1.5", stroke + 0.4)]
    case .arrowRight:
      [("M4.5 12h14M13 6.5l5.5 5.5-5.5 5.5", stroke)]
    }
  }

  var body: some View {
    Canvas { context, canvas in
      let box = CGRect(origin: .zero, size: canvas)
      let unit = min(canvas.width, canvas.height) / 24
      for line in lines {
        guard let svg = try? SVGPath(parsing: line.d) else { continue }
        context.stroke(svg.path(in: box), with: .color(color),
                       style: StrokeStyle(lineWidth: line.width * unit, lineCap: .round, lineJoin: .round))
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

struct PlanFactsLine: View {
  let parts: [PlanDetailPart]
  let hidden: Bool
  @Environment(\.dynamicTypeSize) private var typeSize

  private enum Run {
    case words(String)
    case status(String, StatusTone)
  }

  private var runs: [Run] { Self.runs(parts, hidden: hidden) }

  private static func hasMoney(_ part: PlanDetailPart) -> Bool {
    switch part {
    case .status: true
    case .text(let p):
      p.parts.contains {
        if case .text = $0 { return false }
        return true
      }
    }
  }

  private static func runs(_ parts: [PlanDetailPart], hidden: Bool) -> [Run] {
    var out: [Run] = []
    for part in parts {
      switch part {
      case .text(let p):
        let s = p.rendered(hidden: hidden)
        if case .words(let previous)? = out.last {
          out[out.count - 1] = .words(previous + " · " + s)
        } else {
          out.append(.words(s))
        }
      case .status(let words, let tone):
        out.append(.status(words, tone))
      }
    }
    return out
  }

  var body: some View {
    Group {
      if typeSize.isAccessibilitySize {
        wrapped.fixedSize(horizontal: false, vertical: true)
      } else {
        line
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(spoken)
  }

  private var line: some View {
    let kept = parts.filter(Self.hasMoney)
    let drops = !kept.isEmpty && kept.count < parts.count
    return ViewThatFits(in: .horizontal) {
      line(runs, squeeze: false)
      if drops { line(Self.runs(kept, hidden: hidden), squeeze: false) }
      line(drops ? Self.runs(kept, hidden: hidden) : runs, squeeze: true)
    }
  }

  private func line(_ runs: [Run], squeeze: Bool) -> some View {
    HStack(spacing: 6) {
      ForEach(Array(runs.enumerated()), id: \.offset) { i, run in
        switch run {
        case .words(let s):
          let lead = i > 0 ? "· " : ""
          let tail = i + 1 < runs.count ? " ·" : ""
          Text(verbatim: lead + s + tail).hType(.footnote).foregroundStyle(HColor.textSecondary)
            .layoutPriority(squeeze ? 1 : 0)
        case .status(let words, let tone):
          HStack(spacing: 6) {
            Circle().fill(Self.dot(tone)).frame(width: 7, height: 7)
            Text(words).hType(.footnote.weight(.semibold)).foregroundStyle(Self.words(tone))
          }
          .layoutPriority(squeeze ? 2 : 0)
        }
      }
    }
    .lineLimit(1)
  }

  private var wrapped: Text {
    var out = Text(verbatim: "")
    for (i, run) in runs.enumerated() {
      if i > 0 { out = Text("\(out)\(Text(verbatim: " · ").foregroundStyle(HColor.textSecondary))") }
      switch run {
      case .words(let s):
        out = Text("\(out)\(Text(verbatim: s).foregroundStyle(HColor.textSecondary))")
      case .status(let words, let tone):
        let dot = Text(verbatim: "● ").foregroundStyle(Self.dot(tone))
        let w = Text(verbatim: words).font(HType.footnote.weight(.semibold).font).foregroundStyle(Self.words(tone))
        out = Text("\(out)\(dot)\(w)")
      }
    }
    return out.font(HType.footnote.font)
  }

  private var spoken: String { BillDetailParts.spoken(parts, hidden: hidden) }

  static func dot(_ tone: StatusTone) -> Color {
    switch tone {
    case .warning: HColor.paceFillOverPace
    case .error: HColor.paceOverBudget
    case .success: HColor.paceOnTrack
    case .accent: HColor.actionAccent
    }
  }

  static func words(_ tone: StatusTone) -> Color {
    switch tone {
    case .warning: HColor.paceOverPace
    case .error: HColor.paceOverBudget
    case .success: HColor.paceOnTrack
    case .accent: HColor.actionAccent
    }
  }
}

struct DoneMark: View {
  let words: String

  init(_ words: String) { self.words = words }

  var body: some View {
    HStack(spacing: 4) {
      HIconView(.check, size: 14, color: HColor.statusSuccessForeground, strokeWidth: 3)
      Text(words).hType(.subheadline.weight(.semibold)).foregroundStyle(HColor.statusSuccessForeground)
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isStaticText)
  }
}

struct PlanListCard<Content: View>: View {
  var inset: HDivider.Inset = .disc68
  @ViewBuilder let content: Content

  var body: some View {
    HListCard {
      Group(subviews: content) { rows in
        ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
          if i > 0 { HDivider(inset: inset) }
          row
        }
      }
    }
  }
}
