import Foundation

public struct CivilDate: Sendable, Hashable, Comparable, CustomStringConvertible {
  public let year: Int
  public let month: Int
  public let day: Int

  public init?(year: Int, month: Int, day: Int) {
    guard (0...9999).contains(year), (1...12).contains(month),
      day >= 1, day <= Civil.daysInMonth(year: Int64(year), month: month)
    else { return nil }
    self.year = year
    self.month = month
    self.day = day
  }

  public init?(wire s: String) {
    let u = Array(s.utf8)
    guard u.count == 10, u[4] == 0x2d, u[7] == 0x2d,
      let y = CivilDate.digits(u[0..<4]), let m = CivilDate.digits(u[5..<7]), let d = CivilDate.digits(u[8..<10]),
      (2000...2099).contains(y)
    else { return nil }
    self.init(year: y, month: m, day: d)
  }

  static let daysRange: ClosedRange<Int64> =
    Civil.daysFromCivil(year: 0, month: 1, day: 1)...Civil.daysFromCivil(year: 9999, month: 12, day: 31)

  public init?(daysSinceEpoch days: Int64) {
    guard CivilDate.daysRange.contains(days) else { return nil }
    let (y, m, d) = Civil.civilFromDays(days)
    guard (0...9999).contains(y) else { return nil }
    self.init(year: Int(y), month: m, day: d)
  }

  public var daysSinceEpoch: Int64 { Civil.daysFromCivil(year: Int64(year), month: month, day: day) }

  public var wire: String { "\(Civil.pad(year, 4))-\(Civil.pad2(month))-\(Civil.pad2(day))" }
  public var description: String { wire }

  public var yearMonth: CivilMonth { CivilMonth(validYear: year, month: month) }

  public var isoWeekday: Int {
    let r = (daysSinceEpoch + 3) % 7
    return Int(r < 0 ? r + 7 : r) + 1
  }

  public func adding(days n: Int) -> CivilDate? {
    let (r, o) = daysSinceEpoch.addingReportingOverflow(Int64(n))
    return o ? nil : CivilDate(daysSinceEpoch: r)
  }

  public static func < (a: CivilDate, b: CivilDate) -> Bool { a.daysSinceEpoch < b.daysSinceEpoch }

  static func digits(_ s: ArraySlice<UInt8>) -> Int? {
    var v = 0
    for c in s {
      guard c >= 0x30, c <= 0x39 else { return nil }
      v = v * 10 + Int(c - 0x30)
    }
    return v
  }
}

public struct CivilMonth: Sendable, Hashable, Comparable, CustomStringConvertible {
  public let year: Int
  public let month: Int

  public init?(year: Int, month: Int) {
    guard (0...9999).contains(year), (1...12).contains(month) else { return nil }
    self.init(validYear: year, month: month)
  }

  init(validYear: Int, month: Int) {
    year = validYear
    self.month = month
  }

  public init?(wire s: String) {
    let u = Array(s.utf8)
    guard u.count == 7, u[4] == 0x2d, let y = CivilDate.digits(u[0..<4]), let m = CivilDate.digits(u[5..<7]),
      (2000...2099).contains(y)
    else { return nil }
    self.init(year: y, month: m)
  }

  public init?(index: Int) {
    guard (0...(9999 * 12 + 11)).contains(index) else { return nil }
    self.init(validYear: index / 12, month: index % 12 + 1)
  }

  public var index: Int { year * 12 + month - 1 }

  public var daysInMonth: Int { Civil.daysInMonth(year: Int64(year), month: month) }
  public var firstDay: CivilDate { CivilDate(year: year, month: month, day: 1)! }
  public var lastDay: CivilDate { CivilDate(year: year, month: month, day: daysInMonth)! }

  public var wire: String { "\(Civil.pad(year, 4))-\(Civil.pad2(month))" }
  public var description: String { wire }

  public func adding(months n: Int) -> CivilMonth? {
    let (r, o) = index.addingReportingOverflow(n)
    return o ? nil : CivilMonth(index: r)
  }

  public static func < (a: CivilMonth, b: CivilMonth) -> Bool { a.index < b.index }
}

public func monthsBetween(_ a: CivilMonth, _ b: CivilMonth) -> Int { b.index - a.index }

public enum LocalClock {
  public static let offsetMinutes: Int64 = 240
  public static let offsetMs: Int64 = offsetMinutes * 60_000

  public static func localDate(_ epochMs: Int64) -> CivilDate? {
    let (local, o) = epochMs.addingReportingOverflow(offsetMs)
    return o ? nil : CivilDate(daysSinceEpoch: Civil.floorDiv(local, Civil.msPerDay))
  }

  public static func localMonth(_ epochMs: Int64) -> CivilMonth? { localDate(epochMs)?.yearMonth }

  public static func startOfDay(_ date: CivilDate) -> Int64 {
    date.daysSinceEpoch * Civil.msPerDay - offsetMs
  }
}

public protocol Clock: Sendable {
  func nowMs() -> Int64
}

public struct SystemClock: Clock {
  public init() {}
  public func nowMs() -> Int64 {
    // lint-allow: Date CoreTime's clock adapter is the sanctioned reader of the wall clock (R8).
    Int64((Date().timeIntervalSince1970 * 1000).rounded(.down))
  }
}
