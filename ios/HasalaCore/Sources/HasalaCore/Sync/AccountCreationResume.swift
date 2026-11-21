import CoreAuth
import CoreCrypto
import CorePrimitives
import CoreStore
import CoreWire
import Foundation

extension AccountCreation {
  public static func bootstrapInterrupted(_ env: AccountEnvironment, keys: NewAccountKeys)
    async throws(CeremonyError) -> EnrolledAccount
  {
    let bearer = try currentBearer(env)
    let account = try await apiStep { () async throws(APIError) in try await env.client.account(bearer: bearer) }
    guard let user = UserID(account.user_id) else { throw .badResponse("account user_id") }
    guard let email = account.email.flatMap({ try? EmailNorm.normalize($0) }),
      let salt = account.password_salt.flatMap({ try? Base64.decode($0) })
    else { throw .badResponse("account email or salt") }
    if let signedUpAs = try signupAddress(env), signedUpAs != email { throw .integrityAlarm("address differs from signup") }
    let aak = try keys.authorityPublicKey()
    let proof = try await StepUpHelper.prove(
      env, params: .keysBootstrap(authorityPublicKey: aak), factor: .passkey, binding: nil,
      reason: "Confirm it's you to finish setting up")
    defer { proof.prf?.wipe() }
    let device = try await NewDevice.mint(env, userID: user)
    var prfWrap: (Data, Data)?
    if let p = proof.prf, let id = proof.credentialID {
      let w = try cryptoStep("prf wrap") {
        try Wrap.sealPRF(body: keys.body, prfOutput: p, userID: user, credentialID: id, random: env.random)
      }
      prfWrap = (id, w)
    }
    let challenge = try await apiStep { () async throws(APIError) in try await env.client.writerChallenge(bearer: bearer) }
    let nonce = try b64(challenge.nonce, "writer nonce")
    var body = try buildBootstrap(
      env, userID: user, emailNorm: email, keys: keys, device: device, authKind: .none, authHash: Data(count: 32),
      prfWrap: prfWrap, nonce: nonce)
    body.step_up = proof.stepUp
    let r = try await apiStep { () async throws(APIError) in try await env.client.bootstrap(body, bearer: bearer) }
    guard r.writer_id == device.writerID.string else { throw .badResponse("bootstrap writer_id") }
    let grant = SessionGrant(
      session_token: bearer, user_id: user.string, expires_at: nil, writer_id: r.writer_id, has_keys: true,
      restricted: false)
    return try await persistAndCompare(
      env, grant: grant, userID: user, device: device, keys: keys, emailNorm: email, serverSalt: salt,
      displayName: account.display_name, recoveryWrap: body.recovery_wrap, recoveryPublicKey: body.recovery_pubkey,
      sessionAlreadyWritten: true)
  }
}
