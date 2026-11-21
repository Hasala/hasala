import CoreAuth
import CoreCrypto
import CorePrimitives
import CoreStore
import CoreWire
import Foundation

public struct NewDevice: @unchecked Sendable {
  public let writerID: WriterID
  public let dwkSeed: SecureBytes
  public let dwkPublic: Data
  public let dakPublic: Data

  public static func mint(_ env: AccountEnvironment, userID: UserID) async throws(CeremonyError) -> NewDevice {
    let w: WriterID
    do { w = try WriterID.mint(random: env.random) } catch { throw .crypto("writer id") }
    let (seed, pub) = DWK.generate()
    let dak: Data
    do { dak = try await env.approvalKeys.create(userID: userID, writerID: w) } catch { throw .approvalKey(error) }
    guard DAK.isValidPublicKey(dak) else { throw .approvalKey(.unavailable) }
    try secretStep { () throws(SecretStoreError) in try env.secrets.writeWriterSeed(seed, userID: userID, writerID: w) }
    return NewDevice(writerID: w, dwkSeed: seed, dwkPublic: pub, dakPublic: dak)
  }

  static func registeredOnThisSession(_ env: AccountEnvironment, userID: UserID, bearer: String)
    async throws(CeremonyError) -> NewDevice?
  {
    let session = try await apiStep { () async throws(APIError) in try await env.client.session(bearer: bearer) }
    guard let w = session.writer_id.flatMap({ WriterID($0) }) else { return nil }
    return try held(env, userID: userID, writerID: w)
  }

  static func heldRegistration(_ env: AccountEnvironment) async throws(CeremonyError) -> SigningWriter? {
    guard let held = try secretStep({ () throws(SecretStoreError) in try env.secrets.session() }), !held.pending_logout,
      let userID = UserID(held.user_id)
    else { return nil }
    let session: SessionInfo
    do {
      session = try await env.client.session(bearer: held.token)
    } catch {
      if let status = error.failure?.status, status < 500 { return nil }
      throw .api(error)
    }
    guard let w = session.writer_id.flatMap({ WriterID($0) }),
      let device = try Self.held(env, userID: userID, writerID: w)
    else { return nil }
    device.dwkSeed.wipe()
    return SigningWriter(userID: userID, writerID: w)
  }

  private static func held(_ env: AccountEnvironment, userID: UserID, writerID w: WriterID) throws(CeremonyError)
    -> NewDevice?
  {
    let binding = try secretStep { () throws(SecretStoreError) in try env.secrets.binding() }
    guard binding?.writerID != w else { return nil }
    guard
      let seed = try secretStep({ () throws(SecretStoreError) in try env.secrets.writerSeed(userID: userID, writerID: w) })
    else { return nil }
    let dak: Data
    do {
      dak = try env.approvalKeys.publicKeyX963(userID: userID, writerID: w)
    } catch {
      seed.wipe()
      if error == .missing { return nil }
      throw .approvalKey(error)
    }
    do {
      return NewDevice(writerID: w, dwkSeed: seed, dwkPublic: try Ed25519.publicKey(seed: seed), dakPublic: dak)
    } catch {
      seed.wipe()
      throw .crypto("writer key")
    }
  }
}

public enum Enrolment {
  static func published(_ env: AccountEnvironment, userID: UserID, bearer: String) async throws(CeremonyError)
    -> (PublishedAccountKeys, recoveryWrap: Data, epoch: UInt32)
  {
    let k = try await apiStep { () async throws(APIError) in try await env.client.keys(bearer: bearer) }
    let p = PublishedAccountKeys(
      userID: userID, recoveryPublicKey: try b64(k.recovery_pubkey, "recovery_pubkey"),
      amkCommitment: try b64(k.amk_commitment, "amk_commitment"),
      authorityPublicKey: try b64(k.authority_pubkey, "authority_pubkey"))
    guard k.current_epoch >= 1, k.current_epoch <= Int(Int32.max) else { throw .badResponse("current_epoch") }
    return (p, try b64(k.recovery_wrap, "recovery_wrap"), UInt32(k.current_epoch))
  }

  public static func unlockWithPhrase(_ env: AccountEnvironment, userID: UserID, typed: String)
    async throws(CeremonyError) -> KeyBody
  {
    let entropy: SecureBytes
    do { entropy = try Phrase.entropy(typed: typed) } catch { throw .badPhrase }
    defer { entropy.wipe() }
    let bearer = try AccountCreation.currentBearer(env)
    let (p, wrap, _) = try await published(env, userID: userID, bearer: bearer)
    do {
      return try AccountUnlock.withPhrase(entropy: entropy, recoveryWrap: wrap, published: p)
    } catch {
      switch error {
      case .notThisAccountsPhrase: throw .notThisAccountsPhrase
      case .accountKeysMismatch, .phraseBoxMismatch: throw .integrityAlarm("commitments")
      default: throw .notThisAccountsPhrase
      }
    }
  }

  public static func unlockWithPRF(
    _ env: AccountEnvironment, userID: UserID, credentialID: Data, prf: SecureBytes?
  ) async throws(CeremonyError) -> KeyBody {
    guard let prf else { throw .noPRF }
    let bearer = try AccountCreation.currentBearer(env)
    let (p, _, _) = try await published(env, userID: userID, bearer: bearer)
    let wraps = try await apiStep { () async throws(APIError) in try await env.client.keyWraps(bearer: bearer) }
    let id = Base64.encodeURL(credentialID)
    guard let w = wraps.wraps.first(where: { $0.credential_id == id }) else { throw .noPRF }
    do {
      return try AccountUnlock.withPRF(
        prfOutput: prf, credentialID: credentialID, prfWrap: try b64(w.wrap, "wrap"), published: p)
    } catch let e as CeremonyError {
      throw e
    } catch {
      if case .accountKeysMismatch = error as? UnwrapError { throw .integrityAlarm("commitments") }
      throw .noPRF
    }
  }

  public static func enrolWriter(
    _ env: AccountEnvironment, userID: UserID, body: KeyBody, emailNorm: String?, serverSalt: Data?,
    displayName: String? = nil
  ) async throws(CeremonyError) -> EnrolledAccount {
    let bearer = try AccountCreation.currentBearer(env)
    var email = emailNorm
    var salt = serverSalt
    var name = displayName
    let signedUpAs = try AccountCreation.signupAddress(env)
    if email == nil || salt == nil || name == nil || signedUpAs != nil {
      let a = try await apiStep { () async throws(APIError) in try await env.client.account(bearer: bearer) }
      if let signedUpAs { try AccountCreation.compareSignupAddress(env, reported: a.email, signedUpAs: signedUpAs) }
      if email == nil { email = a.email.flatMap { try? EmailNorm.normalize($0) } }
      if salt == nil { salt = a.password_salt.flatMap { try? Base64.decode($0) } }
      if name == nil { name = a.display_name }
    }
    guard let email, let salt else { throw .badResponse("account email or salt") }
    let device: NewDevice
    if let registered = try await NewDevice.registeredOnThisSession(env, userID: userID, bearer: bearer) {
      device = registered
    } else {
      device = try await NewDevice.mint(env, userID: userID)
      try await register(env, device: device, body: body, bearer: bearer)
    }
    let k1 = try cryptoStep("K_1") { try body.epochKey1(userID: userID) }
    defer { k1.wipe() }
    let aak = try cryptoStep("aak") { try body.authorityPublicKey() }
    return try await persist(
      env, userID: userID, device: device, epochKey: k1, emailNorm: email, serverSalt: salt, displayName: name,
      authorityPublicKey: aak)
  }

  static func register(_ env: AccountEnvironment, device: NewDevice, body: KeyBody, bearer: String)
    async throws(CeremonyError)
  {
    let challenge = try await apiStep { () async throws(APIError) in try await env.client.writerChallenge(bearer: bearer) }
    let nonce = try b64(challenge.nonce, "writer nonce")
    let sig = try cryptoStep("registration") {
      try body.signWithAuthority(
        try SigningMessage.registration(
          nonce: nonce, writerID: device.writerID, dwkPublicKey: device.dwkPublic, dakPublicKey: device.dakPublic))
    }
    let r = try await apiStep { () async throws(APIError) in
      try await env.client.writerRegister(
        WriterRegisterRequest(
          writerID: device.writerID.string, pubkeyB64: Base64.encode(device.dwkPublic),
          dakPubkeyB64: Base64.encode(device.dakPublic), nonceB64: Base64.encode(nonce), sigB64: Base64.encode(sig)),
        bearer: bearer)
    }
    guard r.writer_id == device.writerID.string else { throw .badResponse("register writer_id") }
  }

  static func persist(
    _ env: AccountEnvironment, userID: UserID, device: NewDevice, epochKey: SecureBytes, emailNorm: String,
    serverSalt: Data, displayName: String?, authorityPublicKey: Data,
    beforeBinding: (@Sendable () async throws(CeremonyError) -> Void)? = nil
  ) async throws(CeremonyError) -> EnrolledAccount {
    try secretStep { () throws(SecretStoreError) in
      try env.secrets.writeEpochKey(epochKey, userID: userID, epoch: 1)
    }
    device.dwkSeed.wipe()
    let bearer = try AccountCreation.currentBearer(env)
    let meta = try? await env.client.meta()
    var store = try env.openStore(for: userID)
    if let old = try? store.meta(), old.writerID != device.writerID || old.userID != userID,
      let dir = env.storeDirectory(for: userID)
    {
      do { try FileManager.default.removeItem(at: dir) } catch { throw .store(.corrupt("earlier writer's store")) }
      store = try env.openStore(for: userID)
    }
    do {
      if try store.meta() == nil {
        try store.create(
          StoreMeta(
            userID: userID, writerID: device.writerID, apiBase: env.apiBase, keyEpoch: 1, createdAt: env.clock.nowMs()),
          epochHWM: 1, logGeneration: meta?.log_generation.flatMap { $0 >= 1 ? $0 : nil })
      }
    } catch {
      throw .store(error)
    }
    var roster = PinnedRoster(authorityPublicKey: authorityPublicKey, roster: .empty)
    do {
      roster = try await RosterService.fetch(client: env.client, bearer: bearer, authorityPublicKey: authorityPublicKey)
      guard let own = roster.writers[device.writerID.string], own.final_counter == nil,
        own.dwk == Base64.encode(device.dwkPublic), own.dak == Base64.encode(device.dakPublic)
      else {
        throw CeremonyError.integrityAlarm("own writer not in key history")
      }
    } catch let e as CeremonyError {
      throw e
    } catch {
      if case .halted? = error as? SyncStop { throw .integrityAlarm("key history") }
    }
    do { try store.setRoster(roster.encoded()) } catch { throw .store(error) }
    if let beforeBinding { try await beforeBinding() }
    let binding = AccountBinding(
      userID: userID, writerID: device.writerID, apiBase: env.apiBase, keyEpoch: 1, emailNorm: emailNorm,
      serverSalt: serverSalt, displayName: displayName)
    try secretStep { () throws(SecretStoreError) in try env.secrets.writeBinding(binding) }
    return EnrolledAccount(userID: userID, writerID: device.writerID, store: store, binding: binding)
  }

  public static func context(
    _ env: AccountEnvironment, binding: AccountBinding, build: String? = nil
  ) throws(CeremonyError) -> SyncContext {
    guard let u = binding.userID, let w = binding.writerID else { throw .badResponse("binding ids") }
    let store = try env.openStore(for: u)
    return SyncContext(
      userID: u, writerID: w, store: store, secrets: env.secrets, client: env.client, clock: env.clock,
      random: env.random, build: build)
  }

  public static func context(_ env: AccountEnvironment, account: EnrolledAccount, build: String? = nil) -> SyncContext {
    SyncContext(
      userID: account.userID, writerID: account.writerID, store: account.store, secrets: env.secrets,
      client: env.client, clock: env.clock, random: env.random, build: build)
  }
}
