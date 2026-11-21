import CorePrimitives
import CoreWire
import CryptoKit
import Foundation

public enum DWK {
  public static func generate() -> (seed: SecureBytes, publicKey: Data) { Ed25519.generate() }

  public static func sign(seed: some ContiguousBytes, message: some DataProtocol) throws(PrimitivesError) -> Data {
    try Ed25519.sign(seed: seed, message: message)
  }
}

public enum DAK {
  public static let publicKeyByteCount = 65
  public static let signatureByteCount = 64

  static let order: [UInt8] = Array(
    try! Hex.decode("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551"))

  public static func isValidPublicKey(_ x963: Data) -> Bool {
    guard x963.count == publicKeyByteCount, x963.first == 0x04 else { return false }
    return (try? P256.Signing.PublicKey(x963Representation: x963)) != nil
  }

  public static func verify(publicKey: Data, signature: Data, message: some DataProtocol) -> Bool {
    guard isValidPublicKey(publicKey), signature.count == signatureByteCount else { return false }
    let s = [UInt8](signature)
    guard inRange(Array(s[0..<32])), inRange(Array(s[32..<64])) else { return false }
    return P256Verify.verify(publicKeyX963: publicKey, signatureRaw: signature, message: message)
  }

  static func inRange(_ v: [UInt8]) -> Bool {
    guard v.contains(where: { $0 != 0 }) else { return false }
    for (a, b) in zip(v, order) where a != b { return a < b }
    return false
  }
}

public enum HeadCheck {
  public struct Row: Sendable, Hashable {
    public let writerID: WriterID
    public let counter: Int64
    public let blobHash: Hash32
    public let headSig: Data?
    public init(writerID: WriterID, counter: Int64, blobHash: Hash32, headSig: Data?) {
      self.writerID = writerID
      self.counter = counter
      self.blobHash = blobHash
      self.headSig = headSig
    }
  }

  public struct RosterWriter: Sendable, Hashable {
    public let dwkPublicKey: Data
    public let revokedAt: Chain.Head?
    public init(dwkPublicKey: Data, revokedAt: Chain.Head?) {
      self.dwkPublicKey = dwkPublicKey
      self.revokedAt = revokedAt
    }
  }

  public static func verify(userID: UserID, rows: [Row], roster: [WriterID: RosterWriter]) throws(ReaderHardStop) {
    if let f = firstFailure(userID: userID, rows: rows, roster: roster) { throw .tampered(f.reason) }
  }

  public static func firstFailure(userID: UserID, rows: [Row], roster: [WriterID: RosterWriter])
    -> (index: Int, reason: TamperReason)?
  {
    var last: [WriterID: Int] = [:]
    for (i, r) in rows.enumerated() { last[r.writerID] = i }
    for (w, i) in last.sorted(by: { $0.value < $1.value }) {
      guard let entry = roster[w] else { return (i, .unknownWriter) }
      if let pin = entry.revokedAt {
        for (j, r) in rows.enumerated() where r.writerID == w {
          if r.counter > pin.counter || (r.counter == pin.counter && r.blobHash != pin.hash) {
            return (j, .afterRevocation)
          }
        }
      }
      let top = rows[i]
      guard let sig = top.headSig else { return (i, .headUnsigned) }
      let message = SigningMessage.head(userID: userID, counter: top.counter, blobHash: top.blobHash, writerID: w)
      guard Ed25519.verify(publicKey: entry.dwkPublicKey, signature: sig, message: message) else {
        return (i, .headInvalid)
      }
    }
    return nil
  }
}
