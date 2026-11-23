public enum LatinGate {
  static let latinV1: [ClosedRange<UInt32>] = [
    0x41...0x5A, 0x61...0x7A, 0xAA...0xAA, 0xBA...0xBA, 0xC0...0xD6, 0xD8...0xF6, 0xF8...0x24F, 0x1E00...0x1EFF,
    0x2C60...0x2C7F, 0xA720...0xA7FF, 0xAB30...0xAB6F, 0xFF21...0xFF3A, 0xFF41...0xFF5A,
  ]

  public static func passes(_ subject: String) -> Bool {
    var letters = 0
    for s in subject.unicodeScalars {
      let v = s.value
      switch s.properties.generalCategory {
      case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
        guard latinV1.contains(where: { $0.contains(v) }) else { return false }
        letters += 1
      case .decimalNumber:
        guard (0x30...0x39).contains(v) else { return false }
      case .nonspacingMark, .spacingMark, .enclosingMark:
        guard (0x300...0x36F).contains(v) else { return false }
      default:
        guard (0x20...0x7E).contains(v) || v == 0xA0 else { return false }
      }
    }
    return letters >= 3
  }
}
