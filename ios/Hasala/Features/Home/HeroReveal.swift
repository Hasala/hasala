import HasalaDesign
import QuartzCore
import SwiftUI

struct HeroReveal: ViewModifier {
  @Binding var phase: PaceFillPhase
  let target: Double
  let policy: MotionPolicy
  @State private var shown = false

  private static var played = false

  struct Schedule: Equatable {
    var tick: Double
    var verdict: Double
    var end: Double
  }

  static let schedule = Schedule(
    tick: HMotion.fill, verdict: HMotion.fill + HMotion.marker,
    end: HMotion.fill + HMotion.marker + HMotion.verdict)

  func body(content: Content) -> some View {
    content
      .onAppear(perform: appear)
      .onChange(of: target) { _, new in
        guard shown else { return }
        withAnimation(policy.animation(.fillUpdate)) { phase = .settled(new) }
      }
  }

  private func appear() {
    guard !shown else { return }
    shown = true
    let plays = !Self.played && !policy.isStill && target > 0
    Self.played = true
    guard plays else {
      phase = .settled(target)
      return
    }
    phase = PaceFillPhase()
    DisplayFrame.next { [target, policy, phase = $phase] in
      guard !phase.wrappedValue.started else { return }
      let schedule = Self.schedule
      withAnimation(policy.animation(.fill)) { phase.wrappedValue.fill = target }
      withAnimation(policy.animation(.marker)?.delay(schedule.tick)) {
        phase.wrappedValue.tickVisible = true
      }
      withAnimation(policy.animation(.verdict)?.delay(schedule.verdict)) {
        phase.wrappedValue.verdictVisible = true
      }
    }
  }
}

extension View {
  func heroReveal(_ phase: Binding<PaceFillPhase>, target: Double, policy: MotionPolicy) -> some View {
    modifier(HeroReveal(phase: phase, target: target, policy: policy))
  }
}

enum DisplayFrame {
  static func next(_ action: @escaping @MainActor () -> Void) {
    FrameWaiter(action).start()
  }
}

private final class FrameWaiter: NSObject {
  private let action: @MainActor () -> Void

  init(_ action: @escaping @MainActor () -> Void) {
    self.action = action
  }

  func start() {
    CADisplayLink(target: self, selector: #selector(frame(_:))).add(to: .main, forMode: .common)
  }

  @objc private func frame(_ link: CADisplayLink) {
    link.invalidate()
    action()
  }
}
