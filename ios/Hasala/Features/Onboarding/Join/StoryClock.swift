import Foundation
import HasalaDesign

struct StoryClock: Equatable, Sendable {
  static let duration = HMotion.storyDuration

  private(set) var banked: TimeInterval = 0
  private(set) var runningSince: Date?

  var isRunning: Bool { runningSince != nil }

  func progress(at now: Date) -> Double {
    min(1, max(0, played(at: now) / Self.duration))
  }

  func remaining(at now: Date) -> TimeInterval {
    max(0, Self.duration - played(at: now))
  }

  private func played(at now: Date) -> TimeInterval {
    banked + (runningSince.map { max(0, now.timeIntervalSince($0)) } ?? 0)
  }

  mutating func resume(at now: Date) {
    guard runningSince == nil, banked < Self.duration else { return }
    runningSince = now
  }

  mutating func pause(at now: Date) {
    guard runningSince != nil else { return }
    banked = min(Self.duration, played(at: now))
    runningSince = nil
  }

  mutating func restart(at now: Date, running: Bool) {
    banked = 0
    runningSince = running ? now : nil
  }

  mutating func finish() {
    banked = Self.duration
    runningSince = nil
  }
}
