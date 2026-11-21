#if HASALA_MOCKS
  import HasalaDesign
  import QuartzCore
  import SwiftUI

  struct RevealTimingProbe: ViewModifier {
    static let argument = "-HasalaRevealTiming"
    private static let enabled = ProcessInfo.processInfo.arguments.contains(argument)

    let phase: PaceFillPhase
    let target: Double
    @State private var log = RevealFrameLog()

    func body(content: Content) -> some View {
      if Self.enabled {
        content
          .background(alignment: .topLeading) {
            HStack(spacing: 0) {
              FrameSampler(value: phase.fill) { log.fill($0, target: target) }
              FrameSampler(value: phase.tickVisible ? 1 : 0) { log.tick($0) }
              FrameSampler(value: phase.verdictVisible ? 1 : 0) { log.verdict($0) }
            }
            .accessibilityHidden(true)
          }
          .overlay(alignment: .topLeading) {
            Color.clear.frame(width: 1, height: 1)
              .accessibilityElement()
              .accessibilityLabel("Reveal timing")
              .accessibilityValue(log.summary)
              .accessibilityIdentifier("home.hero.revealTiming")
          }
      } else {
        content
      }
    }
  }

  private struct FrameSampler: View, Animatable {
    var value: Double
    let record: (Double) -> Void

    nonisolated var animatableData: Double {
      get { value }
      set { value = newValue }
    }

    var body: some View {
      record(value)
      return Color.clear.frame(width: 1, height: 1)
    }
  }

  @MainActor @Observable
  private final class RevealFrameLog {
    private(set) var summary = ""
    @ObservationIgnored private var start: CFTimeInterval?
    @ObservationIgnored private var marks: [(String, CFTimeInterval)] = []
    @ObservationIgnored private var finished = false

    func fill(_ value: Double, target: Double) {
      guard !finished else { return }
      let now = CACurrentMediaTime()
      guard value > 0 else { return }
      if start == nil {
        guard value < target - 0.0005 else { return publish("settled") }
        start = now - Self.fillElapsed(share: value / target)
      }
      if value >= target - 0.0005 { mark("filled", now) }
    }

    static func fillElapsed(share: Double) -> Double {
      var low = 0.0, high = 1.0
      for _ in 0..<40 {
        let s = (low + high) / 2
        if 3 * s * s - 2 * s * s * s < share { low = s } else { high = s }
      }
      let s = (low + high) / 2
      let x = 3 * (1 - s) * (1 - s) * s * 0.65 + 3 * (1 - s) * s * s * 0.35 + s * s * s
      return x * HMotion.fill
    }

    func tick(_ value: Double) {
      if value > 0 { mark("tick", CACurrentMediaTime()) }
    }

    func verdict(_ value: Double) {
      let now = CACurrentMediaTime()
      if value > 0 { mark("verdict", now) }
      guard value >= 0.999, let start, !finished else { return }
      mark("done", now)
      let text = (["fill 0"] + marks.map { "\($0.0) \(Int((($0.1 - start) * 1000).rounded()))" })
        .joined(separator: ", ")
      publish(text)
    }

    private func mark(_ name: String, _ time: CFTimeInterval) {
      guard start != nil, !finished, !marks.contains(where: { $0.0 == name }) else { return }
      marks.append((name, time))
    }

    private func publish(_ text: String) {
      finished = true
      Task { @MainActor in self.summary = text }
    }
  }
#endif
