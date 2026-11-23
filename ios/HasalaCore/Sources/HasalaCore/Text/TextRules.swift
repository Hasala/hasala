public enum TextViolation: Error, Equatable, Sendable {
  case empty
  case tooManyScalars(max: Int)
  case tooManyBytes(max: Int)
  case forbiddenScalar(UInt32)
  case edgeSpace
  case notToken
}

public enum TextRules {
  public static let labelMaxScalars = 64
  public static let labelMaxBytes = 256
  public static let noteMaxScalars = 500
  public static let noteMaxBytes = 2000

  public static func checkLabel(_ s: String) -> TextViolation? {
    let scalars = s.unicodeScalars
    guard let first = scalars.first, let last = scalars.last else { return .empty }
    if scalars.count > labelMaxScalars { return .tooManyScalars(max: labelMaxScalars) }
    if s.utf8.count > labelMaxBytes { return .tooManyBytes(max: labelMaxBytes) }
    if let bad = scalars.first(where: { ScalarSet.forbidden.contains($0) }) { return .forbiddenScalar(bad.value) }
    if ScalarSet.edgeSpace.contains(first) || ScalarSet.edgeSpace.contains(last) { return .edgeSpace }
    return nil
  }

  public static func checkNote(_ s: String) -> TextViolation? {
    if s.unicodeScalars.count > noteMaxScalars { return .tooManyScalars(max: noteMaxScalars) }
    if s.utf8.count > noteMaxBytes { return .tooManyBytes(max: noteMaxBytes) }
    if let bad = s.unicodeScalars.first(where: { $0.value != 0x0a && ScalarSet.forbidden.contains($0) }) {
      return .forbiddenScalar(bad.value)
    }
    return nil
  }

  public static func isToken(_ s: String) -> Bool {
    let u = Array(s.utf8)
    guard (1...32).contains(u.count), ASCII.isLower(u[0]) else { return false }
    return u.dropFirst().allSatisfy { ASCII.isLower($0) || ASCII.isDigit($0) || $0 == 0x5f }
  }
}
