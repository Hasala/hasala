public enum Pace {
  public static let minDay = 7
  public static let marginPercent: Int64 = 105

  public static func projected(_ spent: Int64, day: Int, days: Int, largest: Int64 = 0) -> Int64 {
    guard day > 0 else { return spent }
    let one = largest > 0 && largest.plus(largest) > spent ? largest : 0
    return one.plus(Fils.mulDiv(spent.minus(one), Int64(days), Int64(day)))
  }

  public static func showsProjection(day: Int) -> Bool { day >= minDay }

  public static func ahead(_ projected: Int64, of budget: Int64) -> Bool {
    Int128(projected) * 100 > Int128(budget) * Int128(marginPercent)
  }

  public static func verdict(spent: Int64, budget: Int64, day: Int, days: Int, paced: Bool, largest: Int64 = 0) -> Verdict {
    if budget <= 0 { return spent > 0 ? .overBudget : .onTrack }
    if spent > budget { return .overBudget }
    if !paced { return spent >= budget ? .done : .onTrack }
    guard showsProjection(day: day) else { return .onTrack }
    return ahead(projected(spent, day: day, days: days, largest: largest), of: budget) ? .overPace : .onTrack
  }

  public static func monthGone(day: Int, days: Int) -> Permille {
    guard days > 0 else { return Permille(0) }
    return Permille(day * 100 / days * 10)
  }

  public static func perDay(left: Int64, day: Int, days: Int) -> Int64 {
    let remaining = max(1, days - day + 1)
    return max(0, left) / Int64(remaining)
  }
}

extension Verdict {
  public var tone: StatusTone {
    switch self {
    case .onTrack: .accent
    case .overPace: .warning
    case .overBudget: .error
    case .done: .success
    }
  }
}
