import HasalaDesign
import HasalaModels
import SwiftUI

struct PhraseText: View {
  let phrase: MoneyPhrase
  let hidden: Bool

  init(_ phrase: MoneyPhrase, hidden: Bool) {
    self.phrase = phrase
    self.hidden = hidden
  }

  var body: some View {
    Text(phrase.rendered(hidden: hidden))
      .accessibilityLabel(phrase.spoken(hidden: hidden))
  }
}

struct SectionTitle: View {
  let title: String
  var note: String?
  var count: Int?
  var actionTitle: String?
  var action: (() -> Void)?

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      HStack(spacing: 8) {
        Text(title).hType(.section).foregroundStyle(HColor.textPrimary).accessibilityAddTraits(.isHeader)
        if let count { CountBadge(count).accessibilityLabel("\(count) items") }
      }
      Spacer(minLength: 8)
      if let actionTitle {
        Button(actionTitle) { action?() }
          .buttonStyle(.plain)
          .hType(.body.weight(.medium))
          .foregroundStyle(HColor.textLink)
      } else if let note {
        Text(note).hType(.subheadline).foregroundStyle(HColor.textSecondary)
      }
    }
  }
}

struct SheetCloseButton: ToolbarContent {
  let identifier: String
  let action: () -> Void

  var body: some ToolbarContent {
    ToolbarItem(placement: .topBarLeading) {
      Button(role: .close, action: action)
        .tint(HColor.iconGlass)
        .accessibilityIdentifier(identifier)
    }
  }
}

struct MonthPill: View {
  let month: YearMonth

  var body: some View {
    HStack(spacing: 4) {
      Text(month.title).hType(.subheadline.weight(.semibold))
      if BuildSurface.showsUnfinished {
        Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold)).accessibilityHidden(true)
      }
    }
    .foregroundStyle(HColor.textPrimary)
    .modifier(MonthPillChrome(isPicker: Self.isPicker))
    .accessibilityElement(children: .combine)
  }

  static var isPicker: Bool { BuildSurface.showsUnfinished }
}

private struct MonthPillChrome: ViewModifier {
  let isPicker: Bool

  func body(content: Content) -> some View {
    if isPicker {
      content
        .padding(.horizontal, 14)
        .frame(minHeight: 36)
        .background(HColor.surfacePrimary, in: Capsule())
        .shadow(color: HColor.elevationNear, radius: 1, x: 0, y: 1)
        .hContrastEdge(Capsule())
    } else {
      content
    }
  }
}

struct EmptyNote: View {
  let systemImage: String
  let message: String

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: systemImage).foregroundStyle(HColor.iconSecondary).accessibilityHidden(true)
      Text(message).hType(.subheadline).foregroundStyle(HColor.textSecondary)
      Spacer(minLength: 0)
    }
    .padding(HSpacing.md)
    .listCard()
  }
}

extension Bucket {
  var label: String {
    switch self {
    case .needs: "Needs"
    case .wants: "Wants"
    case .savings: "Savings"
    case .income: "Income"
    case .project: "Projects"
    case .other: "Not spending"
    }
  }
}

nonisolated enum WashPin {
  static func offset(contentOffset: CGFloat, insetTop: CGFloat) -> CGFloat {
    -max(0, contentOffset + insetTop)
  }
}

extension View {
  func washBehind(_ wash: HWash) -> some View {
    modifier(WashBehind(wash: wash))
  }
}

private struct WashBehind: ViewModifier {
  let wash: HWash
  @State private var offset: CGFloat = 0

  func body(content: Content) -> some View {
    content
      .onScrollGeometryChange(for: CGFloat.self) { geo in
        WashPin.offset(contentOffset: geo.contentOffset.y, insetTop: geo.contentInsets.top)
      } action: { _, value in
        offset = value
      }
      .background(alignment: .top) {
        AmbientWash(wash).offset(y: offset).ignoresSafeArea(edges: .top)
      }
  }
}
