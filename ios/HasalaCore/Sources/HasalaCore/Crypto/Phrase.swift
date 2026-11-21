import CorePrimitives
import Foundation

public enum PhraseError: Error, Equatable, Sendable {
  case length(count: Int)
  case unknownWord(index: Int, word: String)
  case checksum
  case entropyLength(Int)
}

public enum Phrase {
  public static let wordCount = 12
  public static let entropyByteCount = 16

  private static let index: [String: Int] = {
    var d = [String: Int](minimumCapacity: 2048)
    for (i, w) in BIP39English.words.enumerated() { d[w] = i }
    return d
  }()

  public static func generate(random: some RandomSource) throws(PrimitivesError) -> SecureBytes {
    SecureBytes(copying: try random.bytes(entropyByteCount))
  }

  public static func words(entropy: some ContiguousBytes) throws(PhraseError) -> [String] {
    let e = entropy.withUnsafeBytes { [UInt8]($0) }
    guard e.count == entropyByteCount else { throw .entropyLength(e.count) }
    let checksum = sha256(e)[0] >> 4
    var out: [String] = []
    out.reserveCapacity(wordCount)
    for w in 0..<wordCount {
      var v = 0
      for b in 0..<11 {
        let bit = w * 11 + b
        let set: Bool
        if bit < 128 {
          set = (e[bit / 8] >> (7 - UInt8(bit % 8))) & 1 == 1
        } else {
          set = (checksum >> (3 - UInt8(bit - 128))) & 1 == 1
        }
        v = v << 1 | (set ? 1 : 0)
      }
      out.append(BIP39English.words[v])
    }
    return out
  }

  public static func normalize(_ typed: String) -> [String] {
    let folded = typed.decomposedStringWithCompatibilityMapping.lowercased()
    var scalars = String.UnicodeScalarView()
    var inRun = false
    for s in folded.unicodeScalars {
      if isW(s) {
        if !inRun { scalars.append(" ") }
        inRun = true
      } else {
        scalars.append(s)
        inRun = false
      }
    }
    var text = String(scalars)
    while text.unicodeScalars.first == " " { text.unicodeScalars.removeFirst() }
    while text.unicodeScalars.last == " " { text.unicodeScalars.removeLast() }
    if text.isEmpty { return [] }
    return text.unicodeScalars.split(separator: " ", omittingEmptySubsequences: false).map { String($0) }
  }

  public static func entropy(words: [String]) throws(PhraseError) -> SecureBytes {
    guard words.count == wordCount else { throw .length(count: words.count) }
    var indices: [Int] = []
    for (i, w) in words.enumerated() {
      guard let v = index[w], BIP39English.words[v].utf8.elementsEqual(w.utf8) else {
        throw .unknownWord(index: i, word: w)
      }
      indices.append(v)
    }
    var bits = [UInt8](repeating: 0, count: 17)
    for (w, v) in indices.enumerated() {
      for b in 0..<11 where (v >> (10 - b)) & 1 == 1 {
        let bit = w * 11 + b
        bits[bit / 8] |= 0x80 >> UInt8(bit % 8)
      }
    }
    let e = SecureBytes(copying: Array(bits[0..<16]))
    let want = bits[16] >> 4
    let got = e.withUnsafeBytes { sha256($0)[0] >> 4 }
    for i in bits.indices { bits[i] = 0 }
    guard constantTimeEquals([want], [got]) else { throw .checksum }
    return e
  }

  public static func entropy(typed: String) throws(PhraseError) -> SecureBytes {
    try entropy(words: normalize(typed))
  }

  public static func confirmationPositions(random: some RandomSource) throws(PrimitivesError) -> [Int] {
    var picked = Set<Int>()
    while picked.count < 4 {
      let b = try random.bytes(1)[0]
      guard b < 240 else { continue }
      picked.insert(Int(b) % wordCount)
    }
    return picked.sorted()
  }

  static func isW(_ s: Unicode.Scalar) -> Bool {
    switch s.value {
    case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: true
    default: false
    }
  }
}
