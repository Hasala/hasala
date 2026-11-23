import SwiftUI

public enum HHaptic: Sendable, Hashable, CaseIterable {
  case selection
  case impactLight
  case impactRigid
  case keyTick
  case success

  public var feedback: SensoryFeedback {
    switch self {
    case .selection: .selection
    case .impactLight: .impact(weight: .light)
    case .impactRigid: .impact(flexibility: .rigid)
    case .keyTick: .impact(weight: .light, intensity: 0.5)
    case .success: .success
    }
  }
}

public extension View {
  func hHaptic<T: Equatable>(_ kind: HHaptic, trigger: T) -> some View {
    sensoryFeedback(kind.feedback, trigger: trigger)
  }

  func hHaptic<T: Equatable>(_ kind: HHaptic, trigger: T, condition: @escaping (T, T) -> Bool) -> some View {
    sensoryFeedback(kind.feedback, trigger: trigger, condition: condition)
  }
}
