import HasalaModels
import SwiftUI

public struct FilterChip: View {
  public enum CountStyle: Sendable { case plain, accent }

  let title: String
  let count: Int?
  let countStyle: CountStyle
  let selected: Bool
  let onCard: Bool
  let action: () -> Void

  public init(_ title: String, count: Int? = nil, countStyle: CountStyle = .accent, selected: Bool,
              onCard: Bool = false, action: @escaping () -> Void)
  {
    self.title = title
    self.count = count
    self.countStyle = countStyle
    self.selected = selected
    self.onCard = onCard
    self.action = action
  }

  public var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        Text(title).hType(.smallButton)
        if let count {
          switch countStyle {
          case .accent: CountBadge(count, style: .chip20)
          case .plain:
            Text("\(count)").hFigure(HFigure.badge.weight(.semibold))
              .foregroundStyle(selected ? HColor.widgetOnInverseSecondary : HColor.chipCount)
          }
        }
      }
      .foregroundStyle(selected ? HColor.chipTextSelected : HColor.chipText)
      .padding(.horizontal, HSpacing.chipInset)
      .frame(minHeight: HSpacing.chipHeight)
      .background(ChipPressStyle.surface(selected: selected, onCard: onCard), in: Capsule())
      .hContrastEdge(Capsule(), active: !selected)
    }
    .buttonStyle(ChipPressStyle())
    .accessibilityLabel(count.map { "\(title), \($0)" } ?? title)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

public struct ChoiceChip: View {
  let title: String
  let dot: Hue?
  let selected: Bool
  let onCard: Bool
  let action: () -> Void

  public init(_ title: String, dot: Hue? = nil, selected: Bool, onCard: Bool = false,
              action: @escaping () -> Void)
  {
    self.title = title
    self.dot = dot
    self.selected = selected
    self.onCard = onCard
    self.action = action
  }

  public var body: some View {
    Button(action: action) {
      HStack(spacing: 7) {
        if let dot {
          Circle().fill(dot.dotGradient).frame(width: onCard ? 10 : 8, height: onCard ? 10 : 8)
        }
        Text(title).hType(.smallButton)
      }
      .foregroundStyle(selected ? HColor.chipTextSelected : HColor.chipText)
      .padding(.leading, dot == nil ? HSpacing.chipInset : (onCard ? 14 : 12))
      .padding(.trailing, dot == nil ? HSpacing.chipInset : (onCard ? 16 : 13))
      .frame(minHeight: HSpacing.chipHeight)
      .background(ChipPressStyle.surface(selected: selected, onCard: onCard), in: Capsule())
      .hContrastEdge(Capsule(), active: !selected)
    }
    .buttonStyle(ChipPressStyle())
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

struct ChipPressStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .overlay { if configuration.isPressed { Capsule().fill(HColor.stateLayerPressed) } }
      .contentShape(Capsule().inset(by: -2))
      .animation(.easeOut(duration: HMotion.highlight), value: configuration.isPressed)
  }

  static func surface(selected: Bool, onCard: Bool) -> Color {
    selected ? HColor.chipSurfaceSelected : (onCard ? HColor.chipSurfaceOnCard : HColor.chipSurface)
  }
}

public struct InfoChip: View {
  public enum Style: Sendable {
    case evidence
    case reason
    case rawText
    case suggested
  }

  let text: String
  let style: Style

  public init(_ text: String, style: Style = .evidence) {
    self.text = text
    self.style = style
  }

  public var body: some View {
    HStack(spacing: 6) {
      if style == .reason {
        Circle().fill(HColor.actionAccent).frame(width: 7, height: 7)
      }
      Text(text)
        .hType(style == .rawText ? .footnote.weight(.medium) : .footnote.weight(.semibold))
        .tracking(style == .rawText ? 0.02 * HFontSize.footnote : 0)
        .fixedSize(horizontal: false, vertical: true)
    }
    .foregroundStyle(foreground)
    .padding(.leading, leading)
    .padding(.trailing, style == .reason ? 12 : leading)
    .frame(minHeight: height)
    .background(background, in: shape)
    .hContrastEdge(shape)
    .accessibilityElement(children: .combine)
  }

  private var leading: CGFloat {
    switch style {
    case .evidence, .reason: 10
    case .rawText: 8
    case .suggested: 9
    }
  }

  private var height: CGFloat {
    switch style {
    case .evidence, .reason: HSpacing.chipInfoHeight
    case .rawText: 26
    case .suggested: 24
    }
  }

  private var foreground: Color {
    switch style {
    case .evidence: HColor.chipInfoText
    case .rawText: HColor.textSecondary
    case .reason, .suggested: HColor.statusInfoForeground
    }
  }

  private var background: Color {
    switch style {
    case .evidence: HColor.chipInfoSurface
    case .rawText: HColor.surfaceSecondary
    case .reason, .suggested: HColor.statusInfoSurface
    }
  }

  private var shape: AnyShape {
    style == .rawText
      ? AnyShape(RoundedRectangle(cornerRadius: HRadius.small, style: .continuous))
      : AnyShape(Capsule())
  }
}

public struct StatusPillView: View {
  public enum Surface: Sendable { case white, tinted }

  public enum Size: Sendable {
    case s36
    case s32
    case s28
    case s26
    case s22

    var height: CGFloat {
      switch self {
      case .s36: 36
      case .s32: 32
      case .s28: 28
      case .s26: 26
      case .s22: 22
      }
    }
  }

  let pill: StatusPill
  let surface: Surface
  let size: Size

  public init(_ pill: StatusPill, size: Size = .s26, surface: Surface = .white) {
    self.pill = pill
    self.size = size
    self.surface = surface
  }

  public var body: some View {
    HStack(spacing: dotGap) {
      if pill.showsDot && size != .s22 {
        Circle().fill(pill.tone.foreground).frame(width: dot, height: dot)
      }
      Text(pill.text)
        .hType(type)
        .foregroundStyle(pill.tone.foreground)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.leading, leading)
    .padding(.trailing, trailing)
    .padding(.vertical, 2)
    .frame(minHeight: size.height)
    .background(surface == .white ? HColor.surfacePosterPill : pill.tone.surface, in: Capsule())
    .accessibilityElement(children: .combine)
  }

  private var dot: CGFloat { size == .s32 || size == .s36 ? 8 : 7 }
  private var dotGap: CGFloat {
    switch size {
    case .s36: 8
    case .s32, .s28: 6
    case .s26, .s22: 5
    }
  }

  private var leading: CGFloat {
    switch size {
    case .s36: 14
    case .s32: 12
    case .s28, .s26: 10
    case .s22: 8
    }
  }

  private var trailing: CGFloat {
    switch size {
    case .s36: 16
    case .s32, .s28: 12
    case .s26: 10
    case .s22: 8
    }
  }

  private var type: HType {
    switch size {
    case .s36, .s32: .subheadline.weight(.semibold)
    case .s28, .s26: .footnote.weight(.semibold)
    case .s22: .caption1.weight(.semibold)
    }
  }
}

public struct CountBadge: View {
  public enum Tone: Sendable { case ink, alert, accent }

  public enum Style: Sendable {
    case glass20
    case tab18
    case title24
    case row22
    case chip20
  }

  private enum Variant {
    case tone(Tone)
    case style(Style)
  }

  let count: Int
  private let variant: Variant
  @ScaledMetric private var height: CGFloat

  public init(_ count: Int, tone: Tone = .ink) {
    self.count = count
    self.variant = .tone(tone)
    _height = ScaledMetric(wrappedValue: tone == .ink ? 24 : 20, relativeTo: tone == .ink ? .footnote : .caption)
  }

  public init(_ count: Int, style: Style) {
    self.count = count
    self.variant = .style(style)
    _height = ScaledMetric(wrappedValue: Self.height(style), relativeTo: .footnote)
  }

  public var body: some View {
    switch variant {
    case .tone(let tone):
      Text("\(count)")
        .font(.system(tone == .ink ? .footnote : .caption, design: .rounded, weight: .bold))
        .foregroundStyle(HColor.white)
        .padding(.horizontal, tone == .ink ? 7 : 6)
        .frame(minWidth: height, minHeight: height)
        .background(Self.fill(tone), in: Capsule())
    case .style(let style):
      if count > 0 {
        StyledBadge(count: count, style: style)
          .dynamicTypeSize(...DynamicTypeSize.accessibility1)
          .accessibilityHidden(true)
      }
    }
  }

  fileprivate static func height(_ style: Style) -> CGFloat {
    switch style {
    case .glass20, .chip20: 20
    case .tab18: 18
    case .title24: 24
    case .row22: 22
    }
  }

  fileprivate static func figure(_ style: Style) -> CGFloat {
    switch style {
    case .glass20, .chip20: 12
    case .tab18: 11
    case .title24, .row22: HFontSize.numericBadge
    }
  }

  fileprivate static func padding(_ style: Style) -> CGFloat {
    switch style {
    case .glass20, .chip20: 6
    case .tab18: 5
    case .title24, .row22: 7
    }
  }

  fileprivate static func fill(_ style: Style) -> Color {
    switch style {
    case .glass20, .tab18: HColor.badgeCount
    case .title24: HColor.textPrimary
    case .row22: HColor.listRowBadge
    case .chip20: HColor.actionAccent
    }
  }

  private static func fill(_ tone: Tone) -> Color {
    switch tone {
    case .ink: HColor.textPrimary
    case .alert: HColor.actionDestructive
    case .accent: HColor.actionAccent
    }
  }
}

private struct StyledBadge: View {
  let count: Int
  let style: CountBadge.Style
  @ScaledMetric private var height: CGFloat
  @ScaledMetric private var figure: CGFloat

  init(count: Int, style: CountBadge.Style) {
    self.count = count
    self.style = style
    _height = ScaledMetric(wrappedValue: CountBadge.height(style), relativeTo: .footnote)
    _figure = ScaledMetric(wrappedValue: CountBadge.figure(style), relativeTo: .footnote)
  }

  var body: some View {
    Text(count > 99 ? "99+" : "\(count)")
      .font(.system(size: figure, weight: .bold, design: .rounded).monospacedDigit())
      .accessibilityIdentifier(hasalaCappedFigureIdentifier)
      .foregroundStyle(style == .title24 ? HColor.white : HColor.badgeCountText)
      .padding(.horizontal, CountBadge.padding(style))
      .frame(minWidth: height, minHeight: height)
      .background(CountBadge.fill(style), in: Capsule())
      .overlay {
        if style == .glass20 || style == .tab18 {
          Capsule().strokeBorder(HColor.white, lineWidth: 2).padding(-2)
        }
      }
  }
}
