import CoreAuth
import CoreCrypto
import CorePrimitives
import CoreStore
import CoreSync
import CoreTime
import Foundation
import os

@MainActor
final class LiveAccountService: AccountService {
  let env: AccountEnvironment
  let build: BuildInfo?
  var endGrant: (@Sendable (_ held: HeldMailGrants, _ stopWatch: Bool) async -> Void)?
  var grantEnds = MailGrantEnds.shared
  var hooks = LiveAccountHooks()
  var bankTextFacts = BankTextsFacts.shared
  var bankTextMarker = LockedTextsMarkerFile.shared
  var setupDefaults = UserDefaults.standard

  var capabilities: AccountCapabilities { .beta }
  private(set) var profile: AccountProfile?
  private var methodConfirmed = false
  private(set) var enrolled: EnrolledAccount?

  private var signup: Signup?
  private var keys: NewAccountKeys?
  private var registered: RegisteredPasskey?
  private var signIn: SignInResult?
  private var recovery: Recovery?
  private var unlockBody: KeyBody?

  init(env: AccountEnvironment, build: BuildInfo? = nil) {
    self.env = env
    self.build = build
    if let build {
      endGrant = { @Sendable held, stopWatch in
        await MailboxLane.endGrant(held, build: build, stopWatch: stopWatch)
      }
    }
  }

  func loadProfile() {
    guard let b = binding else { return }
    profile = AccountProfile(displayName: b.display_name ?? "", email: b.email_norm, method: .passkey)
    methodConfirmed = false
  }

  private var binding: AccountBinding? { try? env.secrets.binding() }

  private func heldBinding() throws(AuthFailure) -> AccountBinding? {
    do { return try env.secrets.binding() } catch { throw .refused }
  }

  var keysOnThisIPhone: Bool {
    do { return try env.secrets.binding() != nil } catch { return true }
  }

  private func otherAccountHere(_ b: AccountBinding) -> AuthFailure {
    hooks.otherAccountHere(b.email_norm)
    return .cancelled
  }

  func beginSignup(code: InviteCode, linkKey: String?, email: String, displayName: String)
    async throws(AuthFailure) -> SignupTicket
  {
    if let b = try heldBinding() { throw otherAccountHere(b) }
    await Self.retryPendingLogout(env)
    do {
      let s = try await AccountCreation.beginSignup(
        env, inviteCode: code.value, email: email, displayName: displayName, inviteLinkKey: linkKey)
      signup = s
      inviteCode = code.value
      codeTries = 5
      keys?.wipe()
      keys = nil
      registered = nil
      return SignupTicket(id: s.id, emailProven: s.emailProven, email: s.emailNorm, displayName: s.displayName,
                          startedAt: .now)
    } catch {
      throw Self.map(error)
    }
  }

  private var codeTries = 5

  func verifySignupEmail(_ ticket: SignupTicket, code: String) async throws(AuthFailure) {
    guard let s = signup, s.id == ticket.id else { throw .refused }
    do {
      try await AccountCreation.verifySignup(env, s, code: code)
      codeTries = 5
    } catch {
      if error.failureClass == .codeRejected {
        codeTries -= 1
        if codeTries <= 0 || ticket.codeExpired(now: .now) { throw .codeExpired }
        throw .codeWrong(triesLeft: codeTries)
      }
      throw Self.map(error)
    }
  }

  private var inviteCode: String?

  func resendSignupCode(_ ticket: SignupTicket) async throws(AuthFailure) -> SignupTicket {
    guard let code = inviteCode, let invite = InviteCode(code) else { throw .refused }
    return try await beginSignup(code: invite, linkKey: nil, email: ticket.email, displayName: ticket.displayName)
  }

  private func freshKeys() throws(AuthFailure) -> NewAccountKeys {
    if let keys { return keys }
    do {
      let k = try NewAccountKeys.generate(random: env.random)
      keys = k
      return k
    } catch {
      throw Self.map(error)
    }
  }

  @discardableResult func registerPasskey(_ ticket: SignupTicket) async throws(AuthFailure) -> NewPasskey {
    guard let s = signup, s.id == ticket.id else { throw .refused }
    let k = try freshKeys()
    do {
      let r = try await AccountCreation.registerPasskey(env, signup: s, keys: k)
      registered = r
      return NewPasskey(prf: r.prf != nil, synced: r.backup?.synced == true)
    } catch {
      throw Self.map(error)
    }
  }

  func makeRecoveryPhrase() throws(AuthFailure) -> RecoveryPhrase {
    let k = try freshKeys()
    do {
      return RecoveryPhrase(words: try k.words())
    } catch {
      throw .unsupported
    }
  }

  func finishAccount(_ ticket: SignupTicket, credential: NewCredential, phrase: RecoveryPhrase)
    async throws(AuthFailure) -> AccountProfile
  {
    try await finish(ticket, credential: credential, phraseUnseen: false)
  }

  func finishAccountWithoutWords(_ ticket: SignupTicket) async throws(AuthFailure) -> AccountProfile {
    guard let r = registered, r.prf != nil, r.backup?.synced == true else { throw .refused }
    return try await finish(ticket, credential: .passkey, phraseUnseen: true)
  }

  private func finish(_ ticket: SignupTicket, credential: NewCredential, phraseUnseen: Bool)
    async throws(AuthFailure) -> AccountProfile
  {
    guard let s = signup, s.id == ticket.id, let k = keys else { throw .refused }
    do {
      switch credential {
      case .passkey:
        guard let r = registered else { throw AuthFailure.refused }
        enrolled = try await AccountCreation.bootstrapPasskey(env, registered: r, keys: k, phraseUnseen: phraseUnseen)
        r.prf?.wipe()
      case .password(let pw):
        enrolled = try await AccountCreation.createWithPassword(env, signup: s, password: pw, keys: k)
      }
    } catch let e as AuthFailure {
      throw e
    } catch let e as CeremonyError {
      throw Self.finishFailure(e, phraseUnseen: phraseUnseen)
    } catch {
      throw .refused
    }
    keys = nil
    registered = nil
    signup = nil
    let p = AccountProfile(displayName: s.displayName, email: s.emailNorm, method: credential.method)
    profile = p
    methodConfirmed = true
    return p
  }

  private func outcome(_ r: SignInResult, bound: AccountBinding?) async throws(AuthFailure) -> SignInOutcome {
    signIn = r
    if r.restricted { return .frozen(await freezeInfo(token: r.grant.session_token)) }
    if !r.hasKeys { return .needsKeys }
    if let b = bound, b.user_id == r.grant.user_id, let u = b.userID {
      do {
        if try env.secrets.epochKey(userID: u, epoch: b.key_epoch) != nil { return .ready }
      } catch {
        throw .refused
      }
    }
    let offer = await AccountSignIn.passkeyUnlockOffer(env, after: r)
    signIn = offer.signIn
    return .needsUnlock(passkeyCanUnlock: offer.canUnlock)
  }

  func signInWithPasskey() async throws(AuthFailure) -> SignInOutcome {
    let stale = await Self.retryPendingLogout(env)
    let bound = try heldBinding()
    let r: SignInResult
    do {
      r = try await AccountSignIn.withPasskey(env, bound: bound, wantPRF: true)
    } catch {
      switch error.failureClass {
      case .rejected:
        guard let bound else { throw .orphanedPasskey }
        throw otherAccountHere(bound)
      case .otherAccountDevice:
        if let bound { throw otherAccountHere(bound) }
      case .deviceRefused:
        if bound != nil {
          hooks.deviceUnenrolled()
          throw .cancelled
        }
      default:
        break
      }
      throw Self.map(error)
    }
    profile = AccountProfile(displayName: bound?.display_name ?? "", email: bound?.email_norm ?? "", method: .passkey)
    methodConfirmed = true
    Self.logOutLater(stale, env)
    return try await outcome(r, bound: bound)
  }

  func signInWithPassword(email: String, password: String) async throws(AuthFailure) -> SignInOutcome {
    let bound = try heldBinding()
    if let bound, let typed = try? EmailNorm.normalize(email), typed != bound.email_norm {
      throw otherAccountHere(bound)
    }
    let stale = await Self.retryPendingLogout(env)
    let r: SignInResult
    do {
      r = try await AccountSignIn.withPassword(env, email: email, password: password, bound: bound)
    } catch {
      throw Self.map(error)
    }
    profile = AccountProfile(displayName: bound?.display_name ?? "", email: r.emailNorm ?? email, method: .password)
    methodConfirmed = true
    Self.logOutLater(stale, env)
    return try await outcome(r, bound: bound)
  }

  @discardableResult
  static func retryPendingLogout(_ env: AccountEnvironment) async -> String? {
    guard let s = try? env.secrets.session(), s.pending_logout else { return nil }
    do {
      try await env.client.logout(bearer: s.token)
    } catch {
      if error.failure?.status != 401 { return s.token }
    }
    if let now = try? env.secrets.session(), now.token == s.token { try? env.secrets.deleteSession() }
    return nil
  }

  private static func logOutLater(_ token: String?, _ env: AccountEnvironment) {
    guard let token else { return }
    Task { try? await env.client.logout(bearer: token) }
  }

  private var signedInUser: UserID? {
    if let u = signIn?.userID { return u }
    guard let s = try? env.secrets.activeSession() else { return nil }
    return UserID(s.user_id)
  }

  func unlockWithPasskey() async throws(AuthFailure) {
    do {
      let assertion: CoreAuth.RawAssertion
      if let a = signIn?.assertion, a.prfFirst != nil {
        assertion = a
      } else {
        let again = try await AccountSignIn.forPasskeyUnlock(env)
        signIn = again
        guard let a = again.assertion else { throw CeremonyError.noPRF }
        assertion = a
      }
      guard let user = signIn?.userID else { throw AuthFailure.refused }
      let body = try await Enrolment.unlockWithPRF(
        env, userID: user, credentialID: assertion.credentialID, prf: assertion.prfFirst)
      defer { body.wipe() }
      try await enrolThisIPhone(user, body: body)
      assertion.prfFirst?.wipe()
    } catch let e as AuthFailure {
      throw e
    } catch let e as CeremonyError {
      if case .noPRF = e { throw .noCredential }
      throw Self.map(e)
    } catch {
      throw .refused
    }
  }

  func unlockWithPhrase(_ words: [String]) async throws(AuthFailure) {
    guard let user = signedInUser else { throw .refused }
    do {
      let body = try await Enrolment.unlockWithPhrase(env, userID: user, typed: words.joined(separator: " "))
      defer { body.wipe() }
      try await enrolThisIPhone(user, body: body)
      endUnlockOffer()
      if profile?.method == .password { unlockBody = try? KeyBody(amk: body.amk, aakSeed: body.aakSeed) }
    } catch {
      throw Self.map(error)
    }
  }

  private func enrolThisIPhone(_ user: UserID, body: KeyBody) async throws(CeremonyError) {
    enrolled = try await Enrolment.enrolWriter(
      env, userID: user, body: body, emailNorm: signIn?.emailNorm, serverSalt: signIn?.serverSalt)
    LocalAccountData.markSetupFinished(setupDefaults)
    refreshProfile()
  }

  func endUnlockOffer() {
    unlockBody?.wipe()
    unlockBody = nil
  }

  func resumeSignedIn() async throws(AuthFailure) -> SignInOutcome {
    let stored: SessionRecord?
    do { stored = try env.secrets.activeSession() } catch { throw .offline }
    guard let s = stored else { throw .refused }
    let a: AccountInfo
    do {
      a = try await env.client.account(bearer: s.token)
    } catch {
      throw Self.map(CeremonyError.api(error))
    }
    profile = AccountProfile(
      displayName: a.display_name ?? binding?.display_name ?? "", email: a.email ?? binding?.email_norm ?? "",
      method: a.has_passkey == true ? .passkey : .password)
    methodConfirmed = a.has_passkey != nil
    if let freeze = Self.freeze(a, nowMs: env.clock.nowMs()) { return .frozen(freeze) }
    guard a.has_keys == true else { return .needsKeys }
    let wraps = (try? await env.client.keyWraps(bearer: s.token).wraps.count) ?? 0
    return .needsUnlock(passkeyCanUnlock: wraps > 0)
  }

  func finishInterruptedSetup(phrase: RecoveryPhrase) async throws(AuthFailure) -> AccountProfile {
    guard let k = keys else { throw .refused }
    do {
      enrolled = try await AccountCreation.bootstrapInterrupted(env, keys: k)
    } catch {
      throw Self.map(error)
    }
    keys = nil
    let b = binding
    let p = AccountProfile(displayName: b?.display_name ?? profile?.displayName ?? "",
                           email: b?.email_norm ?? profile?.email ?? "", method: .passkey)
    profile = p
    return p
  }

  func noteAccount(_ a: AccountInfo) {
    guard let b = binding, a.user_id == b.user_id else { return }
    profile = AccountProfile(
      displayName: a.display_name ?? b.display_name ?? profile?.displayName ?? "",
      email: a.email ?? b.email_norm, method: a.has_passkey == true ? .passkey : .password)
    methodConfirmed = true
  }

  func usesPasskey() async -> Bool {
    if !methodConfirmed, let token = try? env.secrets.activeSession()?.token,
      let a = try? await env.client.account(bearer: token)
    {
      noteAccount(a)
    }
    return profile?.method == .passkey
  }

  private func refreshProfile() {
    guard let b = binding else { return }
    profile = AccountProfile(displayName: b.display_name ?? "", email: b.email_norm, method: profile?.method ?? .passkey)
  }

  func updateDisplayName(_ name: String) async throws(AuthFailure) -> String {
    guard let valid = AccountFields.displayName(name) else { throw .badName }
    guard let token = try? env.secrets.activeSession()?.token else { throw .refused }
    do {
      try await env.client.setDisplayName(valid, bearer: token)
    } catch {
      throw Self.map(CeremonyError.api(error))
    }
    if var b = binding {
      b.display_name = valid
      try? env.secrets.writeBinding(b)
    }
    profile = AccountProfile(
      displayName: valid, email: profile?.email ?? binding?.email_norm ?? "", method: profile?.method ?? .passkey)
    return valid
  }

  func beginPasswordReset(email: String) async throws(AuthFailure) -> ResetTicket { throw .notInThisBuild }
  func verifyPasswordReset(_ ticket: ResetTicket, code: String) async throws(AuthFailure) -> ResetTicket {
    throw .notInThisBuild
  }
  func requestResetApproval(_ ticket: ResetTicket, newPassword: String) async throws(AuthFailure) -> ResetTicket {
    throw .notInThisBuild
  }
  func pollResetApproval(_ ticket: ResetTicket) async throws(AuthFailure) -> Bool { throw .notInThisBuild }
  func pendingResetRequest() async -> PendingReset? { nil }
  func approveReset(_ request: PendingReset, code: String) async throws(AuthFailure) { throw .notInThisBuild }

  func beginRecovery(words: [String]) async throws(AuthFailure) -> RecoveryTicket {
    await Self.retryPendingLogout(env)
    recovery?.wipe()
    recovery = nil
    do {
      let r = try await AccountRecovery.begin(env, typed: words.joined(separator: " "))
      recovery = r
      codeTries = 5
      return RecoveryTicket(id: r.ceremonyID, emailHint: r.emailHint)
    } catch {
      if error.failure?.status == 404 { throw .noAccountForPhrase }
      throw Self.map(error)
    }
  }

  func verifyRecovery(_ ticket: RecoveryTicket, code: String, kind: SignInMethod) async throws(AuthFailure) {
    guard let r = recovery, r.ceremonyID == ticket.id else { throw .refused }
    let held = try heldBinding()
    do {
      switch kind {
      case .passkey: try await AccountRecovery.verifyForPasskey(env, r, code: code)
      case .password: try await AccountRecovery.verifyForPassword(env, r, code: code)
      }
      codeTries = 5
    } catch {
      if error.failureClass == .codeRejected {
        codeTries -= 1
        if codeTries <= 0 { throw .codeExpired }
        throw .codeWrong(triesLeft: codeTries)
      }
      throw Self.map(error)
    }
    if let b = held, let user = r.userID, b.user_id != user.string {
      r.wipe()
      recovery = nil
      throw otherAccountHere(b)
    }
  }

  func finishRecovery(_ ticket: RecoveryTicket, credential: NewCredential) async throws(AuthFailure) {
    guard let r = recovery, r.ceremonyID == ticket.id, r.userID != nil else { throw .refused }
    do {
      switch credential {
      case .passkey: enrolled = try await AccountRecovery.finishWithPasskey(env, r)
      case .password(let password): enrolled = try await AccountRecovery.finishWithPassword(env, r, password: password)
      }
    } catch {
      if !r.canFinish(after: error) {
        r.wipe()
        recovery = nil
      }
      throw Self.map(error)
    }
    LocalAccountData.markSetupFinished(setupDefaults)
    recovery = nil
    signIn = nil
    let b = binding
    profile = AccountProfile(displayName: b?.display_name ?? "", email: b?.email_norm ?? "", method: credential.method)
    methodConfirmed = true
  }

  func recoveryCanContinue(_ ticket: RecoveryTicket) -> Bool { recovery?.ceremonyID == ticket.id }

  func securityState() async throws(AuthFailure) -> SecurityState {
    guard let b = try heldBinding() else { throw .refused }
    var hasPassword = profile?.method == .password
    var hasPasskey = profile?.method == .passkey
    var frozen: FreezeInfo?
    var fetched: AccountInfo?
    if let token = try? env.secrets.activeSession()?.token {
      do {
        fetched = try await env.client.account(bearer: token)
      } catch {
        if !methodConfirmed { throw Self.map(CeremonyError.api(error)) }
      }
    } else if !methodConfirmed {
      throw .refused
    }
    if let a = fetched {
      hasPassword = a.has_password ?? hasPassword
      hasPasskey = a.has_passkey ?? hasPasskey
      frozen = Self.freeze(a, nowMs: env.clock.nowMs())
    }
    return SecurityState(
      email: b.email_norm, emailVerified: true,
      passkeys: hasPasskey
        ? [PasskeyRow(id: "this", provider: "Passkey", detail: "Signs you in with Face ID", isThisCredential: true)] : [],
      passwordChanged: hasPassword ? "Set" : nil,
      devices: [DeviceRow(id: b.writer_id, title: "This iPhone", detail: "Active now", isThisDevice: true)],
      lastSignIn: "on this iPhone", phraseConfirmed: "Shown at signup", frozen: frozen)
  }

  private func freezeInfo(token: String) async -> FreezeInfo {
    let a = try? await env.client.account(bearer: token)
    return a.flatMap { Self.freeze($0, nowMs: env.clock.nowMs()) } ?? FreezeInfo(by: .holder, when: nil)
  }

  func freezeInfo() async -> FreezeInfo? {
    guard let token = try? env.secrets.activeSession()?.token,
      let a = try? await env.client.account(bearer: token)
    else { return nil }
    return Self.freeze(a, nowMs: env.clock.nowMs())
  }

  static func freeze(_ a: AccountInfo, nowMs: Int64) -> FreezeInfo? {
    guard a.frozen == true || a.restricted == true else { return nil }
    return FreezeInfo(
      by: a.frozen_by == "operator" ? .operator : .holder, when: freezeTime(a.freeze_trigger_at, nowMs: nowMs),
      holderCanLift: a.holder_can_lift ?? true, hasPassword: a.has_password)
  }

  static func freezeTime(_ instant: String?, nowMs: Int64) -> String? {
    guard let instant, let ms = try? parseInstantMs(instant) else { return nil }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(secondsFromGMT: Int(LocalClock.offsetMinutes) * 60)!
    f.dateFormat = LocalClock.localDate(ms)?.year == LocalClock.localDate(nowMs)?.year
      ? "EEE d MMM 'at' HH:mm" : "EEE d MMM yyyy 'at' HH:mm"
    return "on " + f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
  }

  func perform(_ action: SecurityAction, password: String?) async throws(AuthFailure) {
    let factor: StepUpHelper.Factor = password.map { .device(password: $0) } ?? .passkey
    guard let b = try heldBinding() else {
      guard case .unfreeze = action else { throw .refused }
      try await unfreeze(factor: factor, binding: nil)
      return
    }
    do {
      switch action {
      case .deleteAccount:
        let ctx = try hooks.context() ?? Enrolment.context(env, binding: b)
        let grant = MailboxLane.heldGrant(secrets: env.secrets, userID: ctx.userID)
        await hooks.pause()
        do {
          try await AccountManagement.deleteAccount(
            env, ctx: ctx, factor: factor, binding: b, beforeWipe: grantEnding(grant, stopWatch: true))
        } catch {
          await hooks.resume()
          throw error
        }
        PushRegistrar.shared.forget()
        leftThisIPhone()
        await left()
      case .removeDevice(id: b.writer_id), .removeThisIPhoneLosingUnsent:
        guard let engine = hooks.engine() else { throw AuthFailure.refused }
        let grant = b.userID.flatMap { MailboxLane.heldGrant(secrets: env.secrets, userID: $0) }
        await hooks.pause()
        await PushRegistrar.shared.unregister()
        do {
          try await AccountManagement.removeThisIPhone(
            env, engine: engine, factor: factor, binding: b, losingUnsent: action == .removeThisIPhoneLosingUnsent,
            beforeWipe: grantEnding(grant, stopWatch: false))
        } catch {
          PushRegistrar.shared.register(env: env, userID: b.user_id)
          await hooks.resume()
          throw error
        }
        leftThisIPhone()
        await left()
      case .signOutEverywhere:
        try await guarded(.sessionLogoutAll, "/api/v1/auth/logout-all", factor: factor, binding: b, action: action)
        try? env.secrets.deleteSession()
        sessionEnded()
        hooks.forgetHomeLayout()
        await left()
      case .freeze:
        try await guarded(.accountFreeze, "/api/v1/account/freeze/now", factor: factor, binding: b, action: action)
      case .unfreeze:
        try await unfreeze(factor: factor, binding: b)
      case .addPasskey:
        _ = try await AccountPasskeys.add(env, binding: b, factor: factor, body: unlockBody, reason: action.explainer)
        endUnlockOffer()
        if let p = profile { profile = AccountProfile(displayName: p.displayName, email: p.email, method: .passkey) }
        methodConfirmed = profile != nil
      case .removePasskey, .setPassword, .changePassword, .removePassword, .removeDevice:
        throw AuthFailure.notInThisBuild
      }
    } catch let e as AuthFailure {
      throw e
    } catch let e as CeremonyError {
      throw await refusal(e)
    } catch {
      throw .refused
    }
  }

  private func unfreeze(factor: StepUpHelper.Factor, binding: AccountBinding?) async throws(AuthFailure) {
    if await freezeInfo()?.by == .operator { throw .frozenByOperator }
    do throws(CeremonyError) {
      try await guarded(.accountUnfreeze, "/api/v1/account/unfreeze", factor: factor, binding: binding,
                        action: .unfreeze)
    } catch {
      let failure = await refusal(error)
      if failure == .frozen, await freezeInfo()?.by == .operator { throw .frozenByOperator }
      throw failure
    }
  }

  private func refusal(_ e: CeremonyError) async -> AuthFailure {
    guard e.failure?.status == 401 else { return Self.map(e) }
    AccountSignIn.forgetEndedSession(env)
    sessionEnded()
    await left()
    return .sessionEnded
  }

  private func guarded(_ params: StepUpParams, _ path: String, factor: StepUpHelper.Factor, binding: AccountBinding?,
                       action: SecurityAction) async throws(CeremonyError)
  {
    let proof = try await StepUpHelper.prove(env, params: params, factor: factor, binding: binding,
                                             reason: action.explainer)
    proof.prf?.wipe()
    let token = try bearer()
    do {
      let _: Empty = try await env.client.api.call(.post, path, json: StepUpBody(step_up: proof.stepUp), bearer: token)
    } catch {
      throw .api(error)
    }
  }

  func viewRecoveryPhrase() async throws(AuthFailure) -> [String] {
    guard let b = try heldBinding(), let user = b.userID else { throw .refused }
    do {
      let proof = try await StepUpHelper.prove(
        env, params: .phraseView, factor: .passkey, binding: b, reason: "Confirm it's you to see your 12 words")
      defer { proof.prf?.wipe() }
      guard let credentialID = proof.credentialID, proof.prf != nil else { throw CeremonyError.noPRF }
      let token = try bearer()
      let keys: KeysResponse
      do { keys = try await env.client.keys(bearer: token) } catch { throw CeremonyError.api(error) }
      let body = try await Enrolment.unlockWithPRF(env, userID: user, credentialID: credentialID, prf: proof.prf)
      defer { body.wipe() }
      let answer: PhraseViewAnswer
      do {
        answer = try await env.client.api.call(
          .post, "/api/v1/keys/phrase/view", json: StepUpBody(step_up: proof.stepUp), bearer: token)
      } catch {
        throw CeremonyError.api(error)
      }
      guard let box = try? Base64.decode(answer.phrase_box), let rk = try? Base64.decode(keys.recovery_pubkey) else {
        throw CeremonyError.badResponse("phrase box")
      }
      let entropy: SecureBytes
      do {
        entropy = try PhraseBox.open(box, amk: body.amk, userID: user, recoveryPublicKey: rk)
      } catch {
        throw CeremonyError.integrityAlarm("phrase box")
      }
      defer { entropy.wipe() }
      do { return try Phrase.words(entropy: entropy) } catch { throw CeremonyError.crypto("words") }
    } catch let e as AuthFailure {
      throw e
    } catch let e as CeremonyError {
      if case .noPRF = e { throw .passkeyCantShowPhrase }
      throw await refusal(e)
    } catch {
      throw .refused
    }
  }

  static func instant(_ s: String?) -> Date? {
    guard let s, let ms = try? parseInstantMs(s) else { return nil }
    return Date(timeIntervalSince1970: Double(ms) / 1000)
  }

  private func bearer() throws(CeremonyError) -> String {
    try AccountSignIn.liveBearer(env)
  }

  func sessionEnded() {
    endUnlockOffer()
    signIn = nil
    enrolled = nil
  }

  private func clearSignedIn() {
    sessionEnded()
    profile = nil
    methodConfirmed = false
  }

  private func leftThisIPhone() {
    try? env.secrets.deleteSession()
    LocalAccountData.forget(facts: bankTextFacts, marker: bankTextMarker)
    clearSignedIn()
  }

  private func grantEnding(_ grant: HeldMailGrants?, stopWatch: Bool) -> @Sendable () async -> Void {
    let ends = grantEnds
    let endGrant = endGrant
    return {
      guard let grant, let endGrant else { return }
      await ends.end { await endGrant(grant, stopWatch) }
    }
  }

  func forgetAll() {
    clearSignedIn()
    signup = nil
    keys?.wipe()
    keys = nil
    registered = nil
    inviteCode = nil
    recovery?.wipe()
    recovery = nil
  }

  private func left() async {
    await hooks.left()
    BankTextsDeviceData.forget(secrets: env.secrets.store, facts: bankTextFacts, marker: bankTextMarker)
  }

  func signOut() async {
    await AccountSignIn.signOut(env)
    sessionEnded()
    hooks.forgetHomeLayout()
    await left()
  }

  func endSessionKeepingData() async {
    await AccountSignIn.signOut(env)
    endUnlockOffer()
    signIn = nil
  }

  static func finishFailure(_ e: CeremonyError, phraseUnseen: Bool) -> AuthFailure {
    if phraseUnseen, case .api(.refused(let f)) = e, f.status == 400 { return .wordsInSignup }
    return map(e)
  }

  static func map(_ e: CeremonyError) -> AuthFailure {
    if case .api(.refused(let f)) = e, f.code == "phrase_unseen" { return .wordsBeforeRemovingPasskey }
    if case .api(.refused(let f)) = e, f.status == 426 { return .updateRequired }
    switch e {
    case .notThisAccountsPhrase: return .phraseMismatch
    case .badPhrase: return .badPhrase("These aren't a Hasala phrase. Two words may be swapped.")
    case .badInviteCode: return .notInvited
    case .noPRF: return .noCredential
    case .integrityAlarm, .challengeMismatch: return .integrity
    default: break
    }
    switch e.failureClass {
    case .cancelled: return .cancelled
    case .unsupported: return .unsupported
    case .noCredential: return .noCredential
    case .notInvited: return .notInvited
    case .badName: return .badName
    case .badEmail: return .badEmail
    case .rejected: return .refused
    case .wrongCredentials: return .wrongCredentials
    case .recoveryRefused, .resetRefused: return .refused
    case .emailInUse: return .emailInUse
    case .codeRejected: return .codeExpired
    case .lastAuthenticator: return .lastAuthenticator
    case .frozen: return .frozen
    case .stepUpFailed: return .stepUpFailed
    case .noDeviceKey: return .noDeviceKey
    case .rateLimited: return .rateLimited
    case .offline, .unavailable: return .offline
    case .integrity: return .integrity
    case .otherAccountDevice, .deviceRefused, .notApproved, .other:
      log.notice("auth refused: \(Self.describe(e), privacy: .public)")
      return .refused
    }
  }

  private static let log = Logger(subsystem: "app.hasala.ios", category: "auth")

  static func describe(_ e: CeremonyError) -> String {
    switch e {
    case .api(.refused(let f)): "\(f.status) \(f.code)"
    case .api: "api"
    case .passkey(let p): "passkey \(p)"
    default: String(String(describing: e).prefix { $0 != "(" })
    }
  }
}

nonisolated struct StepUpBody: Encodable, Sendable {
  var step_up: StepUpJSON
}

nonisolated struct PhraseViewAnswer: Decodable, Sendable {
  var phrase_box: String
}

@MainActor
struct LiveAccountHooks {
  var engine: @MainActor () -> SyncEngine? = { nil }
  var context: @MainActor () -> SyncContext? = { nil }
  var pause: @MainActor () async -> Void = {}
  var resume: @MainActor () async -> Void = {}
  var left: @MainActor () async -> Void = {}
  var forgetHomeLayout: @MainActor () -> Void = {}
  var otherAccountHere: @MainActor (_ email: String?) -> Void = { _ in }
  var deviceUnenrolled: @MainActor () -> Void = {}
}
