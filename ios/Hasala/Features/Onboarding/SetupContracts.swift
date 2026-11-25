import Foundation

enum SupportedBank: String, CaseIterable, Identifiable, Sendable {
  case enbd
  case dib
  case adib

  var id: String { rawValue }

  var name: String {
    switch self {
    case .enbd: "Emirates NBD"
    case .dib: "Dubai Islamic Bank"
    case .adib: "Abu Dhabi Islamic Bank"
    }
  }

  var shortName: String {
    switch self {
    case .enbd: "Emirates NBD"
    case .dib: "DIB"
    case .adib: "ADIB"
    }
  }

  var monogram: String {
    switch self {
    case .enbd: "ENBD"
    case .dib: "DIB"
    case .adib: "ADIB"
    }
  }

  var note: String? {
    switch self {
    case .enbd: nil
    case .dib: "Arabic alerts supported"
    case .adib: nil
    }
  }
}

struct ScanProgress: Equatable, Sendable {
  enum Phase: Equatable, Sendable {
    case downloading
    case sorting
    case finished
    case background
    case failed(String)
  }

  var phase: Phase
  var read: Int
  var total: Int
  var summary: SortSummary?

  var isRunning: Bool { phase == .downloading || phase == .sorting }
  var fraction: Double { total == 0 ? 0 : min(1, Double(read) / Double(total)) }
}

struct SortSummary: Equatable, Sendable {
  var total: Int
  var byRules: Int
  var byDictionary: Int
  var byModel: Int
  var toReview: Int

  var sortedThemselves: Int { max(0, total - toReview) }
}

struct StartingPlan: Equatable, Sendable {
  var needsPercent: Int = 50
  var wantsPercent: Int = 30
  var savingsPercent: Int = 20

  func amounts(income: Int64) -> (needs: Int64, wants: Int64, savings: Int64) {
    let needs = income * Int64(needsPercent) / 100
    let wants = income * Int64(wantsPercent) / 100
    return (needs, wants, income - needs - wants)
  }

  var isValid: Bool {
    needsPercent >= 0 && wantsPercent >= 0 && savingsPercent >= 0 && needsPercent + wantsPercent + savingsPercent == 100
  }
}

struct SetupReadBack: Equatable, Sendable {
  var incomeMinor: Int64?
  var payday: Int?
  var split: StartingPlan?
  var paydayLastWorkingDay = false

  var paydayChoice: PaydayChoice? { payday.map { PaydayChoice(day: $0, lastWorkingDay: paydayLastWorkingDay) } }
}

@MainActor
protocol SetupAuthoring: AnyObject {
  func readBack() -> SetupReadBack
  func chooseBanks(_ banks: [SupportedBank]) async throws(SetupFailure)
  func setBanks(_ banks: [SupportedBank]) async throws(SetupFailure)
  func requestBank(_ name: String) async throws(SetupFailure)
  func requestBank(slug: String, senderDomain: String?) async throws(SetupFailure)
  func bankRequests() async throws(SetupFailure) -> BankRequestsSnapshot
  func savePlan(income: Int64?, payday: Int?, lastWorkingDay: Bool, plan: StartingPlan?) async throws(SetupFailure)
}

extension SetupAuthoring {
  func savePlan(income: Int64?, payday: Int?, plan: StartingPlan?) async throws(SetupFailure) {
    try await savePlan(income: income, payday: payday, lastWorkingDay: false, plan: plan)
  }
}

@MainActor
protocol CloudSortOffering: AnyObject {
  var isOffered: Bool { get }
  var isOn: Bool { get }
  var answered: Bool { get }
  func turnOn()
  func notNow()
}

@MainActor
protocol NotificationPermissionAsking: AnyObject {
  func requestAuthorization() async -> Bool
  var answered: Bool { get }
  func decline()
  var showsDetails: Bool { get set }
}

enum SetupFailure: Error, Equatable, Sendable {
  case cancelled
  case offline
  case failed(String)

  var message: String? {
    switch self {
    case .cancelled: nil
    case .offline: "You're offline. Finish setup once you're online."
    case .failed(let s): s
    }
  }
}
