import CryptoKit
import Foundation

public enum Ed25519 {
  public static let seedByteCount = 32
  public static let publicKeyByteCount = 32
  public static let signatureByteCount = 64

  public static func publicKey(seed: some ContiguousBytes) throws(PrimitivesError) -> Data {
    try privateKey(seed).publicKey.rawRepresentation
  }

  public static func sign(seed: some ContiguousBytes, message: some DataProtocol) throws(PrimitivesError) -> Data {
    do {
      return try privateKey(seed).signature(for: message)
    } catch let e as PrimitivesError {
      throw e
    } catch {
      throw .invalidKey(what: "ed25519 seed")
    }
  }

  public static func verify(publicKey: some ContiguousBytes, signature: some DataProtocol, message: some DataProtocol)
    -> Bool
  {
    guard signature.count == signatureByteCount,
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
    else { return false }
    return key.isValidSignature(signature, for: message)
  }

  public static func generate() -> (seed: SecureBytes, publicKey: Data) {
    let key = Curve25519.Signing.PrivateKey()
    let seed = key.rawRepresentation
    return (SecureBytes(copying: seed), key.publicKey.rawRepresentation)
  }

  private static func privateKey(_ seed: some ContiguousBytes) throws(PrimitivesError)
    -> Curve25519.Signing.PrivateKey
  {
    let count = seed.withUnsafeBytes { $0.count }
    guard count == seedByteCount else {
      throw .invalidLength(what: "ed25519 seed", expected: "32", got: count)
    }
    do {
      return try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    } catch {
      throw .invalidKey(what: "ed25519 seed")
    }
  }
}

public enum P256Verify {
  public static func verify(
    publicKeyX963: some ContiguousBytes, signatureRaw: some DataProtocol, message: some DataProtocol
  ) -> Bool {
    let keyCount = publicKeyX963.withUnsafeBytes { $0.count }
    guard keyCount == 65, signatureRaw.count == 64,
      let key = try? P256.Signing.PublicKey(x963Representation: publicKeyX963),
      let sig = try? P256.Signing.ECDSASignature(rawRepresentation: signatureRaw)
    else { return false }
    return key.isValidSignature(sig, for: message)
  }
}
