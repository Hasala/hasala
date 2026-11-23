import CorePrimitives
import CoreWire
import Foundation

public struct BootstrapPayload: Sendable, Hashable {
  public static let version: UInt8 = 0x01

  public let userID: UserID
  public let amkCommitment: Data
  public let authorityPublicKey: Data
  public let recoveryPublicKey: Data
  public let recoveryWrap: Data
  public let phraseBox: Data
  public let emailNorm: String
  public let authKind: AuthKind
  public let authHash: Data
  public let writerPublicKey: Data
  public let writerDAKPublicKey: Data
  public let writerID: WriterID
  public let prfWrap: (credentialID: Data, wrap: Data)?

  public init(
    userID: UserID, amkCommitment: Data, authorityPublicKey: Data, recoveryPublicKey: Data, recoveryWrap: Data,
    phraseBox: Data, emailNorm: String, authKind: AuthKind, authHash: Data, writerPublicKey: Data,
    writerDAKPublicKey: Data, writerID: WriterID, prfWrap: (credentialID: Data, wrap: Data)?
  ) {
    self.userID = userID
    self.amkCommitment = amkCommitment
    self.authorityPublicKey = authorityPublicKey
    self.recoveryPublicKey = recoveryPublicKey
    self.recoveryWrap = recoveryWrap
    self.phraseBox = phraseBox
    self.emailNorm = emailNorm
    self.authKind = authKind
    self.authHash = authHash
    self.writerPublicKey = writerPublicKey
    self.writerDAKPublicKey = writerDAKPublicKey
    self.writerID = writerID
    self.prfWrap = prfWrap
  }

  public func encoded() throws(SigningMessageError) -> Data {
    var out = Data([BootstrapPayload.version])
    out += userID.raw
    out += try SigningMessage.check(amkCommitment, 32, "amk_commitment")
    out += try SigningMessage.check(authorityPublicKey, 32, "authority_pubkey")
    out += try SigningMessage.check(recoveryPublicKey, 32, "recovery_pubkey")
    out += SigningMessage.u32be(1)
    out += [0x00, 127]
    out += try SigningMessage.check(recoveryWrap, Wrap.byteCount, "recovery_wrap")
    out += [0x00, 45]
    out += try SigningMessage.check(phraseBox, PhraseBox.byteCount, "phrase_box")
    out += EmailNorm.hash(emailNorm)
    out += [authKind.rawValue]
    out += try SigningMessage.check(authHash, 32, "auth_hash")
    out += [0x01]
    out += try SigningMessage.check(writerPublicKey, 32, "writer pubkey")
    out += try SigningMessage.check(writerDAKPublicKey, 65, "writer dak_pubkey")
    out += [UInt8(WriterID.byteCount)]
    out += writerID.bytes
    if let (credentialID, wrap) = prfWrap {
      guard Wrap.credentialIDBytes.contains(credentialID.count) else {
        throw .invalidLength(field: "credential_id", expected: 16, got: credentialID.count)
      }
      out += [UInt8(credentialID.count >> 8), UInt8(credentialID.count & 0xff)]
      out += credentialID
      out += [0x00, 127]
      out += try SigningMessage.check(wrap, Wrap.byteCount, "prf wrap")
    } else {
      out += [0x00, 0x00, 0x00, 0x00]
    }
    return out
  }

  public static func == (a: BootstrapPayload, b: BootstrapPayload) -> Bool {
    (try? a.encoded()) == (try? b.encoded())
  }

  public func hash(into h: inout Hasher) { h.combine(try? encoded()) }
}
