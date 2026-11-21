import CoreAuth
import CoreCrypto
import CorePrimitives
import Foundation
import Testing

@testable import CoreSync

@Suite("Live recovery", .enabled(if: Live.enabled && Live.env["HASALA_E2E_AUTH_KEY_FILE"] != nil), .serialized)
struct LiveRecoveryTests {
  static func setCode(_ code: String, purpose: String, ceremonyID: String) throws {
    let path = try #require(Live.env["HASALA_E2E_AUTH_KEY_FILE"])
    let hex = try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    let authKey = try Hex.decode(hex)
    let row = try Live.sql(
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
    _ = try Live.sql("UPDATE email_codes SET code_mac = \(Live.hex(mac)) WHERE code_id = '\(row[0])';")
  }

  @Test("the words and an email code get a new iPhone in with a new passkey; then the account is deleted")
  func recoverThenDelete() async throws {
    let random = SystemRandom()
    let email = "e2e-\(Hex.encode(try random.bytes(4)))@example.com"

    let invite = Base32.encode(try random.bytes(15))
    _ = try Live.sql(
      """
      INSERT INTO invite_codes (code_hash, origin, state, created_at, minted_at, expires_at, mint_count)
        VALUES (\(Live.hex(sha256(Data(invite.utf8)))), 'cli', 'active', now(), now(), now() + interval '1 day', 1);
      """)
    let a = Live.phone("live-recover-a-\(email)")
    let signup = try await AccountCreation.beginSignup(
      a.env, inviteCode: invite, email: email, displayName: "Maya Recover", inviteLinkKey: nil)
    try Self.setCode("135790", purpose: "signup", ceremonyID: signup.id)
    try await AccountCreation.verifySignup(a.env, signup, code: "135790")
    let keys = try NewAccountKeys.generate(random: random)
    let words = try keys.words().joined(separator: " ")
    let made = try await AccountCreation.createWithPassword(
      a.env, signup: signup, password: "copper lantern quietly 42", keys: keys)
    let user = made.userID
    let bearerA = try #require(try a.env.secrets.session()).token

    let c = Live.phone("live-recover-c-\(email)")

    let r = try await AccountRecovery.begin(c.env, typed: words)
    #expect(r.emailHint == "e\u{2022}\u{2022}\u{2022}@e\u{2022}\u{2022}\u{2022}.com")
    try Self.setCode("424242", purpose: "recovery", ceremonyID: r.ceremonyID)

    try await AccountRecovery.verifyForPasskey(c.env, r, code: "424242")
    #expect(r.userID == user)

    let account = try await AccountRecovery.finishWithPasskey(c.env, r)
    #expect(account.userID == user && c.passkeys.credentials.count == 1)
    let binding = try #require(c.binding)
    #expect(binding.user_id == user.string && binding.email_norm == email && binding.writer_id == account.writerID.string)
    #expect(binding.display_name == "Maya Recover")
    let bearerC = try #require(try c.env.secrets.session()).token
    let info = try await c.env.client.account(bearer: bearerC)
    #expect(info.email == email && info.has_passkey == true && info.has_password == false)
    await #expect {
      _ = try await a.env.client.account(bearer: bearerA)
    } throws: { ($0 as? APIError)?.failure?.status == 401 }
    let d = Live.phone("live-recover-d-\(email)")
    await #expect(throws: CeremonyError.self) {
      _ = try await AccountSignIn.withPassword(d.env, email: email, password: "copper lantern quietly 42", bound: nil)
    }
    let wraps = try await c.env.client.keyWraps(bearer: bearerC).wraps
    #expect(wraps.map(\.credential_id) == c.passkeys.credentials.map { Base64.encodeURL($0.id) })
    #expect(try c.env.secrets.epochKey(userID: user, epoch: 1) != nil)

    try await AccountManagement.deleteAccount(
      c.env, ctx: Enrolment.context(c.env, account: account), factor: .passkey, binding: binding)
    #expect(c.binding == nil)
    await #expect {
      _ = try await c.env.client.account(bearer: bearerC)
    } throws: { ($0 as? APIError)?.failure?.code == "account_deleted" }
  }
}
