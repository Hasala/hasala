import CorePrimitives
import Foundation

public enum KeyDerivation {
  static let zeroSalt = Data(count: 32)

  public static let prfSalt: Data = sha256(Domain.prfSaltUnlock.bytes)

  public static func recoveryKeySeed(entropy: some ContiguousBytes) throws(PrimitivesError) -> SecureBytes {
    try requireLength(entropy, Phrase.entropyByteCount, "phrase entropy")
    return SecureBytes(copying: try hkdfSHA256(inputKeyMaterial: entropy, salt: zeroSalt, info: Domain.recoveryKey.bytes))
  }

  public static func recoveryPublicKey(entropy: some ContiguousBytes) throws(PrimitivesError) -> Data {
    try Ed25519.publicKey(seed: try recoveryKeySeed(entropy: entropy))
  }

  public static func recoveryWrapKey(entropy: some ContiguousBytes, salt: some DataProtocol) throws(PrimitivesError)
    -> SecureBytes
  {
    try requireLength(entropy, Phrase.entropyByteCount, "phrase entropy")
    try requireCount(salt.count, 32, "wrap salt")
    return SecureBytes(copying: try hkdfSHA256(inputKeyMaterial: entropy, salt: salt, info: Domain.wrapRecovery.bytes))
  }

  public static func prfWrapKey(prfOutput: some ContiguousBytes, salt: some DataProtocol) throws(PrimitivesError)
    -> SecureBytes
  {
    try requireLength(prfOutput, 32, "prf output")
    try requireCount(salt.count, 32, "wrap salt")
    return SecureBytes(copying: try hkdfSHA256(inputKeyMaterial: prfOutput, salt: salt, info: Domain.wrapPRF.bytes))
  }

  public static func amkCommitment(amk: some ContiguousBytes, userID: UserID) throws(PrimitivesError) -> Data {
    try requireLength(amk, 32, "amk")
    return hmacSHA256(key: amk, message: Domain.amkCommitment.prefix + userID.raw)
  }

  public static func epochKey1(amk: some ContiguousBytes, userID: UserID) throws(PrimitivesError) -> SecureBytes {
    try requireLength(amk, 32, "amk")
    let info = Domain.epochKey.prefix + Data([0, 0, 0, 1])
    return SecureBytes(copying: try hkdfSHA256(inputKeyMaterial: amk, salt: userID.raw, info: info))
  }

  public static func blobKey(epochKey: some ContiguousBytes, nonce: some DataProtocol, associatedData: some DataProtocol)
    throws(PrimitivesError) -> SecureBytes
  {
    try requireLength(epochKey, 32, "epoch key")
    try requireCount(nonce.count, 12, "frame nonce")
    let info = Domain.blobKey.prefix + sha256(associatedData)
    return SecureBytes(copying: try hkdfSHA256(inputKeyMaterial: epochKey, salt: nonce, info: info))
  }

  public static func phraseBoxKey(amk: some ContiguousBytes, userID: UserID) throws(PrimitivesError) -> SecureBytes {
    try requireLength(amk, 32, "amk")
    return SecureBytes(copying: try hkdfSHA256(inputKeyMaterial: amk, salt: userID.raw, info: Domain.phraseBoxKey.bytes))
  }

  static func requireLength(_ k: some ContiguousBytes, _ n: Int, _ what: String) throws(PrimitivesError) {
    try requireCount(k.withUnsafeBytes { $0.count }, n, what)
  }

  static func requireCount(_ got: Int, _ n: Int, _ what: String) throws(PrimitivesError) {
    guard got == n else { throw .invalidLength(what: what, expected: String(n), got: got) }
  }
}
