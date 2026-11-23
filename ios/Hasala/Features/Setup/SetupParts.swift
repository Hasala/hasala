import HasalaDesign
import HasalaModels
import SwiftUI

struct SetupScreen<Content: View, Dock: View>: View {
  enum Layout { case fill, scroll }

  var title: String
  var subtitle: String?
  var steps: (current: Int, of: Int)?
  var back: AccountBack = .none
  var trailing: (title: String, action: () -> Void)?
  var wash: HWash = .setup
  var layout: Layout = .scroll
  var top: CGFloat = 16
  @ViewBuilder var content: () -> Content
  @ViewBuilder var dock: () -> Dock

  var body: some View {
    GeometryReader { viewport in
      ScrollView {
        switch layout {
        case .fill:
          FillOrGrow(minHeight: viewport.size.height) { column(filling: true) }
        case .scroll:
          column(filling: false).padding(.bottom, 16)
        }
      }
      .scrollBounceBehavior(.basedOnSize)
      .scrollEdgeEffectStyle(.soft, for: .bottom)
    }
    .safeAreaBar(edge: .bottom) { dock() }
    .background(alignment: .top) {
      AmbientWash(wash).ignoresSafeArea(edges: .top)
    }
    .background(HColor.surfaceSecondary)
    .accountHeader(steps: steps, back: back, trailing: trailing)
  }

  private func column(filling: Bool) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      SetupQuestion(title: title, subtitle: subtitle)
        .padding(.horizontal, HSpacing.insetPage)
        .padding(.top, top)
      content()
        .frame(maxWidth: .infinity, maxHeight: filling ? .infinity : nil)
    }
  }
}

private struct FillOrGrow: Layout {
  var minHeight: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard let child = subviews.first else { return .zero }
    let natural = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
    return CGSize(width: proposal.width ?? natural.width, height: max(minHeight, natural.height))
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
  }
}

struct SetupQuestion: View {
  let title: String
  let subtitle: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .hType(.title1)
        .foregroundStyle(HColor.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
      if let subtitle {
        Text(subtitle)
          .hType(.body)
          .foregroundStyle(HColor.textOnWashSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct DockNote: View {
  var icon: HIcon = .lock
  var text: String

  @ScaledMetric(relativeTo: .subheadline) private var lane: CGFloat = 20

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      HIconView(icon, size: 16, color: HColor.textSecondary, strokeWidth: 2).frame(height: lane)
      Text(text)
        .hType(.subheadline)
        .foregroundStyle(HColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 8)
    .accessibilityElement(children: .combine)
  }
}

struct SetupFailureBanner: View {
  var failure: SetupFailure?

  var body: some View {
    if let message = failure?.message, !message.isEmpty {
      FailureBanner(failure: .badPhrase(message))
    }
  }
}
