import SwiftUI

public enum HWeight: Sendable, Hashable, CaseIterable {
  case regular, medium, semibold, bold

  public var interFace: String {
    switch self {
    case .regular: "InterVariable"
    case .medium: "InterVariable-Medium"
    case .semibold: "InterVariable-SemiBold"
    case .bold: "InterVariable-Bold"
    }
  }

  public var cssWeight: Int {
    switch self {
    case .regular: HFontWeight.regular
    case .medium: HFontWeight.medium
    case .semibold: HFontWeight.semibold
    case .bold: HFontWeight.bold
    }
  }

  public var bolder: HWeight {
    switch self {
    case .regular: .medium
    case .medium: .semibold
    case .semibold, .bold: .bold
    }
  }

  public var systemWeight: Font.Weight {
    switch self {
    case .regular: .regular
    case .medium: .medium
    case .semibold: .semibold
    case .bold: .bold
    }
  }
}

public struct HType: Sendable, Hashable {
  public var size: CGFloat
  public var leading: CGFloat
  public var weight: HWeight
  public var tracking: CGFloat
  public var trackingEm: CGFloat?
  public var uppercase: Bool
  public var textStyle: Font.TextStyle

  public init(
    size: CGFloat, leading: CGFloat, weight: HWeight, tracking: CGFloat = 0, trackingEm: CGFloat? = nil,
    uppercase: Bool = false, textStyle: Font.TextStyle
  ) {
    self.size = size
    self.leading = leading
    self.weight = weight
    self.tracking = tracking
    self.trackingEm = trackingEm
    self.uppercase = uppercase
    self.textStyle = textStyle
  }

  public func weight(_ w: HWeight) -> HType {
    var t = self
    t.weight = w
    return t
  }

  public var resolvedTracking: CGFloat { trackingEm.map { $0 * size } ?? tracking }

  public var font: Font { .custom(weight.interFace, size: size, relativeTo: textStyle) }

  public static let largeTitle = HType(size: HFontSize.largeTitle, leading: HLeading.largeTitle, weight: .bold,
                                       tracking: HTracking.largeTitle, textStyle: .largeTitle)
  public static let title1 = HType(size: HFontSize.title1, leading: HLeading.title1, weight: .bold,
                                   tracking: HTracking.title1, textStyle: .title)
  public static let title2 = HType(size: HFontSize.title2, leading: HLeading.title2, weight: .semibold,
                                   tracking: HTracking.title2, textStyle: .title2)
  public static let section = HType(size: HFontSize.title2, leading: HLeading.title2, weight: .bold,
                                    tracking: HTracking.title2, textStyle: .title2)
  public static let title3 = HType(size: HFontSize.title3, leading: HLeading.title3, weight: .semibold,
                                   tracking: HTracking.title3, textStyle: .title3)
  public static let headline = HType(size: HFontSize.headline, leading: HLeading.headline, weight: .semibold,
                                     tracking: HTracking.headline, textStyle: .headline)
  public static let body = HType(size: HFontSize.body, leading: HLeading.body, weight: .regular,
                                 tracking: HTracking.body, textStyle: .body)
  public static let callout = HType(size: HFontSize.callout, leading: HLeading.callout, weight: .regular,
                                    tracking: HTracking.callout, textStyle: .callout)
  public static let rowTitle = HType(size: HFontSize.callout, leading: HLeading.callout, weight: .semibold,
                                     tracking: HTracking.callout, textStyle: .callout)
  public static let subheadline = HType(size: HFontSize.subheadline, leading: HLeading.subheadline,
                                        weight: .regular, tracking: HTracking.subheadline, textStyle: .subheadline)
  public static let footnote = HType(size: HFontSize.footnote, leading: HLeading.footnote, weight: .regular,
                                     tracking: HTracking.footnote, textStyle: .footnote)
  public static let caption1 = HType(size: HFontSize.caption1, leading: HLeading.caption1, weight: .medium,
                                     tracking: HTracking.caption1, textStyle: .caption)
  public static let caption2 = HType(size: HFontSize.caption2, leading: HLeading.caption2, weight: .medium,
                                     tracking: HTracking.caption2, textStyle: .caption2)
  public static let button = HType(size: HFontSize.button, leading: HLeading.button, weight: .semibold,
                                   tracking: HTracking.button, textStyle: .body)
  public static let smallButton = HType(size: HFontSize.subheadline, leading: HLeading.subheadline,
                                        weight: .semibold, textStyle: .subheadline)
  public static let textButton = HType(size: HFontSize.body, leading: HLeading.body, weight: .semibold,
                                       tracking: HTracking.body, textStyle: .body)
  public static let inlineLink = HType(size: HFontSize.subheadline, leading: HLeading.subheadline,
                                       weight: .semibold, textStyle: .subheadline)
  public static let cardTitle = HType(size: HFontSize.headline, leading: 22, weight: .semibold,
                                      tracking: HTracking.headline, textStyle: .headline)
  public static let overline = HType(size: HFontSize.footnote, leading: HLeading.overline, weight: .semibold,
                                     trackingEm: HTracking.overlineEm, uppercase: true, textStyle: .footnote)
}

public struct HFigure: Sendable, Hashable {
  public var size: CGFloat
  public var leading: CGFloat
  public var weight: HWeight
  public var tracking: CGFloat
  public var textStyle: Font.TextStyle
  public var tabular: Bool
  public var maxDynamicTypeSize: DynamicTypeSize
  public var minimumScale: CGFloat

  public init(
    size: CGFloat, leading: CGFloat, weight: HWeight, tracking: CGFloat = 0, textStyle: Font.TextStyle,
    tabular: Bool = false, maxDynamicTypeSize: DynamicTypeSize = .accessibility5, minimumScale: CGFloat = 1
  ) {
    self.size = size
    self.leading = leading
    self.weight = weight
    self.tracking = tracking
    self.textStyle = textStyle
    self.tabular = tabular
    self.maxDynamicTypeSize = maxDynamicTypeSize
    self.minimumScale = minimumScale
  }

  public var floor: CGFloat { (size * minimumScale).rounded() }

  public func weight(_ w: HWeight) -> HFigure {
    var f = self
    f.weight = w
    return f
  }

  func font(size: CGFloat) -> Font {
    let font = Font.system(size: size, weight: weight.systemWeight, design: .rounded)
    return tabular ? font.monospacedDigit() : font
  }

  public static let display = HFigure(size: HFontSize.numericDisplay, leading: HLeading.numericDisplay,
                                      weight: .bold, tracking: HTracking.numericDisplay, textStyle: .largeTitle,
                                      maxDynamicTypeSize: .accessibility3, minimumScale: 0.6)
  public static let hero = HFigure(size: HFontSize.numericHero, leading: HLeading.numericHero, weight: .bold,
                                   tracking: HTracking.numericHero, textStyle: .largeTitle,
                                   maxDynamicTypeSize: .accessibility3, minimumScale: 0.6)
  public static let widget = HFigure(size: 40, leading: 44, weight: .bold, tracking: HTracking.numericHero,
                                     textStyle: .largeTitle, minimumScale: 0.55)
  public static let large = HFigure(size: HFontSize.numericLarge, leading: HLeading.numericLarge, weight: .bold,
                                    tracking: HTracking.numericLarge, textStyle: .title, minimumScale: 0.6)
  public static let medium = HFigure(size: HFontSize.numericMedium, leading: HLeading.numericMedium,
                                     weight: .medium, tracking: HTracking.numericMedium, textStyle: .title2,
                                     minimumScale: 0.75)
  public static let small = HFigure(size: HFontSize.numericSmall, leading: HLeading.numericSmall, weight: .bold,
                                    textStyle: .title3, minimumScale: 0.75)
  public static let stat = HFigure(size: HFontSize.numericUnit, leading: HLeading.numericUnit, weight: .bold,
                                   textStyle: .body, minimumScale: 0.75)
  public static let displayUnit = HFigure(size: HFontSize.numericDisplayUnit, leading: HLeading.numericDisplayUnit,
                                          weight: .semibold, textStyle: .title3, maxDynamicTypeSize: .accessibility3)
  public static let unit = HFigure(size: HFontSize.numericUnit, leading: HLeading.numericUnit, weight: .semibold,
                                   textStyle: .body)
  public static let row = HFigure(size: HFontSize.numericRow, leading: HLeading.numericRow, weight: .bold,
                                  textStyle: .callout, tabular: true)
  public static let compact = HFigure(size: HFontSize.numericCompact, leading: HLeading.numericCompact,
                                      weight: .bold, textStyle: .subheadline, tabular: true)
  public static let badge = HFigure(size: HFontSize.numericBadge, leading: HLeading.numericBadge, weight: .bold,
                                    textStyle: .footnote, tabular: true)
}

let interLineRatio: CGFloat = 1.21
let roundedLineRatio: CGFloat = 1.19

struct HTypeModifier: ViewModifier {
  let type: HType
  @ScaledMetric private var scale: CGFloat
  @Environment(\.legibilityWeight) private var legibilityWeight

  init(type: HType) {
    self.type = type
    _scale = ScaledMetric(wrappedValue: 1, relativeTo: type.textStyle)
  }

  func body(content: Content) -> some View {
    let extra = max(0, (type.leading - type.size * interLineRatio) * scale)
    let weight = legibilityWeight == .bold ? type.weight.bolder : type.weight
    content
      .font(type.weight(weight).font)
      .tracking(type.resolvedTracking * scale)
      .textCase(type.uppercase ? .uppercase : nil)
      .lineSpacing(extra)
      .padding(.vertical, extra / 2)
  }
}

struct HFigureModifier: ViewModifier {
  let figure: HFigure
  @ScaledMetric private var size: CGFloat

  init(figure: HFigure) {
    self.figure = figure
    _size = ScaledMetric(wrappedValue: figure.size, relativeTo: figure.textStyle)
  }

  func body(content: Content) -> some View {
    let scale = size / figure.size
    let extra = max(0, (figure.leading - figure.size * roundedLineRatio) * scale)
    content
      .font(figure.font(size: size))
      .tracking(figure.tracking * scale)
      .padding(.vertical, extra / 2)
  }
}

public extension View {
  func hType(_ type: HType) -> some View { modifier(HTypeModifier(type: type)) }

  func hFigure(_ figure: HFigure) -> some View {
    modifier(HFigureModifier(figure: figure))
      .cappedDynamicType(figure)
  }

  func singleLineAtDefaultTextSize() -> some View { lineLimitAtDefaultTextSize(1) }

  func lineLimitAtDefaultTextSize(_ lines: Int) -> some View { modifier(LineLimitAtDefaultTextSize(lines: lines)) }
}

extension View {
  func cappedDynamicType(_ figure: HFigure) -> some View {
    dynamicTypeSize(...figure.maxDynamicTypeSize)
      .modifier(CappedFigureMarker(capped: figure.maxDynamicTypeSize < .accessibility5))
  }
}

struct LineLimitAtDefaultTextSize: ViewModifier {
  let lines: Int
  @Environment(\.dynamicTypeSize) private var size

  func body(content: Content) -> some View {
    content.lineLimit(size <= .large ? lines : nil)
  }
}

public let hasalaCappedFigureIdentifier = "hasala.cappedFigure"

struct CappedFigureMarker: ViewModifier {
  let capped: Bool

  func body(content: Content) -> some View {
    if capped {
      content.accessibilityIdentifier(hasalaCappedFigureIdentifier)
    } else {
      content
    }
  }
}
