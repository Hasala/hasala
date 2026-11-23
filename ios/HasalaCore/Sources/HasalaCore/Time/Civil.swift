public enum Civil {
  public static let msPerDay: Int64 = 86_400_000

  public static func isLeapYear(_ y: Int64) -> Bool {
    y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)
  }

  public static func daysInMonth(year y: Int64, month m: Int) -> Int {
    switch m {
    case 2: isLeapYear(y) ? 29 : 28
    case 4, 6, 9, 11: 30
    default: 31
    }
  }

  public static func daysFromCivil(year: Int64, month: Int, day: Int) -> Int64 {
    let y = month <= 2 ? year - 1 : year
    let era = (y >= 0 ? y : y - 399) / 400
    let yoe = y - era * 400
    let mp = Int64((month + 9) % 12)
    let doy = (153 * mp + 2) / 5 + Int64(day) - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146_097 + doe - 719_468
  }

  public static func civilFromDays(_ days: Int64) -> (year: Int64, month: Int, day: Int) {
    let z = days + 719_468
    let era = (z >= 0 ? z : z - 146_096) / 146_097
    let doe = z - era * 146_097
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let day = Int(doy - (153 * mp + 2) / 5 + 1)
    let month = Int(mp < 10 ? mp + 3 : mp - 9)
    return (yoe + era * 400 + (month <= 2 ? 1 : 0), month, day)
  }

  public static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
    let q = a / b
    return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
  }

  public static func utcDay(_ epochMs: Int64) -> String {
    let (y, m, d) = civilFromDays(floorDiv(epochMs, msPerDay))
    return "\(yearText(y))-\(pad2(m))-\(pad2(d))"
  }

  static func yearText(_ y: Int64) -> String {
    if y >= 0 && y <= 9999 { return pad(Int(y), 4) }
    let digits = pad(Int(y.magnitude), 6)
    return (y < 0 ? "-" : "+") + digits
  }

  static func pad2(_ n: Int) -> String { pad(n, 2) }

  package static func pad(_ n: Int, _ width: Int) -> String {
    let s = String(n)
    return s.utf8.count >= width ? s : String(repeating: "0", count: width - s.utf8.count) + s
  }
}
