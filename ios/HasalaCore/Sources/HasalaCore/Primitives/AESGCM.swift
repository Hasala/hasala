import CryptoKit
import Foundation

public enum AESGCM {
  public static let keyByteCount = 32
  public static let nonceByteCount = 12
  public static let tagByteCount = 16

  public static func seal(
    key: some ContiguousBytes, nonce: some DataProtocol, aad: some DataProtocol,
    plaintext: some DataProtocol
  ) throws(PrimitivesError) -> Data {
    let symmetric = try checkedKey(key)
    let gcmNonce = try checkedNonce(nonce)
    do {
      let box = try AES.GCM.seal(plaintext, using: symmetric, nonce: gcmNonce, authenticating: aad)
      return box.ciphertext + box.tag
    } catch {
      throw .sealFailed
    }
  }

  public static func open(
    key: some ContiguousBytes, nonce: some DataProtocol, aad: some DataProtocol,
    sealed: some DataProtocol
  ) throws(PrimitivesError) -> Data {
    let symmetric = try checkedKey(key)
    let gcmNonce = try checkedNonce(nonce)
    let bytes = Data(sealed)
    guard bytes.count >= tagByteCount else { throw .authenticationFailed }
    let split = bytes.count - tagByteCount
    do {
      let box = try AES.GCM.SealedBox(
        nonce: gcmNonce, ciphertext: bytes.prefix(split), tag: bytes.suffix(tagByteCount))
      return try AES.GCM.open(box, using: symmetric, authenticating: aad)
    } catch {
      throw .authenticationFailed
    }
  }

  private static func checkedKey(_ key: some ContiguousBytes) throws(PrimitivesError) -> SymmetricKey {
    let count = key.withUnsafeBytes { $0.count }
    guard count == keyByteCount else {
      throw .invalidLength(what: "aes-256-gcm key", expected: "32", got: count)
    }
    return SymmetricKey(data: key)
  }

  private static func checkedNonce(_ nonce: some DataProtocol) throws(PrimitivesError) -> AES.GCM.Nonce {
    guard nonce.count == nonceByteCount, let n = try? AES.GCM.Nonce(data: nonce) else {
      throw .invalidLength(what: "aes-gcm nonce", expected: "12", got: nonce.count)
    }
    return n
  }
}
