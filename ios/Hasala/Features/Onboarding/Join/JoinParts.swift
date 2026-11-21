import HasalaDesign
import HasalaModels
import SwiftUI

struct JoinStatusLine: View {
  enum Tone { case success, error, warning }

  var text: String
  var tone: Tone

  @ScaledMetric(relativeTo: .subheadline) private var lane: CGFloat = 20

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Circle().fill(ink).frame(width: 7, height: 7).frame(height: lane)
      Text(text)
        .hType(.subheadline.weight(.medium))
        .foregroundStyle(ink)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("status.\(tone)")
  }

  private var ink: Color {
    switch tone {
    case .success: HColor.statusSuccessForeground
    case .error: HColor.statusErrorForeground
    case .warning: HColor.statusWarningForeground
    }
  }
}

struct ConfirmedChip: View {
  var body: some View {
    HStack(spacing: 6) {
      Circle().fill(HColor.statusSuccessForeground).frame(width: 7, height: 7)
      Text("Confirmed")
        .hType(.footnote.weight(.semibold))
        .foregroundStyle(HColor.statusSuccessForeground)
        .lineLimit(1)
    }
    .padding(.leading, 10)
    .padding(.trailing, 12)
    .frame(minHeight: 28)
    .background(HColor.statusSuccessSurface, in: Capsule())
    .fixedSize()
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("about.confirmed")
  }
}

struct GlyphNote: View {
  var icon: HIcon
  var text: String

  @ScaledMetric(relativeTo: .subheadline) private var lane: CGFloat = 20

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      HIconView(icon, size: 22, color: HColor.iconPrimary, strokeWidth: 1.8)
        .frame(height: max(22, lane))
      Text(text)
        .hType(.subheadline)
        .foregroundStyle(HColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(16)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.tile, style: .continuous))
    .accessibilityElement(children: .combine)
  }
}

struct NumberedStep: View {
  var number: Int
  var text: String

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Text("\(number)")
        .hFigure(HFigure(size: 14, leading: 18, weight: .bold, textStyle: .subheadline))
        .foregroundStyle(HColor.textPrimary)
        .frame(minWidth: 26, minHeight: 26)
        .background(Circle().fill(HColor.surfacePrimary))
        .overlay { Circle().strokeBorder(HColor.neutral300, lineWidth: 1.5) }
        .accessibilityHidden(true)
      Text(text)
        .hType(.subheadline)
        .foregroundStyle(HColor.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(number). \(text)")
  }
}

struct ReasonsCard: View {
  var reasons: [(title: String, detail: String)]
  var link: ReasonLink?

  struct ReasonLink {
    var row: Int
    var title: String
    var identifier: String
    var action: () -> Void
  }

  var body: some View {
    VStack(spacing: 0) {
      ForEach(Array(reasons.enumerated()), id: \.offset) { i, reason in
        if i > 0 {
          Rectangle().fill(HColor.borderSubtle).frame(height: 1).padding(.leading, 16)
        }
        let rowLink = link.flatMap { $0.row == i ? $0 : nil }
        VStack(alignment: .leading, spacing: 2) {
          VStack(alignment: .leading, spacing: 2) {
            Text(reason.title).hType(.rowTitle).foregroundStyle(HColor.textPrimary)
            Text(reason.detail)
              .hType(.subheadline)
              .foregroundStyle(HColor.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          .accessibilityElement(children: .combine)
          if let rowLink {
            Button(action: rowLink.action) {
              Text(rowLink.title)
                .hType(.subheadline.weight(.semibold))
                .foregroundStyle(HColor.textLink)
                .frame(minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, -6)
            .accessibilityIdentifier(rowLink.identifier)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .contain)
      }
    }
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
  }
}

struct WrappingTextField: View {
  var placeholder: String
  @Binding var text: String

  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    if typeSize.isAccessibilitySize {
      TextField(placeholder, text: oneLine, axis: .vertical)
        .lineLimit(1...4)
    } else {
      TextField(placeholder, text: $text)
    }
  }

  private var oneLine: Binding<String> {
    Binding(get: { text }, set: { text = $0.replacingOccurrences(of: "\n", with: "") })
  }
}
