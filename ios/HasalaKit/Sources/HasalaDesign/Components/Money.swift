import HasalaModels
import SwiftUI

public struct MoneyText: View {
  public enum Sign: Sendable {
    case none
    case income
    case debt

    var glyph: String {
      switch self {
      case .none: ""
      case .income: "+"
      case .debt: "\u{2212}"
      }
    }

    var spoken: String {
      switch self {
      case .none: ""
      case .income: "plus "
      case .debt: "minus "
      }
    }
  }

  let money: Money
  let figure: HFigure
  let unit: HFigure?
  let style: MoneyStyle
  let hidden: Bool
  let hiddenGlyphs: Int
  let hiddenDots: CGFloat?
  let hiddenTracking: CGFloat
  let color: Color
  let unitColor: Color?
  let unitGap: CGFloat
  let sign: Sign
  let approx: Bool

  public init(
    _ money: Money, figure: HFigure, unit: HFigure? = nil, style: MoneyStyle = .exact, hidden: Bool = false,
    hiddenGlyphs: Int = 4, hiddenDots: CGFloat? = nil, hiddenTracking: CGFloat = 2,
    color: Color = HColor.moneyOut, unitColor: Color? = nil, unitGap: CGFloat = 8, sign: Sign = .none,
    approx: Bool = false
  ) {
    self.money = money
    self.figure = figure
    self.unit = unit
    self.style = style
    self.hidden = hidden
    self.hiddenGlyphs = hiddenGlyphs
    self.hiddenDots = hiddenDots
    self.hiddenTracking = hiddenTracking
    self.color = color
    self.unitColor = unitColor
    self.unitGap = unitGap
    self.sign = sign
    self.approx = approx
  }

  private var shownSign: String { hidden ? "" : (approx ? "\u{2248} " : "") + sign.glyph }

  private var digits: String {
    hidden
      ? MoneyFormat.hidden(count: hiddenGlyphs)
      : (unit == nil ? shownSign : "") + MoneyFormat.string(money, style: style)
  }

  public var body: some View {
    FigureLine(
      unit: unit.map { (shownSign + money.currency, $0, unitColor ?? color) },
      digits: digits, figure: hidden ? figure.forHiddenGlyphs(hiddenDots) : figure, color: color, gap: unitGap,
      hiddenTracking: hidden ? hiddenTracking : nil, numericValue: hidden ? nil : Double(money.minor)
    )
    .privacySensitive()
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Self.spoken(money, style: style, sign: sign, approx: approx, hidden: hidden))
  }

  static func spoken(_ money: Money, style: MoneyStyle = .exact, sign: Sign = .none, approx: Bool = false,
                     hidden: Bool) -> String
  {
    hidden
      ? "Amount hidden"
      : "\(approx ? "about " : "")\(sign.spoken)\(money.currency) \(MoneyFormat.string(money, style: style))"
  }
}

extension HFigure {
  func forHiddenGlyphs(_ dots: CGFloat? = nil) -> HFigure {
    var f = self
    if let dots {
      f.size = dots
    } else {
      guard size >= 28 else { return self }
      f.size = (size * 0.55).rounded()
    }
    f.leading = leading
    return f
  }
}

struct FigureLine: View {
  let unit: (text: String, figure: HFigure, color: Color)?
  let digits: String
  let figure: HFigure
  let color: Color
  let gap: CGFloat
  let hiddenTracking: CGFloat?
  let numericValue: Double?

  var body: some View {
    FigureLineBody(line: self)
      .cappedDynamicType(figure)
  }
}

private struct FigureLineBody: View {
  let line: FigureLine
  @ScaledMetric private var figureSize: CGFloat
  @ScaledMetric private var unitSize: CGFloat
  @ResolvedMotion private var motion: MotionPolicy

  init(line: FigureLine) {
    self.line = line
    _figureSize = ScaledMetric(wrappedValue: line.figure.size, relativeTo: line.figure.textStyle)
    _unitSize = ScaledMetric(wrappedValue: line.unit?.figure.size ?? line.figure.size,
                             relativeTo: line.figure.textStyle)
  }

  var body: some View {
    let scale = figureSize / line.figure.size
    let extra = max(0, (line.figure.leading - line.figure.size * roundedLineRatio) * scale)
    Text(attributed(scale: scale))
      .lineLimit(1)
      .minimumScaleFactor(line.figure.minimumScale < 1 ? line.figure.minimumScale : 0.75)
      .padding(.vertical, extra / 2)
      .contentTransition(motion.isStill || line.numericValue == nil
        ? .identity : .numericText(value: line.numericValue ?? 0))
  }

  private func attributed(scale: CGFloat) -> AttributedString {
    var out = AttributedString()
    if let unit = line.unit {
      var u = AttributedString(unit.text)
      u.font = unit.figure.font(size: unitSize)
      u.foregroundColor = unit.color
      u.tracking = unit.figure.tracking * scale
      if let last = u.characters.indices.last {
        u[last...].kern = line.gap * scale
      }
      out += u
    }
    var d = AttributedString(line.digits)
    d.font = line.figure.font(size: figureSize)
    d.foregroundColor = line.color
    d.tracking = line.hiddenTracking ?? line.figure.tracking * scale
    out += d
    return out
  }
}

public struct AmountFigure: View {
  public enum Layout: Sendable { case docked, inline }

  let unit: String
  let entry: AmountEntry
  let caret: Bool
  let layout: Layout

  public init(unit: String = "AED", entry: AmountEntry, caret: Bool = true, layout: Layout = .docked) {
    self.unit = unit
    self.entry = entry
    self.caret = caret
    self.layout = layout
  }

  public var body: some View {
    HStack(alignment: .center, spacing: layout == .docked ? 3 : 8) {
      FigureLine(
        unit: (unit, unitFigure, layout == .docked ? HColor.textSecondary : HColor.textPrimary),
        digits: entry.display, figure: Self.figure, color: HColor.moneyOut, gap: layout == .docked ? 8 : 6,
        hiddenTracking: nil, numericValue: nil)
      if caret {
        RoundedRectangle(cornerRadius: 2)
          .fill(HColor.actionAccent)
          .frame(width: 3, height: 46)
          .accessibilityHidden(true)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Amount")
    .accessibilityValue(entry.spoken(unit: unit))
  }

  private var unitFigure: HFigure {
    layout == .docked ? .displayUnit : HFigure(size: 22, leading: 28, weight: .semibold, textStyle: .title3,
                                               maxDynamicTypeSize: .accessibility3)
  }

  static let figure: HFigure = {
    var f = HFigure.display
    f.minimumScale = 0.5
    return f
  }()
}
