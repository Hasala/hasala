import HasalaModels
import SwiftUI

public struct SwipeRowPan: Sendable, Equatable {
  private enum Phase: Sendable, Equatable {
    case idle
    case panning(from: CGFloat)
    case committing(fingerDown: Bool)
    case spent
  }

  private var phase = Phase.idle

  public init() {}

  public var isIdle: Bool { phase == .idle }

  public var isPanning: Bool {
    if case .panning = phase { return true }
    return false
  }

  public mutating func moved(at offset: CGFloat) -> CGFloat? {
    switch phase {
    case .idle:
      phase = .panning(from: offset)
      return offset
    case .panning(let from):
      return from
    case .committing, .spent:
      return nil
    }
  }

  public mutating func released() -> CGFloat? {
    switch phase {
    case .panning(let from):
      phase = .idle
      return from
    case .committing:
      phase = .committing(fingerDown: false)
      return nil
    case .spent:
      phase = .idle
      return nil
    case .idle:
      return nil
    }
  }

  public mutating func commit() -> Bool {
    switch phase {
    case .idle:
      phase = .committing(fingerDown: false)
    case .panning, .spent:
      phase = .committing(fingerDown: true)
    case .committing:
      return false
    }
    return true
  }

  public mutating func committed() {
    guard case .committing(let fingerDown) = phase else { return }
    phase = fingerDown ? .spent : .idle
  }
}

public struct HListCard<Content: View>: View {
  let alignment: HorizontalAlignment
  let content: Content

  public init(alignment: HorizontalAlignment = .center, @ViewBuilder content: () -> Content) {
    self.alignment = alignment
    self.content = content()
  }

  public var body: some View {
    VStack(alignment: alignment, spacing: 0) { content }
      .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
      .background(HColor.listRowSurface)
      .clipShape(RoundedRectangle(cornerRadius: HRadius.listGroup, style: .continuous))
  }
}

public struct HDivider: View {
  public enum Inset: Sendable {
    case disc68
    case icon52
    case text16
    case lane35
    case none

    var value: CGFloat {
      switch self {
      case .disc68: 68
      case .icon52: 52
      case .text16: 16
      case .lane35: 35
      case .none: 0
      }
    }
  }

  let inset: Inset
  @Environment(\.dynamicTypeSize) private var typeSize

  public init(inset: Inset = .disc68) {
    self.inset = inset
  }

  public var body: some View {
    HColor.listRowSeparator
      .frame(height: 1)
      .padding(.leading, typeSize.isAccessibilitySize && inset != .none ? 16 : inset.value)
      .accessibilityHidden(true)
  }
}

public struct HListRow: View {
  public enum Leading {
    case disc(Hue, HIcon)
    case monogram(String)
    case plate(initials: String, hue: Hue)
    case provider(MailProviderKind)
    case icon22(HIcon, color: Color = HColor.listRowIcon)
    case none
  }

  public enum Supporting: ExpressibleByStringLiteral {
    case text(String)
    case wrapping(String)
    case phrase(MoneyPhrase)
    case status(String, StatusTone)

    public init(stringLiteral value: String) { self = .text(value) }
  }

  public enum Trailing {
    case amount(Money, in: Bool = false, approx: Bool = false)
    case value(String)
    case chevron
    case valueChevron(String)
    case `switch`(Binding<Bool>)
    case check(Bool)
    case badge(Int)
    case status(StatusPill)
    case none
  }

  let leading: Leading
  let title: String
  let titleColor: Color
  let supporting: Supporting?
  let trailing: Trailing
  let hidden: Bool
  let project: String?
  let spokenSupporting: String?
  let supportingID: String?
  @Environment(\.dynamicTypeSize) private var typeSize

  public init(leading: Leading = .none, title: String, supporting: Supporting? = nil, trailing: Trailing = .none,
              titleColor: Color = HColor.listRowTitle, hidden: Bool = false, project: String? = nil,
              spokenSupporting: String? = nil, supportingID: String? = nil)
  {
    self.project = project
    self.spokenSupporting = spokenSupporting
    self.supportingID = supportingID
    self.leading = leading
    self.title = title
    self.supporting = supporting
    self.trailing = trailing
    self.titleColor = titleColor
    self.hidden = hidden
  }

  private var isIconRow: Bool {
    if case .icon22 = leading { return true }
    return false
  }

  private var hasLeading: Bool {
    if case .none = leading { return false }
    return true
  }

  public var body: some View {
    Group {
      if typeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 8) {
          if hasLeading { leadingView }
          text
          trailingView
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        HStack(spacing: isIconRow ? 14 : HSpacing.listRowGap) {
          if hasLeading { leadingView }
          text.frame(maxWidth: .infinity, alignment: .leading)
          trailingView
        }
        .padding(.vertical, isIconRow ? 0 : HSpacing.listRowInsetBlock)
        .frame(minHeight: supporting == nil ? HSpacing.listRowMinHeight : HSpacing.listRowMinHeightTwoLine)
      }
    }
    .padding(.horizontal, HSpacing.listRowInsetInline)
    .contentShape(Rectangle())
    .modifier(RowAccessibility(isSwitch: isSwitch, label: spokenLabel, value: spokenValue))
  }

  private var isSwitch: Bool {
    if case .switch = trailing { return true }
    return false
  }

  @ViewBuilder private var leadingView: some View {
    switch leading {
    case .disc(let hue, let icon): CategoryDisc(hue: hue, icon: icon)
    case .monogram(let letter): MonogramDisc(letter)
    case .plate(let initials, let hue): BankPlate(initials: initials, hue: hue)
    case .provider(let p): ProviderMark(p)
    case .icon22(let icon, let color): HIconView(icon, size: HSpacing.iconGlass, color: color, strokeWidth: 1.8)
    case .none: EmptyView()
    }
  }

  private var text: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).hType(.rowTitle).foregroundStyle(titleColor).lineLimitAtDefaultTextSize(2)
      if let supporting {
        if let project {
          ProjectChipFlow(project) { SupportingLine(supporting, hidden: hidden, id: supportingID) }
        } else {
          SupportingLine(supporting, hidden: hidden, id: supportingID)
        }
      } else if let project {
        ProjectChip(project)
      }
    }
  }

  @ViewBuilder private var trailingView: some View {
    switch trailing {
    case .amount(let money, let isIn, let approx):
      MoneyText(money, figure: .row, hidden: hidden, hiddenGlyphs: 3, color: isIn ? HColor.moneyIn : HColor.moneyOut,
                sign: isIn ? .income : .none, approx: approx)
        .fixedSize()
    case .value(let v):
      Text(v).hType(.subheadline).foregroundStyle(HColor.listRowSupporting)
    case .chevron:
      HIconView(.chevronRight, size: HSpacing.iconSmall, color: HColor.listRowChevron)
    case .valueChevron(let v):
      HStack(spacing: 8) {
        Text(v).hType(.subheadline).foregroundStyle(HColor.listRowSupporting)
        HIconView(.chevronRight, size: HSpacing.iconSmall, color: HColor.listRowChevron)
      }
    case .switch(let isOn):
      Toggle("", isOn: isOn).labelsHidden().tint(HColor.controlSwitchTrackOn)
    case .check(let on):
      ZStack { if on { HIconView(.check, size: 22, color: HColor.listRowCheck) } }.frame(width: 24, height: 24)
    case .badge(let n):
      HStack(spacing: 12) {
        CountBadge(n, style: .row22)
        HIconView(.chevronRight, size: HSpacing.iconSmall, color: HColor.listRowChevron)
      }
    case .status(let pill):
      StatusPillView(pill, size: .s22, surface: .tinted)
    case .none:
      EmptyView()
    }
  }

  private var spokenLabel: String {
    var parts = [title]
    if let supporting { parts.append(spokenSupporting ?? supporting.spoken(hidden: hidden)) }
    if let project { parts.append(ProjectChip.spoken(project)) }
    return parts.joined(separator: ", ")
  }

  private var spokenValue: String {
    switch trailing {
    case .amount(let m, let isIn, let approx):
      MoneyText.spoken(m, sign: isIn ? .income : .none, approx: approx, hidden: hidden)
    case .value(let v), .valueChevron(let v): v
    case .badge(let n): n > 0 ? "\(n) new" : ""
    case .status(let pill): pill.text
    case .check(let on): on ? "Selected" : ""
    case .switch, .chevron, .none: ""
    }
  }
}

struct RowAccessibility: ViewModifier {
  let isSwitch: Bool
  let label: String
  let value: String

  func body(content: Content) -> some View {
    if isSwitch {
      content.accessibilityElement(children: .combine).accessibilityLabel(label)
    } else {
      content
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
  }
}

struct SupportingLine: View {
  let line: HListRow.Supporting
  let hidden: Bool
  let id: String?

  init(_ line: HListRow.Supporting, hidden: Bool, id: String? = nil) {
    self.line = line
    self.hidden = hidden
    self.id = id
  }

  @ViewBuilder var body: some View {
    if let id {
      content.accessibilityIdentifier(id)
    } else {
      content
    }
  }

  @ViewBuilder private var content: some View {
    switch line {
    case .text(let s):
      Text(s).hType(.footnote).foregroundStyle(HColor.listRowSupporting).singleLineAtDefaultTextSize()
    case .wrapping(let s):
      Text(s).hType(.footnote).foregroundStyle(HColor.listRowSupporting).fixedSize(horizontal: false, vertical: true)
    case .phrase(let p):
      Text(p.rendered(hidden: hidden)).hType(.footnote).foregroundStyle(HColor.listRowSupporting)
        .singleLineAtDefaultTextSize()
    case .status(let s, let tone):
      HStack(spacing: 6) {
        Circle().fill(tone.foreground).frame(width: 7, height: 7)
        Text(s).hType(.footnote.weight(.semibold)).foregroundStyle(tone.foreground).singleLineAtDefaultTextSize()
      }
    }
  }
}

extension HListRow.Supporting {
  func spoken(hidden: Bool) -> String {
    switch self {
    case .text(let s), .wrapping(let s), .status(let s, _): s
    case .phrase(let p): p.spoken(hidden: hidden)
    }
  }
}

public struct KeyValueRow: View {
  let key: String
  let value: String
  let dot: Hue?
  let chevron: Bool
  let placeholder: Bool

  public init(_ key: String, value: String, dot: Hue? = nil, chevron: Bool = false, placeholder: Bool = false) {
    self.key = key
    self.value = value
    self.dot = dot
    self.chevron = chevron
    self.placeholder = placeholder
  }

  public var body: some View {
    ReflowingRow(spacing: 12) {
      Text(key).hType(.subheadline).foregroundStyle(HColor.listRowSupporting)
    } trailing: {
      HStack(spacing: 8) {
        if let dot { Circle().fill(dot.dotGradient).frame(width: 8, height: 8) }
        Text(value)
          .hType(placeholder ? .subheadline : .subheadline.weight(.semibold))
          .foregroundStyle(placeholder ? HColor.listRowSupporting : HColor.listRowTitle)
        if chevron {
          HIconView(.chevronRight, size: HSpacing.iconSmall, color: HColor.listRowChevron)
        } else {
          Color.clear.frame(width: HSpacing.iconSmall, height: HSpacing.iconSmall)
        }
      }
    }
    .frame(minHeight: HSpacing.listRowMinHeightKeyValue)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(key)
    .accessibilityValue(value)
  }
}

public struct SettingsRow: View {
  public enum Accessory {
    case chevron
    case value(String)
    case `switch`(Binding<Bool>)
    case none
  }

  public enum Role: Sendable {
    case standard
    case action
    case destructive
  }

  let icon: HIcon?
  let title: String
  let accessory: Accessory
  let role: Role

  public init(icon: HIcon?, title: String, accessory: Accessory = .chevron, role: Role = .standard) {
    self.icon = icon
    self.title = title
    self.accessory = accessory
    self.role = role
  }

  public var body: some View {
    HListRow(leading: icon.map { .icon22($0, color: tint) } ?? .none, title: title, trailing: trailing,
             titleColor: role == .standard ? HColor.listRowTitle : tint)
  }

  private var tint: Color {
    switch role {
    case .standard: HColor.listRowIcon
    case .action: HColor.listRowAction
    case .destructive: HColor.listRowDestructive
    }
  }

  private var trailing: HListRow.Trailing {
    switch accessory {
    case .chevron: .chevron
    case .value(let v): .valueChevron(v)
    case .switch(let b): .switch(b)
    case .none: .none
    }
  }
}

public struct HSectionHeader: View {
  public enum Trailing {
    case link(String, action: () -> Void)
    case fact(String)
    case count(Int)
    case none
  }

  let title: String
  let subtitle: String?
  let trailing: Trailing

  public init(_ title: String, subtitle: String? = nil, trailing: Trailing = .none) {
    self.title = title
    self.subtitle = subtitle
    self.trailing = trailing
  }

  public var body: some View {
    ReflowingRow(alignment: subtitle == nil ? .firstTextBaseline : .bottom) {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 8) {
          Text(title).hType(.section).foregroundStyle(HColor.textPrimary)
            .accessibilityAddTraits(.isHeader)
          if case .count(let n) = trailing {
            CountBadge(n, style: .title24)
          }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(countLabel)
        if let subtitle {
          Text(subtitle).hType(.subheadline).foregroundStyle(HColor.textSecondary)
        }
      }
    } trailing: {
      switch trailing {
      case .link(let label, let action):
        Button(label, action: action)
          .buttonStyle(.inlineLink)
      case .fact(let fact):
        Text(fact).hType(.subheadline).foregroundStyle(HColor.textSecondary)
      case .count, .none:
        EmptyView()
      }
    }
  }

  private var countLabel: String {
    if case .count(let n) = trailing, n > 0 { return "\(title), \(n)" }
    return title
  }
}

public struct OverlineHeader<Trailing: View>: View {
  let title: String
  let trailing: Trailing

  public init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
    self.title = title
    self.trailing = trailing()
  }

  public var body: some View {
    ReflowingRow(alignment: .firstTextBaseline) {
      Text(title).hType(.overline).foregroundStyle(HColor.textGroupedHeader).accessibilityAddTraits(.isHeader)
    } trailing: {
      trailing
    }
    .padding(.leading, 4)
    .padding(.trailing, 4)
    .padding(.top, 2)
  }
}

public extension OverlineHeader where Trailing == EmptyView {
  init(_ title: String) {
    self.init(title) { EmptyView() }
  }
}

public struct TransactionRow: View {
  let row: MiniTxnRow
  let hidden: Bool

  static func tone(_ reason: TxnReviewReason?) -> StatusTone {
    switch reason {
    case .probableCopy, .samePurchase, .mayRepeat: .accent
    case nil: .accent
    }
  }

  public init(_ row: MiniTxnRow, hidden: Bool) {
    self.row = row
    self.hidden = hidden
  }

  public var body: some View {
    HListRow(
      leading: row.monogram.map { .monogram($0) } ?? .disc(row.hue, row.glyph.icon),
      title: row.merchant,
      supporting: row.toReview ? .status(row.detail, Self.tone(row.reviewReason)) : .text(row.detail),
      trailing: row.notCounted ? .value("Not counted") : .amount(row.amount, in: row.isIncome, approx: row.estimate),
      hidden: hidden,
      project: row.project?.name,
      spokenSupporting: row.toReview ? nil : row.spokenDetail,
      supportingID: row.spokenDetail == nil || row.toReview ? nil : "activity.row.source")
  }
}

public struct ProjectChip: View {
  let name: String
  @Environment(\.dynamicTypeSize) private var typeSize
  @ScaledMetric(relativeTo: .caption) private var height: CGFloat = 20

  public init(_ name: String) {
    self.name = name
  }

  public static func spoken(_ name: String) -> String { "\(name) project" }

  public var body: some View {
    let large = typeSize.isAccessibilitySize
    HStack(spacing: large ? 8 : 4) {
      HIconView(.project, size: large ? 26 : 12, color: HColor.huePeachInk, strokeWidth: large ? 2 : 2.4)
      Text(name).hType(.caption1).foregroundStyle(HColor.huePeachInk)
        .lineLimit(large ? nil : 1).truncationMode(.tail)
        .fixedSize(horizontal: false, vertical: large)
    }
    .padding(.leading, large ? 10 : 5)
    .padding(.trailing, large ? 16 : 8)
    .padding(.vertical, large ? 4 : 0)
    .frame(minHeight: large ? nil : height)
    .background(HColor.bucketProjectStart, in: Capsule())
    .frame(maxWidth: large ? nil : 140, alignment: .leading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Self.spoken(name))
  }
}

public struct ProjectChipFlow<Detail: View>: View {
  let project: String
  let detail: Detail
  @Environment(\.dynamicTypeSize) private var typeSize

  public init(_ project: String, @ViewBuilder detail: () -> Detail) {
    self.project = project
    self.detail = detail()
  }

  public var body: some View {
    if typeSize.isAccessibilitySize {
      stacked(spacing: 8)
    } else {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .center, spacing: 6) {
          detail
          ProjectChip(project)
        }
        stacked(spacing: 4)
      }
    }
  }

  private func stacked(spacing: CGFloat) -> some View {
    VStack(alignment: .leading, spacing: spacing) {
      detail
      ProjectChip(project)
    }
  }
}

public struct BillRowView: View {
  let row: BillRowModel
  let hidden: Bool
  @Environment(\.dynamicTypeSize) private var typeSize

  public init(_ row: BillRowModel, hidden: Bool) {
    self.row = row
    self.hidden = hidden
  }

  public var body: some View {
    let layout = typeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
      : AnyLayout(HStackLayout(spacing: HSpacing.listRowGap))
    layout {
      CategoryDisc(hue: row.hue, glyph: row.glyph)
      VStack(alignment: .leading, spacing: 2) {
        Text(row.name).hType(.rowTitle).foregroundStyle(HColor.listRowTitle).singleLineAtDefaultTextSize()
        DetailParts(parts: row.detail, hidden: hidden)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      VStack(alignment: typeSize.isAccessibilitySize ? .leading : .trailing, spacing: 2) {
        HStack(spacing: 0) {
          if row.approximate && !hidden {
            Text(verbatim: "~").hFigure(.row).foregroundStyle(HColor.moneyOut)
          }
          MoneyText(row.amount, figure: .row, hidden: hidden, hiddenGlyphs: 3,
                    color: row.isIncome ? HColor.moneyIn : HColor.moneyOut, sign: row.isIncome ? .income : .none)
        }
        if let note = row.trailingNote { DetailParts(parts: [note], hidden: hidden) }
      }
      .fixedSize()
    }
    .padding(.horizontal, HSpacing.listRowInsetInline)
    .padding(.vertical, HSpacing.listRowInsetBlock)
    .frame(minHeight: HSpacing.listRowMinHeightTwoLine)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(spoken)
  }

  private var spoken: String {
    let amount = MoneyText.spoken(row.amount, sign: row.isIncome ? .income : .none, approx: row.approximate,
                                  hidden: hidden)
    return ([row.name, DetailParts.spoken(row.detail, hidden: hidden), amount]
      + (row.trailingNote.map { [DetailParts.spoken([$0], hidden: hidden)] } ?? []))
      .filter { !$0.isEmpty }
      .joined(separator: ", ")
  }
}

struct DetailParts: View {
  let parts: [PlanDetailPart]
  let hidden: Bool

  var body: some View {
    HStack(spacing: 0) {
      ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
        if index > 0 {
          Text(verbatim: " · ").hType(.footnote).foregroundStyle(HColor.listRowSupporting)
        }
        switch part {
        case .text(let p):
          Text(p.rendered(hidden: hidden)).hType(.footnote).foregroundStyle(HColor.listRowSupporting)
        case .status(let words, let tone):
          HStack(spacing: 6) {
            Circle().fill(tone.foreground).frame(width: 7, height: 7)
            Text(words).hType(.footnote.weight(.semibold)).foregroundStyle(tone.foreground)
          }
        }
      }
    }
    .lineLimitAtDefaultTextSize(1)
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

public struct ReflowingRow<Leading: View, Trailing: View>: View {
  let spacing: CGFloat
  let alignment: VerticalAlignment
  let leading: Leading
  let trailing: Trailing
  @Environment(\.dynamicTypeSize) private var typeSize

  public init(
    spacing: CGFloat = 8, alignment: VerticalAlignment = .center, @ViewBuilder leading: () -> Leading,
    @ViewBuilder trailing: () -> Trailing
  ) {
    self.spacing = spacing
    self.alignment = alignment
    self.leading = leading()
    self.trailing = trailing()
  }

  public var body: some View {
    if typeSize.isAccessibilitySize {
      stacked
    } else {
      ViewThatFits(in: .horizontal) {
        HStack(alignment: alignment, spacing: 0) {
          leading
          Spacer(minLength: spacing)
          trailing
        }
        .environment(\.reflowingRowStacked, false)
        stacked
      }
    }
  }

  private var stacked: some View {
    VStack(alignment: .leading, spacing: 4) {
      leading
      trailing
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .environment(\.reflowingRowStacked, true)
  }
}

public extension EnvironmentValues {
  @Entry var reflowingRowStacked = false
}

