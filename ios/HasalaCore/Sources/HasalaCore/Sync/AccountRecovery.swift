import CoreAuth
import CoreCrypto
import CorePrimitives
import CoreStore
import CoreWire
import Foundation

public final class Recovery: @unchecked Sendable {
  public let ceremonyID: String
  public let emailHint: String
  let entropy: SecureBytes
  let recoveryPublicKey: Data
  fileprivate(set) var verified: Verified?
  fileprivate var grant: SessionGrant?

  struct Verified {
    let nonce: Data
    let userID: UserID
    let body: KeyBody
    let way: Way
  }

  enum Way {
    case passkey(CreationOptions)
    case password(serverSalt: Data, emailNorm: String)
  }

  init(ceremonyID: String, emailHint: String, entropy: SecureBytes, recoveryPublicKey: Data) {
    self.ceremonyID = ceremonyID
    self.emailHint = emailHint
    self.entropy = entropy
    self.recoveryPublicKey = recoveryPublicKey
  }

  public var userID: UserID? { verified?.userID }

  public func canFinish(after error: CeremonyError) -> Bool {
    switch error.failureClass {
    case .cancelled: true
    case .integrity: false
    default: grant != nil
    }
  }

  public func wipe() {
    entropy.wipe()
    verified?.body.wipe()
    grant = nil
  }
}

public enum AccountRecovery {
  public static func begin(_ env: AccountEnvironment, typed: String) async throws(CeremonyError) -> Recovery {
    let entropy: SecureBytes
    do { entropy = try Phrase.entropy(typed: typed) } catch { throw .badPhrase }
    let rk: Data
    do { rk = try KeyDerivation.recoveryPublicKey(entropy: entropy) } catch {
      entropy.wipe()
      throw .crypto("recovery key")
    }
    do {
      let r: RecoverBeginAnswer = try await env.client.api.call(
        .post, "/api/v1/auth/recover/begin", json: RecoverBeginBody(recovery_pubkey: Base64.encode(rk)))
      return Recovery(ceremonyID: r.ceremony_id, emailHint: r.email_hint, entropy: entropy, recoveryPublicKey: rk)
    } catch {
      entropy.wipe()
      throw .api(error)
    }
  }

  public static func verifyForPasskey(_ env: AccountEnvironment, _ r: Recovery, code: String)
    async throws(CeremonyError)
  {
    try await verify(env, r, code: code, kind: "passkey") { (a) throws(CeremonyError) in
      guard let wire = a.options, let options = try? wire.decoded() else { throw .badResponse("recover options") }
      return .passkey(options)
    }
  }

  public static func verifyForPassword(_ env: AccountEnvironment, _ r: Recovery, code: String)
    async throws(CeremonyError)
  {
    try await verify(env, r, code: code, kind: "password") { (a) throws(CeremonyError) in
      guard let salt = a.salt.flatMap({ try? Base64.decode($0) }), salt.count == 32 else {
        throw .badResponse("recover salt")
      }
      guard let email = a.email_norm, (try? EmailNorm.normalize(email)) == email else {
        throw .badResponse("recover email_norm")
      }
      return .password(serverSalt: salt, emailNorm: email)
    }
  }

  private static func verify(
    _ env: AccountEnvironment, _ r: Recovery, code: String, kind: String,
    way: (RecoverVerifyAnswer) throws(CeremonyError) -> Recovery.Way
  ) async throws(CeremonyError) {
    let a: RecoverVerifyAnswer = try await apiStep { () async throws(APIError) in
      try await env.client.api.call(
        .post, "/api/v1/auth/recover/verify",
        json: RecoverVerifyBody(ceremony_id: r.ceremonyID, code: code, kind: kind))
    }
    guard let user = UserID(a.user_id) else { throw .badResponse("recover user_id") }
    let nonce = try b64(a.nonce, "recover nonce")
    guard nonce.count == 32 else { throw .badResponse("recover nonce length") }
    let published = PublishedAccountKeys(
      userID: user, recoveryPublicKey: r.recoveryPublicKey, amkCommitment: try b64(a.amk_commitment, "amk_commitment"),
      authorityPublicKey: try b64(a.authority_pubkey, "authority_pubkey"))
    let body: KeyBody
    do {
      body = try AccountUnlock.withPhrase(
        entropy: r.entropy, recoveryWrap: try b64(a.recovery_wrap, "recovery_wrap"), published: published)
    } catch let e as CeremonyError {
      throw e
    } catch {
      throw .integrityAlarm("recovery commitments")
    }
    let verifiedWay: Recovery.Way
    do {
      verifiedWay = try way(a)
    } catch {
      body.wipe()
      throw error
    }
    r.verified?.body.wipe()
    r.verified = Recovery.Verified(nonce: nonce, userID: user, body: body, way: verifiedWay)
  }

  public static func finishWithPasskey(_ env: AccountEnvironment, _ r: Recovery) async throws(CeremonyError)
    -> EnrolledAccount
  {
    guard let v = r.verified, case .passkey(let options) = v.way else { throw .badResponse("recovery not verified") }
    let grant: SessionGrant
    if let held = r.grant {
      grant = held
    } else {
      grant = try await spendCeremony(env, r, v, options)
      r.grant = grant
    }
    try AccountCreation.writeSession(env, grant)
    let enrolled = try await Enrolment.enrolWriter(env, userID: v.userID, body: v.body, emailNorm: nil, serverSalt: nil)
    r.wipe()
    return enrolled
  }

  public static func finishWithPassword(_ env: AccountEnvironment, _ r: Recovery, password: String)
    async throws(CeremonyError) -> EnrolledAccount
  {
    guard let v = r.verified, case .password(let salt, let email) = v.way else {
      throw .badResponse("recovery not verified")
    }
    let grant: SessionGrant
    if let held = r.grant {
      grant = held
    } else {
      grant = try await spendCeremony(env, r, v, password: password, serverSalt: salt, emailNorm: email)
      r.grant = grant
    }
    try AccountCreation.writeSession(env, grant)
    let enrolled = try await Enrolment.enrolWriter(env, userID: v.userID, body: v.body, emailNorm: email, serverSalt: salt)
    r.wipe()
    return enrolled
  }

  private static func spendCeremony(
    _ env: AccountEnvironment, _ r: Recovery, _ v: Recovery.Verified, password: String, serverSalt: Data,
    emailNorm: String
  ) async throws(CeremonyError) -> SessionGrant {
    let s: SecureBytes
    do { s = try PasswordStretch.stretch(password: password, serverSalt: serverSalt, emailNorm: emailNorm) } catch {
      throw .crypto("stretch")
    }
    defer { s.wipe() }
    let device = try await NewDevice.mint(env, userID: v.userID)
    defer { device.dwkSeed.wipe() }
    let (rkSig, registrationSig) = try cryptoStep("recovery signatures") {
      let rkSeed = try KeyDerivation.recoveryKeySeed(entropy: r.entropy)
      defer { rkSeed.wipe() }
      let rkSig = try Ed25519.sign(
        seed: rkSeed, message: try SigningMessage.recoverySigninPassword(nonce: v.nonce, newVerifier: s))
      let registrationSig = try v.body.signWithAuthority(
        try SigningMessage.registration(
          nonce: v.nonce, writerID: device.writerID, dwkPublicKey: device.dwkPublic, dakPublicKey: device.dakPublic))
      return (rkSig, registrationSig)
    }
    let w = WriterJSON(
      writerID: device.writerID.string, pubkeyB64: Base64.encode(device.dwkPublic),
      dakPubkeyB64: Base64.encode(device.dakPublic))
    let body = RecoverFinishBody(
      ceremony_id: r.ceremonyID, kind: "password", credential: nil, prf_wrap: nil,
      verifier: s.withUnsafeBytes { Base64.encode($0) }, rk_sig: Base64.encode(rkSig),
      writer: RecoverWriterBody(
        writer_id: w.writer_id, alg: w.alg, pubkey: w.pubkey, dak_pubkey: w.dak_pubkey,
        registration_sig: Base64.encode(registrationSig)))
    let grant: SessionGrant = try await apiStep { () async throws(APIError) in
      try await env.client.api.call(.post, "/api/v1/auth/recover/finish", json: body)
    }
    guard grant.user_id == v.userID.string, grant.writer_id == device.writerID.string else {
      throw .badResponse("recover session")
    }
    return grant
  }

  private static func spendCeremony(
    _ env: AccountEnvironment, _ r: Recovery, _ v: Recovery.Verified, _ options: CreationOptions
  ) async throws(CeremonyError) -> SessionGrant {
    guard let passkeys = env.passkeys else { throw .passkey(.unsupported) }
    let device = try await NewDevice.mint(env, userID: v.userID)
    defer { device.dwkSeed.wipe() }
    let reg: RawRegistration
    do { reg = try await passkeys.register(options, prfSalt: KeyDerivation.prfSalt) } catch { throw .passkey(error) }
    defer { reg.prfFirst?.wipe() }
    var prfWrap: Data?
    if let p = reg.prfFirst {
      prfWrap = try cryptoStep("prf wrap") {
        try Wrap.sealPRF(body: v.body, prfOutput: p, userID: v.userID, credentialID: reg.credentialID, random: env.random)
      }
    }
    let (rkSig, registrationSig) = try cryptoStep("recovery signatures") {
      let rkSeed = try KeyDerivation.recoveryKeySeed(entropy: r.entropy)
      defer { rkSeed.wipe() }
      let rkSig = try Ed25519.sign(
        seed: rkSeed,
        message: try SigningMessage.recoverySigninPasskey(
          nonce: v.nonce, clientDataJSON: reg.rawClientDataJSON, attestationObject: reg.rawAttestationObject,
          prfWrap: prfWrap))
      let registrationSig = try v.body.signWithAuthority(
        try SigningMessage.registration(
          nonce: v.nonce, writerID: device.writerID, dwkPublicKey: device.dwkPublic, dakPublicKey: device.dakPublic))
      return (rkSig, registrationSig)
    }
    let w = WriterJSON(
      writerID: device.writerID.string, pubkeyB64: Base64.encode(device.dwkPublic),
      dakPubkeyB64: Base64.encode(device.dakPublic))
    let grant: SessionGrant = try await passkeyFinishStep(env, credentialID: reg.credentialID) { () async throws(APIError) in
      try await env.client.api.call(
        .post, "/api/v1/auth/recover/finish",
        json: RecoverFinishBody(
          ceremony_id: r.ceremonyID, kind: "passkey", credential: reg.credential,
          prf_wrap: prfWrap.map {
            BootstrapPRFWrapJSON(credentialIDB64URL: Base64.encodeURL(reg.credentialID), wrapB64: Base64.encode($0))
          },
          verifier: nil, rk_sig: Base64.encode(rkSig),
          writer: RecoverWriterBody(
            writer_id: w.writer_id, alg: w.alg, pubkey: w.pubkey, dak_pubkey: w.dak_pubkey,
            registration_sig: Base64.encode(registrationSig))))
    }
    guard grant.user_id == v.userID.string, grant.writer_id == device.writerID.string else {
      throw .badResponse("recover session")
    }
    return grant
  }
}

struct RecoverBeginBody: Encodable, Sendable {
  let recovery_pubkey: String
}

struct RecoverBeginAnswer: Decodable, Sendable {
  let ceremony_id: String
  let email_hint: String
}

struct RecoverVerifyBody: Encodable, Sendable {
  let ceremony_id: String
  let code: String
  let kind: String
}

struct RecoverVerifyAnswer: Decodable, Sendable {
  let nonce: String
  let user_id: String
  let amk_commitment: String
  let authority_pubkey: String
  let recovery_wrap: String
  let current_epoch: Int
  let options: WireCreationOptions?
  let salt: String?
  let email_norm: String?
}

struct RecoverWriterBody: Encodable, Sendable {
  let writer_id: String
  let alg: String
  let pubkey: String
  let dak_pubkey: String
  let registration_sig: String
}

struct RecoverFinishBody: Encodable, Sendable {
  let ceremony_id: String
  let kind: String
  let credential: PublicKeyCredentialJSON?
  let prf_wrap: BootstrapPRFWrapJSON?
  let verifier: String?
  let rk_sig: String
  let writer: RecoverWriterBody
}
