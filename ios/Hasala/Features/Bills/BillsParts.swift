import HasalaDesign
import HasalaModels
import SwiftUI

struct PushedPage<Content: View>: View {
  @Bindable var app: AppModel
  let title: String
  var wash: HWash = .onTrack
  var spacing: CGFloat = HSpacing.gapScreenSection
  var top: CGFloat = 20
  @ViewBuilder let content: () -> Content
  @Environment(\.inProfileSheet) private var inProfileSheet

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: spacing) { content() }
        .padding(.top, top)
        .padding(.bottom, HSpacing.scrollContentBottom)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .washBehind(wash)
    .scrollEdgeEffectStyle(.soft, for: .bottom)
    .background(inProfileSheet ? HColor.sheetSurfaceLarge : HColor.surfaceSecondary)
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
    .overlay(alignment: .bottom) { if !inProfileSheet { ToastHost(app: app) } }
  }
}

extension AppRouter {
  func openBill(_ id: BillID, inProfileSheet: Bool) {
    if inProfileSheet { profile.append(.bill(id)) } else { home.append(.bill(id)) }
  }
}

struct BillCard<Extra: View>: View {
  typealias Action = BillCardAction

  let hue: Hue
  let glyph: PosterGlyph
  let name: String
  let pill: StatusPill
  let amount: Money
  var caption: String?
  let message: MoneyPhrase?
  let hidden: Bool
  let primary: Action
  var secondary: Action?
  let id: String
  @ViewBuilder var extra: Extra

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 0) {
        poster
        if let message {
          Text(message.rendered(hidden: hidden))
            .hType(.subheadline)
            .foregroundStyle(HColor.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(spoken)
      VStack(alignment: .leading, spacing: 12) {
        extra
        buttons
      }
      .padding(.horizontal, 16)
      .padding(.top, 12)
      .padding(.bottom, 14)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(HColor.surfacePrimary)
    .clipShape(RoundedRectangle(cornerRadius: HRadius.brief, style: .continuous))
    .hElevation(.nearFar)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(id)
  }

  private var poster: some View {
    VStack(alignment: .leading, spacing: 0) {
      ReflowingRow(spacing: 6) {
        HStack(spacing: 8) {
          plate
          Text(name).hType(.footnote.weight(.semibold)).foregroundStyle(HColor.textPrimary)
            .lineLimitAtDefaultTextSize(2)
        }
      } trailing: {
        StatusPillView(pill)
      }
      Spacer(minLength: 6)
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        MoneyText(amount, figure: .large, unit: .unit, hidden: hidden, hiddenGlyphs: 3, color: HColor.textPrimary,
                  unitGap: 5)
        if let caption {
          Text(caption).hType(.body).foregroundStyle(HColor.textOnHueSecondary)
        }
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 13)
    .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
    .fixedSize(horizontal: false, vertical: true)
    .background(hue.perceptualGradient)
  }

  @ViewBuilder private var plate: some View {
    switch glyph {
    case .icon(let icon):
      GlyphPlate(icon: icon, hue: hue, size: 32)
    case .path(let stroke, let fill):
      Circle()
        .fill(HColor.posterGlyph)
        .frame(width: 32, height: 32)
        .overlay { StrokeGlyph(d: stroke, filled: fill, size: 18, color: hue.ink, lineWidth: 2) }
        .accessibilityHidden(true)
    }
  }

  private var buttons: some View {
    BillCardButtons(primary: primary, secondary: secondary)
  }

  private var spoken: String {
    let figure = hidden ? "Amount hidden" : "\(amount.currency) \(MoneyFormat.string(amount.minor))"
    let head = [name, figure + (caption.map { " \($0)" } ?? ""), pill.text].joined(separator: ", ")
    return message.map { "\(head). \($0.spoken(hidden: hidden))" } ?? head
  }
}

struct BillCardAction {
  let title: String
  let id: String
  let run: () -> Void
}

struct BillCardButtons: View {
  typealias Action = BillCardAction
  let primary: Action
  var secondary: Action?
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    if let secondary, !typeSize.isAccessibilitySize {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) {
          primaryButton
          secondaryButton(secondary)
            .frame(minWidth: 128)
            .fixedSize(horizontal: true, vertical: false)
        }
        VStack(spacing: 8) {
          primaryButton
          secondaryButton(secondary)
        }
      }
    } else {
      VStack(spacing: 8) {
        primaryButton
        if let secondary { secondaryButton(secondary) }
      }
    }
  }

  private var primaryButton: some View {
    Button(primary.title, action: primary.run)
      .buttonStyle(.pill(.primary, size: .medium, fill: true))
      .pillHeight()
      .accessibilityIdentifier(primary.id)
  }

  private func secondaryButton(_ secondary: Action) -> some View {
    Button(secondary.title, action: secondary.run)
      .buttonStyle(.pill(.secondary, size: .medium, fill: true))
      .pillHeight()
      .accessibilityIdentifier(secondary.id)
  }
}

extension BillCard where Extra == EmptyView {
  init(hue: Hue, glyph: PosterGlyph, name: String, pill: StatusPill, amount: Money, message: MoneyPhrase?,
       hidden: Bool, primary: Action, secondary: Action?, id: String)
  {
    self.init(hue: hue, glyph: glyph, name: name, pill: pill, amount: amount, caption: nil, message: message,
              hidden: hidden, primary: primary, secondary: secondary, id: id) { EmptyView() }
  }
}

enum PosterGlyph: Equatable {
  case icon(HIcon)
  case path(stroke: String, fill: String?)
}

struct BillsListRow: View {
  let row: BillRowModel
  var tag: StatusPill?
  let hidden: Bool
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    let layout = typeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
      : AnyLayout(HStackLayout(spacing: HSpacing.listRowGap))
    layout {
      CategoryDisc(hue: row.hue, glyph: row.glyph)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 8) {
          Text(row.name).hType(.rowTitle).foregroundStyle(HColor.listRowTitle).singleLineAtDefaultTextSize()
          if let tag { StatusPillView(tag, size: .s22, surface: .tinted).fixedSize() }
        }
        BillDetailParts(parts: row.detail, hidden: hidden)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      HStack(spacing: 0) {
        if row.approximate && !hidden {
          Text(verbatim: "~").hFigure(.row).foregroundStyle(HColor.moneyOut)
        }
        MoneyText(row.amount, figure: .row, hidden: hidden, hiddenGlyphs: 3,
                  color: row.isIncome ? HColor.moneyIn : HColor.moneyOut, sign: row.isIncome ? .income : .none)
      }
      .fixedSize()
    }
    .padding(.horizontal, HSpacing.listRowInsetInline)
    .padding(.vertical, HSpacing.listRowInsetBlock)
    .frame(minHeight: HSpacing.listRowMinHeightTwoLine)
    .contentShape(Rectangle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(spoken)
  }

  private var spoken: String {
    let amount = hidden
      ? "Amount hidden"
      : (row.approximate ? "about " : "") + (row.isIncome ? "plus " : "")
        + "\(row.amount.currency) \(MoneyFormat.string(row.amount.minor))"
    return [row.name, tag?.text, BillDetailParts.spoken(row.detail, hidden: hidden), amount]
      .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
  }
}

struct BillDetailParts: View {
  let parts: [PlanDetailPart]
  let hidden: Bool

  var body: some View {
    line.hType(.footnote).lineLimitAtDefaultTextSize(1)
  }

  private var line: Text {
    var text = Text(verbatim: "")
    for (index, part) in parts.enumerated() {
      if index > 0 {
        text = Text("\(text)\(Text(verbatim: " · ").foregroundStyle(HColor.listRowSupporting))")
      }
      switch part {
      case .text(let p):
        text = Text("\(text)\(Text(p.rendered(hidden: hidden)).foregroundStyle(HColor.listRowSupporting))")
      case .status(let words, let tone):
        let dot = Text(verbatim: "\u{25CF}\u{2002}").font(.system(size: 9)).foregroundStyle(tone.foreground)
        let said = Text(words).fontWeight(.semibold).foregroundStyle(tone.foreground)
        text = Text("\(text)\(dot)\(said)")
      }
    }
    return text
  }

  static func spoken(_ parts: [PlanDetailPart], hidden: Bool) -> String {
    parts.map { part in
      switch part {
      case .text(let p): p.spoken(hidden: hidden)
      case .status(let words, _): words
      }
    }.joined(separator: ", ")
  }
}

struct StrokeGlyph: View {
  let d: String
  var filled: String?
  var size: CGFloat = 16
  var color: Color
  var lineWidth: CGFloat = 2.4

  var body: some View {
    Canvas { context, canvas in
      let box = CGRect(origin: .zero, size: canvas)
      if let svg = try? SVGPath(parsing: d) {
        context.stroke(svg.path(in: box), with: .color(color), style: StrokeStyle(
          lineWidth: lineWidth * canvas.width / 24, lineCap: .round, lineJoin: .round))
      }
      if let filled, let svg = try? SVGPath(parsing: filled) {
        context.fill(svg.path(in: box), with: .color(color))
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

extension View {
  func pillHeight() -> some View { fixedSize(horizontal: false, vertical: true) }
}
