import Foundation
import Testing

@testable import Hasala

@MainActor
@Suite("Account capabilities")
struct AccountCapabilitiesTests {
  func session(_ account: MockAccountService = MockAccountService()) -> AccountSession {
    let services = AccountServices(
      account: account, mailbox: MockMailbox(offersSampleData: false), setup: MockSetupAuthoring(),
      notifications: MockNotificationPermission())
    return AccountSession(services: services, phase: .ready)
  }

  @Test func betaIsTheAgreedSubset() {
    let hidden: AccountCapabilities = [
      .resetPassword, .rotatePhrase, .changeEmail, .freeze,
      .removePasskey, .changePassword, .removeDevice, .removeThisIPhone,
    ]
    #expect(AccountCapabilities.all.isSuperset(of: .beta))
    #expect(AccountCapabilities.beta.isDisjoint(with: hidden))
    #expect(AccountCapabilities.beta.union(hidden) == .all)
    #expect(AccountCapabilities.all.rawValue.nonzeroBitCount == 22)
    #expect(AccountCapabilities.beta.isSuperset(of: [.recoverAccess, .recoverWithPassword, .deleteAccount]))
    #expect(AccountCapabilities.beta.contains(.addPasskey))
    #expect(AccountCapabilities.beta.contains(.changeName))
    #expect(AccountCapabilities.beta.contains(.unfreeze))
  }

  @Test func securityFollowsTheCapabilities() {
    let mock = MockAccountService(existing: .passkey, signedIn: true)
    let s = session(mock)
    let model = SecurityModel(session: s)
    #expect(!model.lacksAnAction)
    #expect(model.offersLockdown)
    mock.capabilities = .beta
    #expect(s.capabilities == .beta)
    #expect(model.lacksAnAction)
    #expect(!model.offersLockdown)
  }

  @Test func theLastPasskeyIsNeverOfferedForRemoval() {
    let mine = PasskeyRow(id: "pk-1", provider: "iCloud Keychain", detail: "", isThisCredential: true)
    let other = PasskeyRow(id: "pk-2", provider: "Work iPad", detail: "", isThisCredential: false)
    func state(_ passkeys: [PasskeyRow], password: Bool) -> SecurityState {
      SecurityState(email: "maya@example.com", emailVerified: true, passkeys: passkeys,
                    passwordChanged: password ? "Set" : nil, devices: [], lastSignIn: "", phraseConfirmed: "",
                    frozen: nil)
    }
    #expect(!state([other], password: false).canRemove(other))
    #expect(!state([mine, other], password: true).canRemove(mine))
    #expect(!state([mine], password: false).canRemove(mine))
    #expect(state([mine, other], password: false).canRemove(other))
    #expect(state([other], password: true).canRemove(other))
    #expect(!state([mine], password: true).canRemove(other))
    #expect(!state([], password: true).canRemovePassword)
    #expect(state([mine], password: true).canRemovePassword)
    #expect(!state([mine], password: false).canRemovePassword)
  }

  @Test func mocksOfferEverythingByDefault() {
    let s = session()
    #expect(s.account.capabilities == .all)
    #expect(s.capabilities == .all)
  }

  @Test func reviewAccountDefaultsOffAndClearsOnSignOut() {
    let s = session()
    #expect(s.reviewAccount == false)
    s.reviewAccount = true
    s.signedOut()
    #expect(s.reviewAccount == false)
  }
}
