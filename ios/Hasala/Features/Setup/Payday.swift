import Foundation
import HasalaModels

enum PaydayChoice: Hashable, Sendable {
  case day(Int)
  case lastWorkingDay

  static let all: [PaydayChoice] = (1...31).map(PaydayChoice.day) + [.lastWorkingDay]

  static let standard = PaydayChoice.day(28)

  init(day: Int, lastWorkingDay: Bool) {
    self = lastWorkingDay ? .lastWorkingDay : .day(day)
  }

  var isLastWorkingDay: Bool { self == .lastWorkingDay }

  func opDay(today: LocalDate, saved: PaydayChoice?, savedDay: Int?) -> Int {
    if self == saved, let savedDay { return savedDay }
    return opDay(today: today)
  }

  var index: Int {
    switch self {
    case .day(let d): min(max(d, 1), 31) - 1
    case .lastWorkingDay: 31
    }
  }

  func date(in month: YearMonth) -> LocalDate {
    switch self {
    case .day(let d):
      return LocalDate(month.year, month.month, min(max(d, 1), month.days))
    case .lastWorkingDay:
      return month.lastWorkingDay
    }
  }

  func next(onOrAfter today: LocalDate) -> LocalDate {
    let this = date(in: today.yearMonth)
    return this >= today ? this : date(in: today.yearMonth.next)
  }

  func opDay(today: LocalDate) -> Int {
    switch self {
    case .day(let d): d
    case .lastWorkingDay: next(onOrAfter: today).day
    }
  }

  var spoken: String {
    switch self {
    case .day(let d): "\(d)\(Self.suffix(d))"
    case .lastWorkingDay: "Last work day"
    }
  }

  static func suffix(_ d: Int) -> String {
    switch (d % 10, d % 100) {
    case (1, let t) where t != 11: "st"
    case (2, let t) where t != 12: "nd"
    case (3, let t) where t != 13: "rd"
    default: "th"
    }
  }

  var identifier: String {
    switch self {
    case .day(let d): "income.payday.\(d)"
    case .lastWorkingDay: "income.payday.last"
    }
  }
}

@MainActor
protocol SetupClock: AnyObject {
  func today() -> LocalDate
}

enum LedgerToday {
  static let offsetSeconds: TimeInterval = 4 * 3600

  static func device(_ now: Date = Date()) -> LocalDate {
    LocalDate(ordinal: Int(((now.timeIntervalSince1970 + offsetSeconds) / 86_400).rounded(.down)))
  }

  static let weekdayNames = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

  static func lockScreenDate(_ d: LocalDate) -> String {
    "\(weekdayNames[d.weekday]) \(d.day) \(d.yearMonth.name)"
  }
}
