import Accessibility
import HasalaDesign
import HasalaModels
import SwiftUI

struct DayByDayChart: View {
  let chart: DayByDay
  let name: String
  let hue: Hue
  var bucket: Bucket?
  let hidden: Bool

  @Environment(\.dynamicTypeSize) private var typeSize
  @ScaledMetric(relativeTo: .caption) private var labelLine: CGFloat = 16
  @ScaledMetric(relativeTo: .caption) private var labelSize: CGFloat = 12
  @ScaledMetric(relativeTo: .caption) private var dayLabelWidth: CGFloat = 15
  @ScaledMetric(relativeTo: .caption) private var dayLabelHeight: CGFloat = 16

  private let tallest: CGFloat = 108

  private var keyed: Bool { typeSize.isAccessibilitySize }
  private var headroom: CGFloat { keyed ? 8 : labelLine + 7 }
  private var plotHeight: CGFloat { headroom + tallest }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if keyed { key.padding(.bottom, 6) }
      GeometryReader { geo in
        plot(width: geo.size.width)
      }
      .frame(height: plotHeight + 1)
      GeometryReader { geo in
        dayLabels(width: geo.size.width)
      }
      .frame(height: dayLabelHeight)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Day by day, \(chart.range)")
    .accessibilityValue(summary)
    .accessibilityChartDescriptor(DayByDayDescriptor(chart: chart, name: name, hidden: hidden))
    .accessibilityIdentifier("plan.chart")
  }

  private func plot(width: CGFloat) -> some View {
    let slot = width / CGFloat(max(1, chart.days.count))
    let bar = min(12, slot * 0.6)
    let top = CGFloat(max(1, chart.scaleTop.minor))
    let lineY = plotHeight - CGFloat(chart.dailyBudget.minor) / top * tallest
    let peak = chart.peak.flatMap { p in chart.days.firstIndex { $0.day == p.day }.map { (p, $0) } }
    return ZStack(alignment: .topLeading) {
      Rectangle().fill(HColor.borderSubtle).frame(width: width, height: 1).offset(y: plotHeight)
      HStack(alignment: .bottom, spacing: 0) {
        ForEach(chart.days) { day in
          dayBar(day, width: bar, height: CGFloat(day.spent.minor) / top * tallest)
            .frame(width: slot, alignment: .center)
        }
      }
      .frame(width: width, height: plotHeight, alignment: .bottomLeading)
      if chart.dailyBudget.minor > 0 {
        Path { p in
          p.move(to: CGPoint(x: 0, y: 1))
          p.addLine(to: CGPoint(x: width, y: 1))
        }
        .stroke(HColor.neutral400, style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
        .frame(width: width, height: 2)
        .offset(y: lineY - 1)
      }
      if !keyed {
        DayByDayPlotLabels(
          hasPeak: peak != nil,
          peakCentre: peak.map { slot * (CGFloat($0.1) + 0.5) } ?? 0,
          peakTop: peak.map { plotHeight - CGFloat($0.0.total.minor) / top * tallest } ?? 0,
          lineY: chart.dailyBudget.minor > 0 ? lineY : nil,
          bars: barFrames(slot: slot, bar: bar, top: top)
        ) {
          if let peak { PeakLabel(peak: peak.0, hidden: hidden, wraps: false) }
          if chart.dailyBudget.minor > 0 { DailyBudgetLabel(amount: chart.dailyBudget, hidden: hidden, wraps: false) }
        }
        .frame(width: width, height: plotHeight)
      }
    }
    .frame(width: width, height: plotHeight + 1, alignment: .topLeading)
  }

  private func barFrames(slot: CGFloat, bar: CGFloat, top: CGFloat) -> [CGRect] {
    chart.days.enumerated().compactMap { i, day in
      guard day.spent.minor > 0 else { return nil }
      let height = max(4, CGFloat(day.spent.minor) / top * tallest)
      return CGRect(x: slot * (CGFloat(i) + 0.5) - bar / 2, y: plotHeight - height, width: bar, height: height)
    }
  }

  @ViewBuilder private func dayBar(_ day: DaySpend, width: CGFloat, height: CGFloat) -> some View {
    if day.spent.minor > 0 {
      BarShape()
        .fill(barColour(day.day))
        .frame(width: width, height: max(4, height))
    } else {
      RoundedRectangle(cornerRadius: 1.5).fill(HColor.paceTrack).frame(width: width, height: 3)
    }
  }

  private func barColour(_ day: Int) -> Color {
    day == chart.today ? hue.ink : (bucket?.splitColor ?? Color(hue.dotDeep))
  }

  private var key: some View {
    let cap = labelSize * 0.73
    let slot = cap * 1.2
    return VStack(alignment: .leading, spacing: 8) {
      if let peak = chart.peak {
        keyLine(PeakLabel(peak: peak, hidden: hidden, wraps: true), slot: slot) {
          BarShape().fill(barColour(peak.day)).frame(width: max(12, cap * 0.6), height: cap)
        }
      }
      if chart.dailyBudget.minor > 0 {
        keyLine(DailyBudgetLabel(amount: chart.dailyBudget, hidden: hidden, wraps: true), slot: slot) {
          Path { p in
            p.move(to: CGPoint(x: 0, y: 1))
            p.addLine(to: CGPoint(x: slot, y: 1))
          }
          .stroke(HColor.neutral400, style: StrokeStyle(lineWidth: 2, dash: [cap / 4, cap / 4]))
          .frame(width: slot, height: 2)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func keyLine<Words: View, Mark: View>(
    _ words: Words, slot: CGFloat, @ViewBuilder mark: () -> Mark
  ) -> some View {
    let halfCap = labelSize * 0.365
    return HStack(alignment: .firstTextBaseline, spacing: 8) {
      mark()
        .frame(width: slot)
        .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + halfCap }
      words
    }
  }

  private func dayLabels(width: CGFloat) -> some View {
    let days = chart.days.map(\.day)
    let slot = width / CGFloat(max(1, days.count))
    let shown = Self.labelledDays(days, today: chart.today, slot: slot, labelWidth: dayLabelWidth)
    return HStack(spacing: 0) {
      ForEach(Array(chart.days.enumerated()), id: \.element.id) { i, day in
        let today = day.day == chart.today
        let centre = Self.labelCentre(i, day: day.day, count: days.count, slot: slot, labelWidth: dayLabelWidth)
        Text(shown.contains(day.day) ? "\(day.day)" : "")
          .font(.system(.caption, design: .rounded, weight: today ? .bold : .medium))
          .foregroundStyle(today ? HColor.textPrimary : HColor.textSecondary)
          .fixedSize()
          .frame(width: slot)
          .offset(x: centre - slot * (CGFloat(i) + 0.5))
      }
    }
  }

  static func labelledDays(_ days: [Int], today: Int, slot: CGFloat, labelWidth: CGFloat) -> Set<Int> {
    func width(_ day: Int) -> CGFloat { day < 10 ? labelWidth / 2 : labelWidth }
    let gap = labelWidth * 0.4
    let candidates = days.count <= 10 ? days : days.filter { $0 == 1 || $0 % 5 == 0 }
    var shown: [(day: Int, centre: CGFloat)] = []
    for day in [today] + candidates {
      guard let i = days.firstIndex(of: day), !shown.contains(where: { $0.day == day }) else { continue }
      let centre = labelCentre(i, day: day, count: days.count, slot: slot, labelWidth: labelWidth)
      if shown.allSatisfy({ abs($0.centre - centre) >= (width($0.day) + width(day)) / 2 + gap }) {
        shown.append((day, centre))
      }
    }
    return Set(shown.map(\.day))
  }

  static func labelCentre(_ index: Int, day: Int, count: Int, slot: CGFloat, labelWidth: CGFloat) -> CGFloat {
    let half = (day < 10 ? labelWidth / 2 : labelWidth) / 2
    let end = slot * CGFloat(count)
    return min(max(half, slot * (CGFloat(index) + 0.5)), max(half, end - half))
  }

  private var summary: String {
    var parts: [String] = []
    if let peak = chart.peak, let day = chart.days.first(where: { $0.day == peak.day }) {
      parts.append("Largest day \(day.date.short), \(peak.label), \(spoken(peak.total))")
    } else {
      parts.append("Nothing spent yet")
    }
    if chart.dailyBudget.minor > 0 { parts.append("Daily budget \(spoken(chart.dailyBudget))") }
    return parts.joined(separator: ". ") + "."
  }

  private func spoken(_ m: Money) -> String {
    hidden ? "Amount hidden" : "AED \(MoneyFormat.string(m.minor))"
  }
}

nonisolated private struct BarShape: Shape {
  func path(in rect: CGRect) -> Path {
    UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 2, bottomTrailingRadius: 2,
                           topTrailingRadius: 4, style: .continuous)
      .path(in: rect)
  }
}

struct DayByDayPlotLabels: Layout {
  let hasPeak: Bool
  let peakCentre: CGFloat
  let peakTop: CGFloat
  let lineY: CGFloat?
  var bars: [CGRect] = []

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    proposal.replacingUnspecifiedDimensions()
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var rest = subviews[...]
    let peak = hasPeak ? rest.popFirst() : nil
    let budget = lineY == nil ? nil : rest.popFirst()
    let frames = frames(
      peak: peak?.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)),
      budget: budget?.sizeThatFits(.unspecified), width: bounds.width)
    for (view, frame) in [(peak, frames.peak), (budget, frames.budget)] {
      guard let view, let frame else { continue }
      view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                 proposal: ProposedViewSize(frame.size))
    }
  }

  func frames(peak: CGSize?, budget: CGSize?, width: CGFloat) -> (peak: CGRect?, budget: CGRect?) {
    let peakFrame = peak.map { size in
      let w = min(size.width, width)
      return CGRect(x: min(max(0, peakCentre - w / 2), width - w), y: max(0, peakTop - size.height - 5),
                    width: w, height: size.height)
    }
    let budgetFrame = budget.flatMap { size in
      lineY.map { lineY in
        let above = CGRect(x: 0, y: lineY - size.height - 4, width: size.width, height: size.height)
        let under = CGRect(x: 0, y: lineY + 4, width: size.width, height: size.height)
        if above.minY < 0 || peakFrame?.intersects(above) == true { return under }
        return crossesABar(above) && !crossesABar(under) ? under : above
      }
    }
    return (peakFrame, budgetFrame)
  }

  private func crossesABar(_ frame: CGRect) -> Bool {
    bars.contains { $0.intersects(frame.insetBy(dx: -2, dy: -2)) }
  }
}

private struct PeakLabel: View {
  let peak: DayByDay.Peak
  let hidden: Bool
  let wraps: Bool

  var body: some View {
    Group {
      if wraps {
        Text("\(name) \(figure)").fixedSize(horizontal: false, vertical: true)
      } else {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
          name.lineLimit(1)
          figure.fixedSize().layoutPriority(1)
        }
      }
    }
    .foregroundStyle(HColor.textPrimary)
  }

  private var name: Text { Text("\(peak.label) ·").font(HType.caption1.weight(.semibold).font) }

  private var figure: Text {
    Text(hidden ? MoneyFormat.hidden(count: 3) : MoneyFormat.string(peak.total.minor))
      .font(.system(.caption, design: .rounded, weight: .bold))
  }
}

private struct DailyBudgetLabel: View {
  let amount: Money
  let hidden: Bool
  let wraps: Bool

  var body: some View {
    Group {
      if wraps {
        Text("\(words) \(figure)").fixedSize(horizontal: false, vertical: true)
      } else {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
          words
          figure
        }
        .fixedSize()
        .background {
          RoundedRectangle(cornerRadius: 4, style: .continuous).fill(HColor.surfacePrimary).padding(-3)
        }
      }
    }
    .foregroundStyle(HColor.textSecondary)
  }

  private var words: Text { Text("Daily budget").font(HType.caption1.weight(.regular).font) }

  private var figure: Text {
    Text(hidden ? MoneyFormat.hidden(count: 3) : MoneyFormat.string(amount.minor))
      .font(.system(.caption, design: .rounded, weight: .semibold))
  }
}

struct DayByDayDescriptor: AXChartDescriptorRepresentable {
  let chart: DayByDay
  let name: String
  let hidden: Bool

  func makeChartDescriptor() -> AXChartDescriptor {
    let top = max(1, chart.scaleTop.minor)
    let days = AXCategoricalDataAxisDescriptor(title: "Day", categoryOrder: chart.days.map { "\($0.day)" })
    let height = AXNumericDataAxisDescriptor(title: "Share of the tallest day", range: 0...100, gridlinePositions: []) {
      "\(Int($0)) percent"
    }
    let points = chart.days.map { day in
      AXDataPoint(
        x: "\(day.day)", y: Double(Fils.mulDiv(day.spent.minor, 100, top)),
        label: "\(day.date.short), " + (hidden ? "Amount hidden" : "AED \(MoneyFormat.string(day.spent.minor))"))
    }
    return AXChartDescriptor(
      title: "Day by day, \(chart.range)", summary: chart.caption, xAxis: days, yAxis: height,
      additionalAxes: [], series: [AXDataSeriesDescriptor(name: name, isContinuous: false, dataPoints: points)])
  }
}
