import HasalaText

public enum Canon {
  public static let maxSubjectRunes = 512

  public static func isGoSpace(_ s: Unicode.Scalar) -> Bool { ScalarSet.goSpace.contains(s) }

  public static func foldCase(_ s: String) -> String { GoCase.lower(s) }

  public static func canonical(_ s: String) -> String { foldCase(s.collapsingGoSpace) }

  public static func runeLength(_ s: String) -> Int { s.unicodeScalars.count }

  public static func truncateRunes(_ s: String, _ n: Int) -> String { HasalaText.truncateRunes(s, n) }

  public static func subject(_ merchantRaw: String) -> String {
    truncateRunes(canonical(merchantRaw), maxSubjectRunes)
  }

  public static func merchantKey(_ merchantRaw: String) -> String {
    truncateRunes(canonical(merchantRaw), 256)
  }
}
