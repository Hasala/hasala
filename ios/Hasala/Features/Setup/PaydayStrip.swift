import HasalaDesign
import HasalaModels
import SwiftUI

struct PaydayPicker: View {
  @Binding var choice: PaydayChoice
  let next: LocalDate
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    VStack(spacing: 10) {
      let layout = typeSize.isAccessibilitySize
        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
        : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
      layout {
        label
        if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
        nextLine
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, HSpacing.insetPage)
      PaydayStrip(choice: $choice)
    }
  }

  private var label: some View {
    Text("Payday").hType(.subheadline.weight(.semibold)).foregroundStyle(HColor.textPrimary)
  }

  private var nextLine: some View {
    Text("Next one \(next.weekdayShort), \(next.dayMonth)")
      .hType(.footnote.weight(.medium))
      .foregroundStyle(HColor.textSecondary)
  }
}

struct PaydayStrip: View {
  @Binding var choice: PaydayChoice

  @State private var dragCentre: Double?
  @State private var dragStart: Double = 0
  @StageMotion private var motion: MotionPolicy
  @ScaledMetric(relativeTo: .title3) private var scale: CGFloat = 1

  private var pitch: CGFloat { 56 * scale }
  private var grow: CGFloat { 8 * scale }

  private var centre: Double { dragCentre ?? Double(choice.index) }

  var body: some View {
    GeometryReader { geo in
      ZStack {
        ForEach(PaydayChoice.all, id: \.self) { day in
          tile(day, width: geo.size.width)
        }
      }
      .frame(width: geo.size.width, height: geo.size.height)
      .contentShape(Rectangle())
      .gesture(drag)
    }
    .frame(height: 64 * scale)
    .hHaptic(.selection, trigger: choice)
  }

  @ViewBuilder private func tile(_ day: PaydayChoice, width: CGFloat) -> some View {
    let offset = Double(day.index) - centre
    let distance = abs(offset)
    let lift = CGFloat(max(0, 1 - distance))
    let side: CGFloat = offset < 0 ? -1 : 1
    let push = CGFloat(min(1, distance)) * (grow / 2 + (day == .lastWorkingDay ? 4 * scale : 0)) * side
    let x = CGFloat(offset) * pitch + push
    if abs(x) < width / 2 + pitch {
      PaydayTile(day: day, selected: day == choice, lift: lift, distance: distance, scale: scale)
        .offset(x: x)
        .opacity(distance >= 4 ? 0.5 : distance >= 3 ? 0.75 : 1)
        .onTapGesture { settle(on: day.index) }
        .accessibilityHidden(distance > 3.5)
        .modifier(PaydayAccessibility(day: day, chosen: day == choice, pick: { settle(on: day.index) }) { step($0) })
    }
  }

  private var drag: some Gesture {
    DragGesture(minimumDistance: 4)
      .onChanged { value in
        if dragCentre == nil { dragStart = Double(choice.index) }
        let moved = dragStart - Double(value.translation.width / pitch)
        let clamped = min(Double(PaydayChoice.all.count - 1), max(0, moved))
        dragCentre = clamped
        let nearest = PaydayChoice.all[Int(clamped.rounded())]
        if nearest != choice { choice = nearest }
      }
      .onEnded { value in
        let projected = dragStart - Double(value.predictedEndTranslation.width / pitch)
        settle(on: Int(min(Double(PaydayChoice.all.count - 1), max(0, projected)).rounded()))
      }
  }

  private func settle(on index: Int) {
    withHMotion(.thumbSlide, motion) {
      choice = PaydayChoice.all[index]
      dragCentre = nil
    }
  }

  private func step(_ by: Int) {
    let index = min(PaydayChoice.all.count - 1, max(0, choice.index + by))
    settle(on: index)
  }
}

private struct PaydayTile: View {
  let day: PaydayChoice
  let selected: Bool
  let lift: CGFloat
  let distance: Double
  let scale: CGFloat

  var body: some View {
    let width = ((day == .lastWorkingDay ? 56 : 48) + (day == .lastWorkingDay ? 0 : 8 * lift)) * scale
    let height = (56 + 8 * lift) * scale
    RoundedRectangle(cornerRadius: (16 + 2 * lift) * scale, style: .continuous)
      .fill(selected ? HColor.actionAccent : HColor.surfacePrimary)
      .shadow(color: selected ? HColor.actionAccent.opacity(0.35) : .clear, radius: 8, x: 0, y: 6)
      .frame(width: width, height: height)
      .overlay { label }
  }

  private static let numeral = HFigure(size: 20, leading: 24, weight: .semibold, textStyle: .title3)
  private static let chosenNumeral = HFigure(size: 24, leading: 28, weight: .bold, textStyle: .title3)
  private static let suffix = HType(size: 11, leading: 14, weight: .semibold, textStyle: .caption2)
  private static let last = HType(size: 13, leading: 16, weight: .semibold, textStyle: .footnote)
  private static let workDay = HType(size: 11, leading: 14, weight: .medium, textStyle: .caption2)

  @ViewBuilder private var label: some View {
    switch day {
    case .day(let d):
      if selected {
        VStack(spacing: 0) {
          Text(verbatim: "\(d)").hFigure(Self.chosenNumeral).foregroundStyle(HColor.white)
          OrdinalMark(text: PaydayChoice.suffix(d), type: Self.suffix)
        }
      } else {
        Text(verbatim: "\(d)")
          .hFigure(Self.numeral)
          .foregroundStyle(distance < 1.5 ? HColor.textPrimary : HColor.textSecondary)
      }
    case .lastWorkingDay:
      VStack(spacing: 0) {
        Text("Last").hType(Self.last)
        Text("work day").hType(Self.workDay)
      }
      .lineLimit(1)
      .minimumScaleFactor(0.5)
      .padding(.horizontal, 2)
      .foregroundStyle(selected ? HColor.white : HColor.textSecondary)
    }
  }
}

private struct OrdinalMark: View {
  let text: String
  let type: HType
  @ScaledMetric private var line: CGFloat

  init(text: String, type: HType) {
    self.text = text
    self.type = type
    _line = ScaledMetric(wrappedValue: type.leading, relativeTo: type.textStyle)
  }

  var body: some View {
    let mark = Text(verbatim: text).font(type.font).foregroundStyle(HColor.white.opacity(0.8))
    Canvas { context, size in
      context.draw(context.resolve(mark), at: CGPoint(x: size.width / 2, y: size.height / 2))
    }
    .frame(height: line)
    .accessibilityHidden(true)
  }
}

private struct PaydayAccessibility: ViewModifier {
  let day: PaydayChoice
  let chosen: Bool
  var pick: () -> Void
  var step: (Int) -> Void

  func body(content: Content) -> some View {
    content
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(chosen ? "Payday, \(day.spoken)" : day.spoken)
      .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
      .accessibilityAction(.default, pick)
      .accessibilityAdjustableAction { direction in
        switch direction {
        case .increment: step(1)
        case .decrement: step(-1)
        @unknown default: break
        }
      }
      .accessibilityIdentifier(day.identifier)
  }
}
