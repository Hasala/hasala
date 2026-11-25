import CoreAuth
import CoreCrypto
import CoreSoftAuth
import CoreTestSupport
import Foundation
import Testing

@testable import CoreSync

extension Live {
  static func twoRuntimes(clock: FakeClock) async throws -> (Runtime, Runtime) {
    let email = try newEmail()
    let a = phone("live-a-\(email)", clock: clock)
    let made = try await passwordAccount(a, email: email)
    let b = phone("live-b-\(email)", clock: clock)
    let accountB = try await secondPhone(b, email: email, words: made.words)

    let ra = try Runtime(Enrolment.context(a.env, account: made.enrolled))
    let rb = try Runtime(Enrolment.context(b.env, account: accountB))
    try await ra.observer.open()
    try await rb.observer.open()
    return (ra, rb)
  }
}

@Suite("LiveSampleSeedTests", .enabled(if: Live.enabled), .serialized)
struct LiveSampleSeedTests {
  @Test("sample data loaded on A reaches B through hasalad")
  func sample() async throws {
    let (a, b) = try await Live.twoRuntimes(clock: FakeClock(ms: Scenarios.anchor))
    try await Scenarios.sampleOnSecondDevice(a, b) { review in
      let bearer = try #require(try a.context.secrets.session()).token
      if review { _ = try Live.sql("UPDATE users SET review_account = true WHERE id = '\(a.context.userID.string)'") }
      return try await a.context.client.account(bearer: bearer)
    }
  }
}

@Suite("LiveGmailToReplayTests", .enabled(if: Live.enabled), .serialized)
struct LiveGmailToReplayTests {
  @Test("Gmail alerts read on A reach B through hasalad")
  func gmail() async throws {
    let clock = FakeClock(ms: Scenarios.anchor)
    let (a, b) = try await Live.twoRuntimes(clock: clock)
    try await Scenarios.gmailToReplay(a, b, clock: clock)
  }
}

@Suite("LiveOutlookToReplayTests", .enabled(if: Live.enabled), .serialized)
struct LiveOutlookToReplayTests {
  @Test("Outlook alerts read on A reach B through hasalad")
  func outlook() async throws {
    let clock = FakeClock(ms: Scenarios.anchor)
    let (a, b) = try await Live.twoRuntimes(clock: clock)
    try await Scenarios.outlookToReplay(a, b, clock: clock)
  }
}
