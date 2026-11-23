import CorePrimitives
import CoreWire
import Foundation

public enum SigningMessageError: Error, Equatable, Sendable {
  case invalidLength(field: String, expected: Int, got: Int)
}

public enum AuthKind: UInt8, Sendable, CaseIterable {
  case none = 0x00
  case passkey = 0x01
  case password = 0x02
}

public enum SigningMessage {
  static let zero32 = Data(count: 32)

  static func check(_ d: some DataProtocol, _ n: Int, _ field: String) throws(SigningMessageError) -> Data {
    guard d.count == n else { throw .invalidLength(field: field, expected: n, got: d.count) }
    return Data(d)
  }

  static func u64be(_ v: Int64) -> Data {
    let u = UInt64(bitPattern: v)
    return Data((0..<8).map { UInt8(u >> (56 - 8 * UInt64($0)) & 0xff) })
  }

  static func u32be(_ v: UInt32) -> Data {
    Data([UInt8(v >> 24), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)])
  }

  public static func registration(nonce: Data, writerID: WriterID, dwkPublicKey: Data, dakPublicKey: Data)
    throws(SigningMessageError) -> Data
  {
    Domain.writerRegistration.prefix + (try check(nonce, 32, "nonce")) + [0] + writerID.bytes + [0]
      + (try check(dwkPublicKey, 32, "dwk_pub")) + (try check(dakPublicKey, 65, "dak_pub"))
  }

  public static func revocation(nonce: Data, writerID: WriterID, finalCounter: Int64, finalHead: Hash32)
    throws(SigningMessageError) -> Data
  {
    guard finalCounter >= 0 else { throw .invalidLength(field: "final_counter", expected: 0, got: -1) }
    return Domain.writerRevocation.prefix + (try check(nonce, 32, "nonce")) + [0] + writerID.bytes + [0]
      + u64be(finalCounter) + finalHead.bytes
  }

  public static func sessionBind(loginChallenge: Data, writerID: WriterID) throws(SigningMessageError) -> Data {
    Domain.sessionBind.prefix + (try check(loginChallenge, 32, "login_challenge")) + [0] + writerID.bytes
  }

  public static func deletion(nonce: Data, userID: UserID) throws(SigningMessageError) -> Data {
    Domain.accountDelete.prefix + (try check(nonce, 32, "nonce")) + [0] + Data(userID.string.utf8)
  }

  public static func bootstrap(nonce: Data, payload: some DataProtocol) throws(SigningMessageError) -> Data {
    Domain.bootstrap.prefix + (try check(nonce, 32, "nonce")) + sha256(payload)
  }

  public static func recoverySigninPasskey(
    nonce: Data, clientDataJSON: some DataProtocol, attestationObject: some DataProtocol, prfWrap: Data?
  ) throws(SigningMessageError) -> Data {
    Domain.recoverySignin.prefix + (try check(nonce, 32, "nonce")) + [AuthKind.passkey.rawValue]
      + sha256(clientDataJSON) + sha256(attestationObject) + (prfWrap.map { sha256($0) } ?? zero32)
  }

  public static func recoverySigninPassword(nonce: Data, newVerifier: some ContiguousBytes) throws(SigningMessageError)
    -> Data
  {
    let s = try check(newVerifier.withUnsafeBytes { Data($0) }, 32, "S_new")
    return Domain.recoverySignin.prefix + (try check(nonce, 32, "nonce")) + [AuthKind.password.rawValue] + sha256(s)
      + zero32 + zero32
  }

  public static func recoveryRotate(
    nonce: Data, newRecoveryPublicKey: Data, newRecoveryWrap: some DataProtocol, newPhraseBox: some DataProtocol
  ) throws(SigningMessageError) -> Data {
    Domain.recoveryRotate.prefix + (try check(nonce, 32, "nonce")) + (try check(newRecoveryPublicKey, 32, "new_recovery_pub"))
      + sha256(newRecoveryWrap) + sha256(newPhraseBox)
  }

  public static func epochRotate(nonce: Data, newEpoch: UInt32, keyring: some DataProtocol) throws(SigningMessageError)
    -> Data
  {
    Domain.epochRotate.prefix + (try check(nonce, 32, "nonce")) + u32be(newEpoch) + sha256(keyring)
  }

  public static func head(userID: UserID, counter: Int64, blobHash: Hash32, writerID: WriterID) -> Data {
    Domain.writerHead.prefix + userID.raw + u64be(counter) + blobHash.bytes + [0] + writerID.bytes
  }

  public static func passkeyAdd(
    nonce: Data, clientDataJSON: some DataProtocol, attestationObject: some DataProtocol, prfWrap: Data?
  ) throws(SigningMessageError) -> Data {
    Domain.passkeyAdd.prefix + (try check(nonce, 32, "nonce")) + sha256(clientDataJSON) + sha256(attestationObject)
      + (prfWrap.map { sha256($0) } ?? zero32)
  }

  public static func wrapPut(nonce: Data, credentialID: some DataProtocol, wrap: some DataProtocol)
    throws(SigningMessageError) -> Data
  {
    Domain.wrapPut.prefix + (try check(nonce, 32, "nonce")) + sha256(credentialID) + sha256(wrap)
  }

  public static func deviceStepUp(challenge: Data, writerID: WriterID) throws(SigningMessageError) -> Data {
    Domain.stepUpDevice.prefix + (try check(challenge, 32, "C")) + [0] + writerID.bytes
  }

  public static func resetApprove(nonce: Data, userID: UserID, ephemeralPublicKey: Data, writerID: WriterID)
    throws(SigningMessageError) -> Data
  {
    Domain.resetApprove.prefix + (try check(nonce, 32, "nonce")) + userID.raw
      + sha256(try check(ephemeralPublicKey, 32, "ek_pub")) + [0] + writerID.bytes
  }

  public static func resetFinish(nonce: Data, newVerifier: some ContiguousBytes) throws(SigningMessageError) -> Data {
    let s = try check(newVerifier.withUnsafeBytes { Data($0) }, 32, "S_new")
    return Domain.resetFinish.prefix + (try check(nonce, 32, "nonce")) + sha256(s)
  }

  public static func emailChange(nonce: Data, newEmailNorm: String) throws(SigningMessageError) -> Data {
    Domain.emailChange.prefix + (try check(nonce, 32, "nonce")) + EmailNorm.hash(newEmailNorm)
  }

  public static func deviceFreeze(nonce: Data, userID: UserID, writerID: WriterID) throws(SigningMessageError) -> Data {
    Domain.deviceFreeze.prefix + (try check(nonce, 32, "nonce")) + userID.raw + [0] + writerID.bytes
  }

  public static func registerChallenge(nonce: Data, authorityPublicKey: Data) throws(SigningMessageError) -> Data {
    sha256(Domain.register.prefix + (try check(nonce, 32, "nonce")) + (try check(authorityPublicKey, 32, "authority_pub")))
  }
}
