import CorePrimitives
import CoreWire
import Foundation

public enum StepUpProofKind: String, Sendable, CaseIterable {
  case passkey
  case device
  case deviceCode = "device_code"
}

public enum StepUpParams: Sendable {
  case passkeyAdd
  case passkeyDelete(credentialID: Data)
  case keysBootstrap(authorityPublicKey: Data)
  case keysWrapPut(credentialID: Data)
  case keysWrapDelete(credentialID: Data)
  case keysRecoveryRotate(newRecoveryPublicKey: Data)
  case keysEpochRotate(newEpoch: UInt32)
  case writerRevoke(WriterID)
  case mailboxLink(idToken: String)
  case mailboxUnlink
  case sessionLogoutAll
  case accountDelete(UserID)
  case passwordSet(newVerifierHash: Data)
  case passwordChange(newVerifierHash: Data)
  case passwordRemove
  case passwordReset(newVerifierHash: Data)
  case emailChange(newEmailNorm: String, newVerifierHash: Data?)
  case phraseView
  case accountFreeze
  case accountUnfreeze

  public var action: String {
    switch self {
    case .passkeyAdd: "passkey.add"
    case .passkeyDelete: "passkey.delete"
    case .keysBootstrap: "keys.bootstrap"
    case .keysWrapPut: "keys.wrap.put"
    case .keysWrapDelete: "keys.wrap.delete"
    case .keysRecoveryRotate: "keys.recovery.rotate"
    case .keysEpochRotate: "keys.epoch.rotate"
    case .writerRevoke: "writer.revoke"
    case .mailboxLink: "mailbox.link"
    case .mailboxUnlink: "mailbox.unlink"
    case .sessionLogoutAll: "session.logout_all"
    case .accountDelete: "account.delete"
    case .passwordSet: "password.set"
    case .passwordChange: "password.change"
    case .passwordRemove: "password.remove"
    case .passwordReset: "password.reset"
    case .emailChange: "email.change"
    case .phraseView: "phrase.view"
    case .accountFreeze: "account.freeze"
    case .accountUnfreeze: "account.unfreeze"
    }
  }

  public var tuple: [Data] {
    switch self {
    case .passkeyAdd, .mailboxUnlink, .sessionLogoutAll, .passwordRemove, .phraseView, .accountFreeze,
      .accountUnfreeze:
      []
    case .passkeyDelete(let id), .keysWrapPut(let id), .keysWrapDelete(let id): [id]
    case .keysBootstrap(let k), .keysRecoveryRotate(let k): [k]
    case .keysEpochRotate(let e): [SigningMessage.u32be(e)]
    case .writerRevoke(let w): [w.bytes]
    case .mailboxLink(let token): [sha256(Data(token.utf8))]
    case .accountDelete(let u): [Data(u.string.utf8)]
    case .passwordSet(let h), .passwordChange(let h), .passwordReset(let h): [h]
    case .emailChange(let address, let h): [sha256(Data(address.utf8)), h ?? Data()]
    }
  }

  public func validate() throws(SigningMessageError) {
    switch self {
    case .keysBootstrap(let k): _ = try SigningMessage.check(k, 32, "authority_pubkey")
    case .keysRecoveryRotate(let k): _ = try SigningMessage.check(k, 32, "new_recovery_pubkey")
    case .passwordSet(let h), .passwordChange(let h), .passwordReset(let h):
      _ = try SigningMessage.check(h, 32, "SHA256(S_new)")
    case .emailChange(_, let h?): _ = try SigningMessage.check(h, 32, "SHA256(S_new)")
    default: break
    }
  }

  public var proofKinds: [StepUpProofKind] {
    switch self {
    case .keysBootstrap, .keysWrapPut, .passwordSet, .passwordRemove, .phraseView: [.passkey]
    case .passwordReset: [.deviceCode]
    default: [.passkey, .device]
    }
  }

  public var usesPRF: Bool {
    switch self {
    case .passkeyAdd, .keysWrapPut, .keysRecoveryRotate, .keysEpochRotate, .phraseView: true
    case .keysBootstrap: true
    default: false
    }
  }

  public static func verifierHash(_ s: some ContiguousBytes) -> Data { s.withUnsafeBytes { sha256($0) } }

  public static let actions = [
    "passkey.add", "passkey.delete", "keys.bootstrap", "keys.wrap.put", "keys.wrap.delete", "keys.recovery.rotate",
    "keys.epoch.rotate", "writer.revoke", "mailbox.link", "mailbox.unlink", "session.logout_all", "account.delete",
    "password.set", "password.change", "password.remove", "password.reset", "email.change", "phrase.view",
    "account.freeze", "account.unfreeze",
  ]
}

public enum StepUp {
  public static func encode(_ tuple: [Data]) -> Data {
    var out = Data()
    for f in tuple {
      out.append(SigningMessage.u32be(UInt32(f.count)))
      out.append(f)
    }
    return out
  }

  public static func paramsHash(action: String, tuple: [Data]) -> Data {
    sha256(Domain.stepUpParams.prefix + Data(action.utf8) + [0] + encode(tuple))
  }

  public static func paramsHash(_ p: StepUpParams) -> Data { paramsHash(action: p.action, tuple: p.tuple) }

  public static func challenge(nonce: Data, action: String, paramsHash: Data) throws(SigningMessageError) -> Data {
    sha256(
      Domain.stepUp.prefix + (try SigningMessage.check(nonce, 32, "nonce")) + Data(action.utf8) + [0]
        + (try SigningMessage.check(paramsHash, 32, "params_hash")))
  }

  public static func challenge(nonce: Data, params: StepUpParams) throws(SigningMessageError) -> Data {
    try params.validate()
    return try challenge(nonce: nonce, action: params.action, paramsHash: paramsHash(params))
  }

  public static func serverChallengeMatches(_ serverChallenge: Data, nonce: Data, params: StepUpParams) -> Bool {
    guard let mine = try? challenge(nonce: nonce, params: params) else { return false }
    return constantTimeEquals(mine, serverChallenge)
  }
}
