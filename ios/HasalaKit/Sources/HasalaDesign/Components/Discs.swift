import HasalaModels
import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

public enum DiscScale {
  public static let cap: CGFloat = 1.5

  public static func factor(_ scaledOne: CGFloat) -> CGFloat {
    min(max(1, scaledOne), cap)
  }
}

public struct CategoryDisc: View {
  public enum Size: Sendable {
    case s32, s40, s56

    public var side: CGFloat {
      switch self {
      case .s32: 32
      case .s40: HSpacing.listRowLeadingDisc
      case .s56: 56
      }
    }
  }

  let hue: Hue
  let icon: HIcon
  let size: Size
  let ring: Bool
  @ScaledMetric(relativeTo: .callout) private var scaledOne: CGFloat = 1

  public init(hue: Hue, icon: HIcon, size: Size = .s40, ring: Bool = false) {
    self.hue = hue
    self.icon = icon
    self.size = size
    self.ring = ring
  }

  public init(hue: Hue, glyph: Glyph, size: Size = .s40, ring: Bool = false) {
    self.init(hue: hue, icon: glyph.icon, size: size, ring: ring)
  }

  public var body: some View {
    let side = size.side * DiscScale.factor(scaledOne)
    Circle()
      .fill(hue.perceptualGradient)
      .frame(width: side, height: side)
      .overlay { HIconView(icon, size: side / 2, color: hue.ink) }
      .background { if ring { Circle().fill(HColor.white).padding(-3) } }
      .accessibilityHidden(true)
  }
}

public struct HueDisc: View {
  let hue: Hue
  let glyph: Glyph
  let size: CGFloat
  let iconSize: CGFloat
  @ScaledMetric(relativeTo: .callout) private var scaledOne: CGFloat = 1

  public init(hue: Hue, glyph: Glyph, size: CGFloat = HSpacing.listRowLeadingDisc, iconSize: CGFloat? = nil) {
    self.hue = hue
    self.glyph = glyph
    self.size = size
    self.iconSize = iconSize ?? (size / 2).rounded()
  }

  public var body: some View {
    let k = DiscScale.factor(scaledOne)
    Circle()
      .fill(hue.perceptualGradient)
      .frame(width: size * k, height: size * k)
      .overlay { HIconView(glyph.icon, size: iconSize * k, color: hue.ink) }
      .accessibilityHidden(true)
  }
}

public struct MonogramDisc: View {
  let letter: String
  let size: CGFloat
  @ScaledMetric(relativeTo: .callout) private var scaledOne: CGFloat = 1

  public init(_ letter: String, size: CGFloat = HSpacing.listRowLeadingDisc) {
    self.letter = letter
    self.size = size
  }

  public var body: some View {
    Circle()
      .fill(HColor.listRowMonogram)
      .overlay { Circle().strokeBorder(HColor.borderSubtle, lineWidth: 1) }
      .frame(width: size * DiscScale.factor(scaledOne), height: size * DiscScale.factor(scaledOne))
      .overlay {
        Text(letter)
          .font(.custom(HWeight.semibold.interFace, fixedSize: (size >= 56 ? 24 : size * 17 / 40) * DiscScale.factor(scaledOne)))
          .foregroundStyle(HColor.textPrimary)
          .accessibilityIdentifier(hasalaCappedFigureIdentifier)
      }
      .accessibilityHidden(true)
  }
}

public struct BankPlate: View {
  let initials: String
  let hue: Hue

  public init(initials: String, hue: Hue) {
    self.initials = initials
    self.hue = hue
  }

  public var body: some View {
    let long = initials.count > 3
    let mark = Text(verbatim: initials)
      .font(.custom(HWeight.bold.interFace, fixedSize: long ? 11 : 12))
      .tracking(long ? -0.2 : 0.2)
      .foregroundStyle(hue.ink)
    RoundedRectangle(cornerRadius: 12, style: .continuous)
      .fill(hue.perceptualGradient)
      .frame(width: 40, height: 40)
      .overlay {
        Canvas { context, size in
          let text = context.resolve(mark)
          let room = size.width - 6
          let measured = text.measure(in: CGSize(width: CGFloat.infinity, height: size.height))
          let scale = measured.width > room ? room / measured.width : 1
          context.translateBy(x: size.width / 2, y: size.height / 2)
          context.scaleBy(x: scale, y: scale)
          context.draw(text, at: .zero, anchor: .center)
        }
      }
      .accessibilityHidden(true)
  }
}

public struct GlyphPlate: View {
  let icon: HIcon
  let hue: Hue
  let size: CGFloat

  public init(icon: HIcon, hue: Hue, size: CGFloat = 32) {
    self.icon = icon
    self.hue = hue
    self.size = size
  }

  public var body: some View {
    Circle()
      .fill(HColor.posterGlyph)
      .frame(width: size, height: size)
      .overlay {
        HIconView(icon, size: size <= 32 ? (size * 18 / 32).rounded() : size / 2, color: hue.ink,
                  strokeWidth: size <= 32 ? 2 : nil)
      }
      .accessibilityHidden(true)
  }
}

public struct AvatarDisc: View {
  let initial: String
  let size: CGFloat
  let ring: Bool
  let email: String?

  @Environment(\.avatarPictures) private var pictures
  @Environment(\.displayScale) private var displayScale
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var picture: AvatarPicture?

  public init(initial: String, size: CGFloat = 36, ring: Bool = false, email: String? = nil) {
    self.initial = initial
    self.size = size
    self.ring = ring
    self.email = email
  }

  private var pixels: Int { max(1, Int((size * displayScale).rounded(.up))) }

  static let gradientStops: [(color: HRGBA, location: Double)] = [
    (HRGBA(246, 182, 107, 1), 0),
    (HRGBA(232, 152, 138, 1), 0.55),
    (HRGBA(140, 107, 184, 1), 1),
  ]
  static let gradientSpace = Gradient.ColorSpace.perceptual
  static let gradientStart = UnitPoint(x: 0.2, y: 0)
  static let gradientEnd = UnitPoint(x: 0.8, y: 1)

  static var gradient: some ShapeStyle {
    let stops = gradientStops.map { Gradient.Stop(color: Color($0.color), location: $0.location) }
    return .linearGradient(Gradient(stops: stops).colorSpace(gradientSpace), startPoint: gradientStart,
                           endPoint: gradientEnd)
  }

  public var body: some View {
    Circle()
      .fill(Self.gradient)
      .frame(width: size, height: size)
      .overlay {
        Text(initial)
          .font(.custom(HWeight.bold.interFace, fixedSize: size <= 48 ? size * 16 / 36 : size * 40 / 96))
          .foregroundStyle(Color(HRGBA(42, 31, 61, 1)))
      }
      .overlay {
        if let picture = picture?.shown(for: email) {
          picture.image
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(Circle())
            .transition(.opacity)
        }
      }
      .task(id: AvatarKey(email: email, pixels: pixels, enabled: pictures != nil)) {
        guard let pictures, let email, !email.isEmpty else {
          picture = nil
          return
        }
        let data = await pictures.load(email, pixels)
        guard !Task.isCancelled else { return }
        let loaded = data.flatMap { AvatarPicture(data: $0, email: email) }
        if reduceMotion {
          picture = loaded
        } else {
          withAnimation(.easeOut(duration: 0.2)) { picture = loaded }
        }
      }
      .background { if ring { Circle().fill(HColor.white).padding(-4) } }
      .shadow(color: ring ? HColor.elevationFar : .clear, radius: 12, x: 0, y: 8)
      .accessibilityHidden(true)
  }
}

private struct AvatarKey: Hashable {
  let email: String?
  let pixels: Int
  let enabled: Bool
}

struct AvatarPicture {
  let image: Image
  let email: String

  init(image: Image, email: String) {
    self.image = image
    self.email = email
  }

  init?(data: Data, email: String) {
    #if canImport(UIKit)
      guard let ui = UIImage(data: data) else { return nil }
      self.init(image: Image(uiImage: ui), email: email)
    #else
      return nil
    #endif
  }

  func shown(for current: String?) -> AvatarPicture? { email == current ? self : nil }
}

public struct AvatarPictureProvider: Sendable {
  public var load: @Sendable (_ email: String, _ pixels: Int) async -> Data?

  public init(load: @escaping @Sendable (_ email: String, _ pixels: Int) async -> Data?) {
    self.load = load
  }
}

public extension EnvironmentValues {
  @Entry var avatarPictures: AvatarPictureProvider? = nil
}
