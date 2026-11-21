import HasalaDesign
import HasalaModels
import SwiftUI

struct PathGlyph: View {
  let paths: [String]
  let size: CGFloat
  let color: Color
  let stroke: CGFloat

  init(_ paths: [String], size: CGFloat, color: Color, stroke: CGFloat) {
    self.paths = paths
    self.size = size
    self.color = color
    self.stroke = stroke
  }

  var body: some View {
    let parsed = paths.compactMap { try? SVGPath(parsing: $0) }
    Canvas { context, canvasSize in
      let box = CGRect(origin: .zero, size: canvasSize)
      let unit = min(canvasSize.width, canvasSize.height) / 24
      for svg in parsed {
        context.stroke(svg.path(in: box), with: .color(color),
                       style: StrokeStyle(lineWidth: stroke * unit, lineCap: .round, lineJoin: .round))
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }

  static func arrow(_ edge: SwipeEdge) -> [String] {
    switch edge {
    case .left: ["M19 12H5.5M11 5.5 4.5 12l6.5 6.5"]
    case .right: ["M5 12h13.5M13 5.5l6.5 6.5-6.5 6.5"]
    case .up: ["M12 19V5.5M5.5 11 12 4.5l6.5 6.5"]
    case .down: ["M12 5v13.5M5.5 13l6.5 6.5 6.5-6.5"]
    }
  }

  static let noteLines = ["M5 6.5h14M5 11.5h14M5 16.5h8.5"]
  static let envelope = ["M6 5.5h12a2.5 2.5 0 0 1 2.5 2.5v8a2.5 2.5 0 0 1-2.5 2.5H6A2.5 2.5 0 0 1 3.5 16V8A2.5 2.5 0 0 1 6 5.5Z",
                         "M4.5 7.5 12 13l7.5-5.5"]
}

struct MerchantMonogram: View {
  let letter: String
  let size: CGFloat
  var ring = true

  var body: some View {
    Circle()
      .fill(HColor.listRowMonogram)
      .overlay { if ring { Circle().strokeBorder(HColor.borderSubtle, lineWidth: 1) } }
      .frame(width: size, height: size)
      .overlay {
        if letter.isEmpty {
          HIconView(.shopping, size: size * 0.45, color: HColor.iconSecondary)
        } else {
          Text(verbatim: letter)
            .font(.custom(HWeight.semibold.interFace, size: size >= 56 ? 24 : (size >= 32 ? 14 : 11),
                          relativeTo: size >= 56 ? .title2 : .subheadline))
            .foregroundStyle(HColor.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.3)
            .padding(size * 0.12)
            .frame(width: size, height: size)
        }
      }
      .accessibilityHidden(true)
  }
}

struct CardStackArt: View {
  var body: some View {
    ZStack(alignment: .topLeading) {
      card.opacity(0.7)
        .rotationEffect(.degrees(8), anchor: .topLeading)
        .offset(x: 14, y: 0)
      card
        .rotationEffect(.degrees(-4), anchor: .topLeading)
        .offset(x: 8, y: 6)
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(HColor.white)
        .frame(width: 52, height: 44)
        .shadow(color: .black.opacity(0.14), radius: 4, y: 2)
        .overlay(alignment: .leading) {
          VStack(alignment: .leading, spacing: 4) {
            Capsule().fill(Color(HRGBA(0xC9, 0xC9, 0xCF, 1))).frame(width: 22, height: 4)
            Capsule().fill(HColor.textPrimary).frame(width: 30, height: 6)
          }
          .padding(.leading, 8)
        }
        .offset(x: 10, y: 12)
    }
    .frame(width: 72, height: 60, alignment: .topLeading)
    .accessibilityHidden(true)
  }

  private var card: some View {
    RoundedRectangle(cornerRadius: 10, style: .continuous)
      .fill(HColor.white)
      .frame(width: 52, height: 44)
      .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
  }
}

struct ReviewDeckArt: View {
  var body: some View {
    ZStack(alignment: .topLeading) {
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .fill(Hue.sky.perceptualGradient)
      mini(fill: HColor.posterGlyph, bars: (Color(HRGBA(0x1E, 0x2A, 0x5E, 0.16)), Color(HRGBA(0x1E, 0x2A, 0x5E, 0.12)))) {
        Circle().fill(Hue.sand.perceptualGradient).frame(width: 20, height: 20)
          .overlay { HIconView(.transport, size: 12, color: Hue.sand.ink, strokeWidth: 2.4) }
      }
        .shadow(color: Color(HRGBA(0x1E, 0x2A, 0x5E, 0.10)), radius: 1.5, y: 1)
        .rotationEffect(.degrees(-22), anchor: .topLeading)
        .offset(x: 7, y: 8)
      mini(fill: HColor.surfacePrimary, bars: (HColor.neutral200, HColor.neutral100)) {
        MerchantMonogram(letter: "L", size: 20)
      }
        .shadow(color: Color(HRGBA(0x1E, 0x2A, 0x5E, 0.12)), radius: 1, y: 1)
        .shadow(color: Color(HRGBA(0x1E, 0x2A, 0x5E, 0.14)), radius: 5, y: 4)
        .rotationEffect(.degrees(15), anchor: .topLeading)
        .offset(x: 32, y: 20)
    }
    .frame(width: 72, height: 72)
    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    .accessibilityHidden(true)
  }

  private func mini<Top: View>(fill: Color, bars: (Color, Color), @ViewBuilder top: () -> Top) -> some View {
    VStack(spacing: 5) {
      top()
      Capsule().fill(bars.0).frame(width: 18, height: 3)
      Capsule().fill(bars.1).frame(width: 12, height: 3)
    }
    .padding(.top, 6)
    .frame(width: 34, height: 44, alignment: .top)
    .background(fill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
  }
}
