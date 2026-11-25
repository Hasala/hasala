import Foundation
import Testing

@testable import Hasala

@MainActor
@Suite("Passkey sheet anchor")
struct PasskeyAuthenticatorTests {
  let challenge = Data(repeating: 7, count: 32)

  @Test func aRegistrationWithNoWindowSceneFailsBeforeAControllerStarts() async {
    let authenticator = PasskeyAuthenticator(anchor: { nil })
    await #expect(throws: AuthFailure.unsupported) {
      _ = try await authenticator.register(challenge: challenge, userID: Data([1, 2, 3]), prfSalt: nil)
    }
  }

  @Test func anAssertionWithNoWindowSceneFailsBeforeAControllerStarts() async {
    let authenticator = PasskeyAuthenticator(anchor: { nil })
    await #expect(throws: AuthFailure.unsupported) {
      _ = try await authenticator.assert(challenge: challenge, prfSalt: nil)
    }
  }
}
