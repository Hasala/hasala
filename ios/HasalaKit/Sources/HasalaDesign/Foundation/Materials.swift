import HasalaModels
import SwiftUI

struct GlassModifier<S: Shape>: ViewModifier {
  let shape: S
  let prominent: Bool
  let interactive: Bool
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.hGlassPaired) private var paired
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.hIncreasedContrast) private var forcedContrast

  func body(content: Content) -> some View {
    if paired {
      content
    } else if reduceTransparency {
      content
        .background(prominent ? HColor.actionAccent : HColor.materialGlassReduced, in: shape)
        .overlay {
          if HContrastEdge.isShown(contrast: contrast, forced: forcedContrast) {
            shape.stroke(HContrastEdge.color, lineWidth: HContrastEdge.width)
          } else {
            shape.stroke(HColor.materialGlassOutline, lineWidth: HSpacing.strokeHairline)
          }
        }
    } else {
      content.glassEffect(glass, in: shape)
    }
  }

  private var glass: Glass {
    let base: Glass = prominent ? .regular.tint(HColor.actionAccent) : .regular
    return interactive ? base.interactive() : base
  }
}

extension EnvironmentValues {
  @Entry var hGlassPaired = false
}

public enum HElevation: Sendable, Hashable {
  case near
  case nearFar
}

public extension View {
  func hGlass<S: Shape>(in shape: S, prominent: Bool = false, interactive: Bool = true) -> some View {
    modifier(GlassModifier(shape: shape, prominent: prominent, interactive: interactive))
  }

  func hElevation(_ level: HElevation) -> some View {
    shadow(color: HColor.elevationNear, radius: 1, x: 0, y: 1)
      .shadow(color: level == .nearFar ? HColor.elevationFar : .clear, radius: 12, x: 0, y: 8)
  }
}

public enum HWash: Sendable, Hashable {
  case onTrack
  case overPace
  case overBudget
  case hue(Hue)
  case setup
  case itWorks
  case ready
  case welcome
  case notifications

  public init(verdict: Verdict) {
    switch verdict {
    case .onTrack, .done: self = .onTrack
    case .overPace: self = .overPace
    case .overBudget: self = .overBudget
    }
  }

  public var height: CGFloat {
    switch self {
    case .onTrack, .overPace, .overBudget, .hue: 420
    case .setup: 360
    case .itWorks, .ready, .notifications: 480
    case .welcome: 560
    }
  }

  public var stops: [(color: HRGBA, location: CGFloat)] {
    switch self {
    case .onTrack: Self.recipe(HPalette.washOnTrack)
    case .overPace: Self.recipe(HPalette.washOverPace)
    case .overBudget: Self.recipe(HPalette.washOverBudget)
    case .hue(let hue):
      switch hue {
      case .sky: Self.recipe(HPalette.washOnTrack)
      case .sand: Self.recipe(HPalette.washOverPace)
      case .rose: Self.recipe(HPalette.washOverBudget)
      default: Self.recipe(hue.tokens.start)
      }
    case .setup: Self.recipe(HPalette.washMorning)
    case .itWorks, .ready:
      [(HPalette.hueMintStart, 0), (HPalette.hueSkyStart, 0.46), (HPalette.hueSkyStart.clear, 1)]
    case .welcome:
      [(HPalette.washMorning, 0), (HPalette.hueSkyStart, 0.45), (HPalette.hueSkyStart.clear, 1)]
    case .notifications:
      [(HPalette.washMorning, 0), (HPalette.hueSkyStart, 0.46), (HPalette.hueSkyStart.clear, 1)]
    }
  }

  public var top: HRGBA { stops[0].color }

  static func recipe(_ wash: HRGBA) -> [(color: HRGBA, location: CGFloat)] {
    [(wash, 0), (wash.withOpacity(0.5), 0.38), (wash.clear, 1)]
  }
}

extension HRGBA {
  func withOpacity(_ opacity: Double) -> HRGBA { HRGBA(red, green, blue, opacity) }
  var clear: HRGBA { withOpacity(0) }
}
