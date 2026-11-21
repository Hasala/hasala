import Foundation

enum OnboardingStep: Int, Comparable, CaseIterable, Sendable {
  case passcode = 0
  case account
  case keys
  case bank
  case mail
  case finished

  static func < (a: OnboardingStep, b: OnboardingStep) -> Bool { a.rawValue < b.rawValue }

  struct Facts: Equatable, Sendable {
    var hasPasscode = true
    var hasSession = false
    var keysReady = false
    var banksChosen = false
    var bankSkipped = false
    enum Mailbox: Equatable, Sendable { case unlinked, scanning, linked, otherDevice }
    var mailbox: Mailbox = .unlinked
    var mailSkipped = false
    var sampleLoaded = false
    var textsChosen = false
  }

  static func derive(_ f: Facts) -> OnboardingStep {
    guard f.hasPasscode else { return .passcode }
    guard f.hasSession else { return .account }
    guard f.keysReady else { return .keys }
    guard f.banksChosen || f.bankSkipped || f.sampleLoaded || f.textsChosen else { return .bank }
    let manual = f.bankSkipped && !f.banksChosen
    let mailDone = manual || f.mailbox != .unlinked || f.mailSkipped || f.sampleLoaded || f.textsChosen
    guard mailDone else { return .mail }
    return .finished
  }
}
