import HasalaModels
import SwiftUI

public struct AmbientWash: View {
  let wash: HWash
  let height: CGFloat
  @ResolvedMotion private var motion: MotionPolicy

  public init(_ wash: HWash, height: CGFloat? = nil) {
    self.wash = wash
    self.height = height ?? wash.height
  }

  public var body: some View {
    ZStack {
      WashLayer(wash: wash)
        .id(wash)
        .transition(.opacity)
    }
    .frame(height: height)
    .frame(maxWidth: .infinity)
    .animation(motion.animation(.stateSwap), value: wash)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

struct WashLayer: View {
  let wash: HWash

  var body: some View {
    let gradient = Gradient(stops: wash.stops.map { Gradient.Stop(color: Color($0.color), location: $0.location) })
    Rectangle().fill(.linearGradient(gradient.colorSpace(.perceptual), startPoint: .top, endPoint: .bottom))
  }
}
