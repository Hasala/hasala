public struct ScalarSet: Sendable, Hashable {
  private let sorted: [UInt32]

  public init(_ values: [UInt32]) {
    sorted = Array(Set(values)).sorted()
  }

  public func contains(_ scalar: Unicode.Scalar) -> Bool { contains(scalar.value) }

  public func contains(_ value: UInt32) -> Bool {
    var lo = 0
    var hi = sorted.count
    while lo < hi {
      let mid = (lo + hi) / 2
      if sorted[mid] == value { return true }
      if sorted[mid] < value { lo = mid + 1 } else { hi = mid }
    }
    return false
  }

  public var members: [UInt32] { sorted }

  public static let goSpace = ScalarSet([
    0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x20, 0x85, 0xa0, 0x1680,
    0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200a,
    0x2028, 0x2029, 0x202f, 0x205f, 0x3000,
  ])

  public static let asciiSpace = ScalarSet([0x20, 0x09, 0x0a, 0x0b, 0x0c, 0x0d])

  public static let spaceTab = ScalarSet([0x20, 0x09])

  public static let unwrapTrim = ScalarSet([0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x20, 0xa0, 0xfeff])

  public static let jsTrim = ScalarSet([
    0x09, 0x0b, 0x0c, 0x20, 0xa0, 0xfeff, 0x1680,
    0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200a,
    0x202f, 0x205f, 0x3000, 0x0a, 0x0d, 0x2028, 0x2029,
  ])

  public static let edgeSpace = ScalarSet([
    0x20, 0xa0, 0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007,
    0x2008, 0x2009, 0x200a, 0x202f, 0x205f, 0x3000,
  ])

  public static let forbidden = ScalarSet(
    Array(0x00...0x1f) + [0x7f] + Array(0x80...0x9f) + [0x2028, 0x2029]
      + Array(0x202a...0x202e) + Array(0x2066...0x2069) + [0xfeff, 0xfffe, 0xffff])
}

extension BidirectionalCollection where Element == Unicode.Scalar {
  @inlinable
  public func trimming(_ set: ScalarSet) -> SubSequence {
    var lo = startIndex
    var hi = endIndex
    while lo < hi, set.contains(self[lo]) { lo = index(after: lo) }
    while hi > lo {
      let prev = index(before: hi)
      guard set.contains(self[prev]) else { break }
      hi = prev
    }
    return self[lo..<hi]
  }
}

extension String {
  public func trimming(_ set: ScalarSet) -> String { String(unicodeScalars.trimming(set)) }

  public var trimmingGoSpace: String { trimming(.goSpace) }

  public var collapsingGoSpace: String {
    var out = String.UnicodeScalarView()
    var pendingSpace = false
    for s in unicodeScalars {
      if ScalarSet.goSpace.contains(s) {
        pendingSpace = !out.isEmpty
        continue
      }
      if pendingSpace {
        out.append(" ")
        pendingSpace = false
      }
      out.append(s)
    }
    return String(out)
  }
}
