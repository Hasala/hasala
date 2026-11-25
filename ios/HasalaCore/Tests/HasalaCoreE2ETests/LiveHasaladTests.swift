import CoreAuth
import CoreCrypto
import CoreSoftAuth
import CoreTestSupport
import Foundation
import Testing

@testable import CoreSync

enum Live {
  static let env = ProcessInfo.processInfo.environment
  static var url: URL? { env["HASALA_E2E_URL"].flatMap(URL.init(string:)) }
  static var enabled: Bool {
    url != nil && env["HASALA_E2E_PSQL"] != nil && env["HASALA_E2E_DSN"] != nil && env["HASALA_E2E_AUTH_KEY_FILE"] != nil
  }

  static func sql(_ statement: String) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: env["HASALA_E2E_PSQL"]!)
    p.arguments = [env["HASALA_E2E_DSN"]!, "-v", "ON_ERROR_STOP=1", "-At", "-c", statement]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    try p.run()
    p.waitUntilExit()
    let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    guard p.terminationStatus == 0 else { throw LiveError.sql(text) }
    return text
  }

  enum LiveError: Error { case sql(String) }

  static func hex(_ d: Data) -> String { "'\\x" + Hex.encode(d) + "'" }

  static let password = "copper lantern quietly 42"

  static func phone(_ seed: String, clock: FakeClock = FakeClock(), passkeys: SoftPasskey = SoftPasskey()) -> Phone {
    Phone(
      transport: URLSessionTransport(baseURL: url!, clientHeader: "ios/0.0.0/1"), clock: clock, seed: seed, passkeys: passkeys)
  }

  static func newEmail() throws -> String { "e2e-\(Hex.encode(try SystemRandom().bytes(4)))@example.com" }

  static func setCode(_ code: String, purpose: String, ceremonyID: String) throws {
    let path = try #require(env["HASALA_E2E_AUTH_KEY_FILE"])
    let keyHex = try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    let authKey = try Hex.decode(keyHex)
    let row = try sql(
      """
      SELECT code_id, encode(email_tag, 'hex') FROM email_codes
        WHERE purpose = '\(purpose)' AND ceremony_id = '\(ceremonyID)' ORDER BY created_at DESC LIMIT 1;
      """
    ).trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|").map(String.init)
    try #require(row.count == 2)
    let codeID = try #require(UUID(uuidString: row[0]))
    let tag = try Hex.decode(row[1])
    let kCode = try hkdfSHA256(
      inputKeyMaterial: authKey, salt: Data(count: 32), info: Data("hasala/v1/server/email-code".utf8), outputByteCount: 32)
    let u = codeID.uuid
    let raw = Data([u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15])
    let mac = hmacSHA256(key: kCode, message: Data(purpose.utf8) + [0] + raw + tag + Data(code.utf8))
    _ = try sql("UPDATE email_codes SET code_mac = \(hex(mac)) WHERE code_id = '\(row[0])';")
  }

  static func signUp(_ phone: Phone, email: String, displayName: String = "Maya Live") async throws -> Signup {
    let invite = Base32.encode(try SystemRandom().bytes(15))
    _ = try sql(
      """
      INSERT INTO invite_codes (code_hash, origin, state, created_at, minted_at, expires_at, mint_count)
        VALUES (\(hex(sha256(Data(invite.utf8)))), 'cli', 'active', now(), now(), now() + interval '1 day', 1);
      """)
    let signup = try await AccountCreation.beginSignup(
      phone.env, inviteCode: invite, email: email, displayName: displayName, inviteLinkKey: nil)
    try setCode("135790", purpose: "signup", ceremonyID: signup.id)
    try await AccountCreation.verifySignup(phone.env, signup, code: "135790")
    return signup
  }

  struct Account {
    let enrolled: EnrolledAccount
    let words: String
    let authorityPublicKey: Data
  }

  static func passwordAccount(_ phone: Phone, email: String, displayName: String = "Maya Live") async throws -> Account {
    let signup = try await signUp(phone, email: email, displayName: displayName)
    let keys = try NewAccountKeys.generate(random: SystemRandom())
    let words = try keys.words().joined(separator: " ")
    let aak = try keys.authorityPublicKey()
    let enrolled = try await AccountCreation.createWithPassword(phone.env, signup: signup, password: password, keys: keys)
    return Account(enrolled: enrolled, words: words, authorityPublicKey: aak)
  }

  static func secondPhone(_ phone: Phone, email: String, words: String) async throws -> EnrolledAccount {
    let r = try await AccountSignIn.withPassword(phone.env, email: email, password: password, bound: nil)
    let user = try #require(r.userID)
    #expect(r.hasKeys && r.boundWriter == nil)
    let body = try await Enrolment.unlockWithPhrase(phone.env, userID: user, typed: words)
    return try await Enrolment.enrolWriter(phone.env, userID: user, body: body, emailNorm: r.emailNorm, serverSalt: r.serverSalt)
  }
}

final class LosingTransport: Transport, @unchecked Sendable {
  let inner: any Transport
  private let lock = NSLock()
  private var armed = true
  init(inner: any Transport) { self.inner = inner }
  func send(_ request: APIRequest) async throws(TransportError) -> APIResponse {
    let r = try await inner.send(request)
    if request.method == .post, request.path == "/api/v1/sync", lock.withLock({ defer { armed = false }; return armed }) {
      throw .offline(.networkConnectionLost)
    }
    return r
  }
}

@Suite("Live hasalad", .enabled(if: Live.enabled), .serialized)
struct LiveHasaladTests {
  @Test("bootstrap, a second writer, upload with signed heads, pull, replay of a lost answer, refusals")
  func everything() async throws {
    let email = try Live.newEmail()

    let a = Live.phone("live-a-\(email)")
    let made = try await Live.passwordAccount(a, email: email)
    let accountA = made.enrolled
    let bearer = try #require(try a.env.secrets.session()).token
    let k = try await a.env.client.keys(bearer: bearer)
    #expect(k.authority_pubkey == Base64.encode(made.authorityPublicKey))
    let info = try await a.env.client.account(bearer: bearer)
    #expect(info.email == email && info.has_keys == true && info.has_password == true && info.has_passkey == false)
    #expect(a.binding?.writer_id == accountA.writerID.string)
    let ctxA = Enrolment.context(a.env, account: accountA)

    let b = Live.phone("live-b-\(email)")
    let accountB = try await Live.secondPhone(b, email: email, words: made.words)
    #expect(accountB.userID == accountA.userID && accountB.writerID != accountA.writerID)
    #expect(b.binding?.email_norm == email && b.binding?.display_name == "Maya Live")
    let ctxB = Enrolment.context(b.env, account: accountB)

    try enqueue(ctxA, (1...3).map { op($0) })
    let outA = await SyncEngine(context: ctxA).run(.authored)
    #expect(outA.stop == nil && outA.pushed.opsAcknowledged == 3)
    let outB = await SyncEngine(context: ctxB).run(.launch)
    #expect(outB.stop == nil)
    #expect(try storedOps(ctxB).map(\.opID) == (1...3).map { op($0).opID })

    let losing = SyncContext(
      userID: ctxA.userID, writerID: ctxA.writerID, store: ctxA.store, secrets: ctxA.secrets,
      client: AuthClient(transport: LosingTransport(inner: URLSessionTransport(baseURL: Live.url!, clientHeader: "ios/0.0.0/1"))),
      clock: ctxA.clock, random: ctxA.random)
    try enqueue(ctxA, [op(10), op(11)])
    #expect(await SyncEngine(context: losing).run(.authored).stop == .offline)
    #expect(try ctxA.store.inflight().count == 1)
    #expect(await SyncEngine(context: losing).run(.foreground).stop == nil)
    #expect(try ctxA.store.inflight().isEmpty && ctxA.store.pendingCount() == 0)

    #expect(await SyncEngine(context: ctxB).run(.foreground).stop == nil)
    #expect(try storedOps(ctxB).count == 5)

    try enqueue(ctxA, [op(20)])
    let batch = try Pusher.buildBatch(try ctxA.store.pendingOps(), ctx: ctxA)
    var forged = batch
    let last = forged.removeLast()
    forged.append(
      InflightBlob(
        counter: last.counter, batchID: last.batchID, prevHash: last.prevHash, blobHash: last.blobHash,
        sizeBucket: last.sizeBucket, blob: last.blob, opIDs: last.opIDs, headSig: Data(repeating: 1, count: 64),
        createdAt: last.createdAt))
    try ctxA.store.persistBatch(forged)
    let engine = SyncEngine(context: ctxA)
    _ = await engine.run(.authored)
    #expect(await engine.status.latch == .hardStop)
    #expect(await engine.status.integrityAlarms == 1)
    #expect(await engine.status.rowAlarms == 0)
  }
}

@Suite("LivePasskeyTests", .enabled(if: Live.enabled), .serialized)
struct LivePasskeyTests {
  @Test("a passkey signs up, signs in on its own iPhone and on a second one, and the two sync")
  func passkey() async throws {
    let email = try Live.newEmail()
    let shared = SoftPasskey()

    let a = Live.phone("live-passkey-a-\(email)", passkeys: shared)
    let signup = try await Live.signUp(a, email: email)
    let keys = try NewAccountKeys.generate(random: SystemRandom())
    let reg = try await AccountCreation.registerPasskey(a.env, signup: signup, keys: keys)
    let accountA = try await AccountCreation.bootstrapPasskey(a.env, registered: reg, keys: keys)
    #expect(shared.credentials.count == 1)
    let bearer = try #require(try a.env.secrets.session()).token
    let info = try await a.env.client.account(bearer: bearer)
    #expect(info.email == email && info.has_keys == true && info.has_passkey == true && info.has_password == false)
    #expect(try await a.env.client.keyWraps(bearer: bearer).wraps.map(\.credential_id) == [Base64.encodeURL(reg.credentialID)])

    let again = try await AccountSignIn.withPasskey(a.env, bound: a.binding, wantPRF: false)
    #expect(again.boundWriter == accountA.writerID)

    let b = Live.phone("live-passkey-b-\(email)", passkeys: shared)
    let r = try await AccountSignIn.withPasskey(b.env, bound: nil, wantPRF: true)
    #expect(r.userID == accountA.userID && r.boundWriter == nil && r.hasKeys)
    let assertion = try #require(r.assertion)
    let body = try await Enrolment.unlockWithPRF(
      b.env, userID: accountA.userID, credentialID: assertion.credentialID, prf: assertion.prfFirst)
    let accountB = try await Enrolment.enrolWriter(b.env, userID: accountA.userID, body: body, emailNorm: nil, serverSalt: nil)
    #expect(accountB.writerID != accountA.writerID)
    #expect(b.binding?.email_norm == email)

    let ctxA = Enrolment.context(a.env, account: accountA)
    let ctxB = Enrolment.context(b.env, account: accountB)
    try enqueue(ctxA, (1...3).map { op($0) })
    let outA = await SyncEngine(context: ctxA).run(.authored)
    #expect(outA.stop == nil && outA.pushed.opsAcknowledged == 3)
    #expect(await SyncEngine(context: ctxB).run(.launch).stop == nil)
    #expect(try storedOps(ctxB).map(\.opID) == (1...3).map { op($0).opID })
  }
}
