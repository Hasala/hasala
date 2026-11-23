import CryptoKit
import Foundation

public func sha256(_ data: some DataProtocol) -> Data {
  Data(SHA256.hash(data: data))
}

public func hmacSHA256(key: some ContiguousBytes, message: some DataProtocol) -> Data {
  Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
}

public func hkdfSHA256(
  inputKeyMaterial: some ContiguousBytes, salt: some DataProtocol, info: some DataProtocol,
  outputByteCount: Int = 32
) throws(PrimitivesError) -> Data {
  guard outputByteCount > 0, outputByteCount <= 255 * 32 else {
    throw .invalidLength(what: "hkdf output", expected: "1...8160", got: outputByteCount)
  }
  let key = HKDF<SHA256>.deriveKey(
    inputKeyMaterial: SymmetricKey(data: inputKeyMaterial), salt: salt, info: info,
    outputByteCount: outputByteCount)
  return key.withUnsafeBytes { Data($0) }
}

public enum PrimitivesError: Error, Equatable, Sendable {
  case invalidLength(what: String, expected: String, got: Int)
  case authenticationFailed
  case sealFailed
  case invalidKey(what: String)
  case randomUnavailable(status: Int32)
  case pbkdf2Failed(status: Int32)
}
