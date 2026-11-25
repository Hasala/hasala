public enum MoneyMath {
  public static func add(_ a: Int64, _ b: Int64) -> Int64? {
    let (r, o) = a.addingReportingOverflow(b)
    return o ? nil : r
  }

  public static func subtract(_ a: Int64, _ b: Int64) -> Int64? {
    let (r, o) = a.subtractingReportingOverflow(b)
    return o ? nil : r
  }

  public static func multiply(_ a: Int64, _ b: Int64) -> Int64? {
    let (r, o) = a.multipliedReportingOverflow(by: b)
    return o ? nil : r
  }

  public static func wideSum(_ values: some Sequence<Int64>) -> Int128 {
    values.reduce(Int128(0)) { $0 + Int128($1) }
  }

  public static func sum(_ values: some Sequence<Int64>) -> Int64? { Int64(exactly: wideSum(values)) }

  public static func floorDiv(_ a: Int128, _ b: Int128) -> Int128 {
    precondition(b != 0, "floorDiv by zero")
    let q = a / b
    return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
  }

  public static func apportion(home: Int64?, parts: [Int64]) -> [Int64]? {
    guard let home else { return nil }
    let n = wideSum(parts)
    guard n > 0 else { return nil }
    let h = Int128(home)
    var cumulative: Int128 = 0
    var previous: Int128 = 0
    var out: [Int64] = []
    out.reserveCapacity(parts.count)
    for p in parts {
      cumulative += Int128(p)
      let (product, overflow) = h.multipliedReportingOverflow(by: cumulative)
      if overflow { return nil }
      let here = floorDiv(product, n)
      guard let share = Int64(exactly: here - previous) else { return nil }
      out.append(share)
      previous = here
    }
    return out
  }
}
