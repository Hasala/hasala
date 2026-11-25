import HasalaDesign
import HasalaModels
import SwiftUI
import UIKit

struct RulesPage: View {
  enum Segment: Hashable { case categories, rules }

  @Bindable var app: AppModel
  let model: any ProfileModel
  @State private var segment: Segment

  init(app: AppModel, model: any ProfileModel, startOn segment: Segment = .rules) {
    self.app = app
    self.model = model
    _segment = State(initialValue: segment)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        HSegmentedControl([Segment.categories, .rules], selection: $segment) { $0 == .categories ? "Categories" : "Rules" }
          .accessibilityIdentifier("rules.segment")
        switch segment {
        case .rules: rules
        case .categories: CategoriesList(app: app)
        }
      }
      .padding(.horizontal, HSpacing.sheetPadding)
      .padding(.top, 8)
      .padding(.bottom, 48)
    }
    .scrollEdgeEffectStyle(.soft, for: .bottom)
    .background(HColor.sheetSurfaceLarge)
    .navigationTitle("Categories and rules")
    .navigationBarTitleDisplayMode(.inline)
  }

  private var rules: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Pausing a rule sends its transactions back to Review.")
        .hType(.subheadline)
        .foregroundStyle(HColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 4)
      let rules = model.rules
      if rules.isEmpty {
        EmptyNote(systemImage: "list.bullet", message: "No rules yet. Turn on Always use it when you sort.")
          .accessibilityIdentifier("rules.empty")
      } else {
        VStack(alignment: .leading, spacing: 8) {
          OverlineHeader("Most used")
          if rules.count > Self.lazyFrom {
            LazyVStack(spacing: 0) { ruleRows(rules) }
              .frame(maxWidth: .infinity)
              .background(HColor.listRowSurface)
              .clipShape(RoundedRectangle(cornerRadius: HRadius.listGroup, style: .continuous))
          } else {
            HListCard { ruleRows(rules) }
          }
        }
      }
    }
  }

  private static let lazyFrom = 40

  private func ruleRows(_ rules: [RuleRowModel]) -> some View {
    ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
      if index > 0 { HDivider(inset: .disc68) }
      RuleRow(rule: rule, enabled: Binding(get: { rule.enabled }, set: { model.setRule(rule.id, enabled: $0) }))
    }
  }
}

private struct RuleRow: View {
  let rule: RuleRowModel
  @Binding var enabled: Bool
  @Environment(\.dynamicTypeSize) private var typeSize
  @ScaledMetric(relativeTo: HType.rowTitle.textStyle) private var titleSize = HType.rowTitle.size
  @Environment(\.legibilityWeight) private var legibilityWeight
  @State private var width = CGFloat.infinity

  var body: some View {
    Toggle(isOn: $enabled) {
      let layout = typeSize.isAccessibilitySize
        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
        : AnyLayout(HStackLayout(spacing: HSpacing.listRowGap))
      layout {
        HuePlate(hue: rule.hue, icon: rule.glyph.icon)
        VStack(alignment: .leading, spacing: 2) {
          title
          MatchLine(rule: rule)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
      }
    }
    .tint(HColor.controlSwitchTrackOn)
    .padding(.horizontal, HSpacing.listRowInsetInline)
    .padding(.vertical, HSpacing.listRowInsetBlock)
    .frame(minHeight: HSpacing.listRowMinHeightTwoLine)
    .accessibilityLabel(spoken)
    .accessibilityIdentifier("rule.\(rule.id)")
  }

  @ViewBuilder private var title: some View {
    let pattern = Text(patternLine).hType(.rowTitle).foregroundStyle(HColor.listRowTitle)
      .lineLimit(2)
    if rule.learnedToday {
      let chip = StatusPillView(StatusPill("Learned today", tone: .accent, showsDot: false), size: .s22,
                                surface: .tinted)
      let stacked = VStack(alignment: .leading, spacing: 4) { pattern; chip }
      if typeSize.isAccessibilitySize {
        stacked
      } else {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 8) { pattern; chip }
          stacked
        }
      }
    } else {
      pattern
    }
  }

  private var patternLine: String {
    let count = rule.patterns.count
    guard count > 1, width.isFinite, width > 0 else { return rule.pattern }
    let type = HType.rowTitle
    let weight = legibilityWeight == .bold ? type.weight.bolder : type.weight
    let font = UIFont(name: weight.interFace, size: titleSize) ?? .systemFont(ofSize: titleSize)
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .kern: type.resolvedTracking * titleSize / type.size]
    let bounds = CGSize(width: width, height: .greatestFiniteMagnitude)
    func height(_ s: String) -> CGFloat {
      (s as NSString).boundingRect(with: bounds, options: .usesLineFragmentOrigin, attributes: attributes, context: nil)
        .height.rounded(.up)
    }
    let limit = height("A\nA")
    for shown in stride(from: count, to: 1, by: -1) where height(rule.patternLine(showing: shown)) <= limit {
      return rule.patternLine(showing: shown)
    }
    return rule.patternLine(showing: 1)
  }

  private var spoken: String {
    let pattern = rule.pattern.replacingOccurrences(of: "\u{201C}", with: "")
      .replacingOccurrences(of: "\u{201D}", with: "")
    return [pattern, rule.learnedToday ? "learned today" : nil, rule.detail].compactMap { $0 }
      .joined(separator: ", ")
  }
}

private struct MatchLine: View {
  let rule: RuleRowModel
  @ScaledMetric(relativeTo: HType.footnote.textStyle) private var size = HType.footnote.size
  @Environment(\.legibilityWeight) private var legibilityWeight
  @State private var width = CGFloat.infinity

  var body: some View {
    Text(fits ? rule.detail : "\(rule.match)\n\(rule.matchesLabel)")
      .hType(.footnote)
      .foregroundStyle(HColor.listRowSupporting)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
  }

  private var fits: Bool {
    let type = HType.footnote
    let weight = legibilityWeight == .bold ? type.weight.bolder : type.weight
    let font = UIFont(name: weight.interFace, size: size) ?? .systemFont(ofSize: size)
    let tracking = type.resolvedTracking * size / type.size
    let measured = (rule.detail as NSString).size(withAttributes: [.font: font, .kern: tracking]).width
    return measured.rounded(.up) <= width
  }
}
