enum CharsetKind: Equatable, Sendable {
  case passthrough
  case unresolved
  case singleByte(Int)
  case unsupported
}

enum Charset {
  static func classify(_ label: String) -> CharsetKind {
    let low = NormText.jsLower(label)
    guard isASCII(low) else { return .unresolved }
    if CharsetTables.passthrough.contains(low) { return .passthrough }
    if CharsetTables.unsupported.contains(low) { return .unsupported }
    if let i = CharsetTables.singleByte[low] { return .singleByte(i) }
    return .unresolved
  }

  static func classifyWord(_ label: String) -> CharsetKind {
    let low = NormText.jsLower(label)
    guard isASCII(low) else { return .unresolved }
    if CharsetTables.wordUnsupported.contains(low) { return .unsupported }
    if CharsetTables.wordPassthrough.contains(low) { return .passthrough }
    if let i = CharsetTables.wordSingleByte[low] { return .singleByte(i) }
    return .unresolved
  }

  static func isASCII(_ s: String) -> Bool { s.utf8.allSatisfy { $0 < 0x80 } }

  static func decodeSingleByte(table: Int, _ bytes: some Sequence<UInt8>) -> String {
    let t = CharsetTables.tables[table]
    var out = String.UnicodeScalarView()
    for b in bytes {
      out.append(Unicode.Scalar(t[Int(b)]) ?? "\u{FFFD}")
    }
    return String(out)
  }
}
