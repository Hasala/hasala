import CoreAuth
import CoreCrypto
import CorePrimitives
import Foundation
import Testing

@testable import CoreSync

@Suite("Live recovery", .enabled(if: Live.enabled), .serialized)
struct LiveRecoveryTests {
  @Test("the words and an email code get a new iPhone in with a new passkey; then the account is deleted")
  func recoverThenDelete() async throws {
    let email = try Live.newEmail()
    let a = Live.phone("live-recover-a-\(email)")
    let made = try await Live.passwordAccount(a, email: email, displayName: "Maya Recover")
    let words = made.words
    let user = made.enrolled.userID
    let bearerA = try #require(try a.env.secrets.session()).token

    let c = Live.phone("live-recover-c-\(email)")

    let r = try await AccountRecovery.begin(c.env, typed: words)
    #expect(r.emailHint == "e\u{2022}\u{2022}\u{2022}@e\u{2022}\u{2022}\u{2022}.com")
    try Live.setCode("424242", purpose: "recovery", ceremonyID: r.ceremonyID)

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
      _ = try await AccountSignIn.withPassword(d.env, email: email, password: Live.password, bound: nil)
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
