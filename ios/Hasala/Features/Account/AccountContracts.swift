import Foundation

enum SignInMethod: String, Equatable, Sendable, CaseIterable {
  case passkey
  case password
}

enum NewCredential: Equatable, Sendable {
  case passkey
  case password(String)

  var method: SignInMethod {
    switch self {
    case .passkey: .passkey
    case .password: .password
    }
  }
}

enum EmailCode {
  static let lifetime: TimeInterval = 10 * 60

  static func expired(sentAt: Date, now: Date) -> Bool { now.timeIntervalSince(sentAt) > lifetime }
}

struct SignupTicket: Equatable, Sendable {
  var id: String
  var emailProven: Bool
  var email: String
  var displayName: String
  var startedAt: Date

  func isExpired(now: Date) -> Bool { now.timeIntervalSince(startedAt) > 30 * 60 }
  func codeExpired(now: Date) -> Bool { EmailCode.expired(sentAt: startedAt, now: now) }
}

struct RecoveryPhrase: Equatable, Sendable {
  var words: [String]
}

enum SignInOutcome: Equatable, Sendable {
  case ready
  case needsUnlock(passkeyCanUnlock: Bool)
  case needsKeys
  case frozen(FreezeInfo)
}

struct ResetTicket: Equatable, Sendable {
  var id: String
  var email: String
  var approvers: Bool = false
  var resetCode: String?
}

struct RecoveryTicket: Equatable, Sendable {
  var id: String
  var emailHint: String
}

struct PendingReset: Identifiable, Equatable, Sendable {
  var id: String
  var askedAgo: String
  var email: String
}

struct FreezeInfo: Equatable, Sendable {
  enum By: Equatable, Sendable { case holder, `operator` }
  var by: By
  var when: String?
  var inApp = false
  var holderCanLift = true
  var hasPassword: Bool?
}

struct PasskeyRow: Identifiable, Equatable, Sendable {
  var id: String
  var provider: String
  var detail: String
  var isThisCredential: Bool
}

struct DeviceRow: Identifiable, Equatable, Sendable {
  var id: String
  var title: String
  var detail: String
  var isThisDevice: Bool
  var isTablet = false
}

struct EmailChangeTicket: Identifiable, Equatable, Sendable {
  var id: String
  var currentEmail: String
  var newEmail: String?
  var sentAt: Date?
}

struct SecurityState: Equatable, Sendable {
  var email: String
  var emailVerified: Bool
  var passkeys: [PasskeyRow]
  var passwordChanged: String?
  var devices: [DeviceRow]
  var lastSignIn: String
  var phraseConfirmed: String
  var frozen: FreezeInfo?

  var hasPasskey: Bool { !passkeys.isEmpty }
  var hasPassword: Bool { passwordChanged != nil }

  func canRemove(_ passkey: PasskeyRow) -> Bool {
    !passkey.isThisCredential && passkeys.contains { $0.id == passkey.id } && (passkeys.count > 1 || hasPassword)
  }

  var canRemovePassword: Bool { hasPassword && hasPasskey }
}

enum SecurityAction: Equatable, Sendable {
  case addPasskey
  case removePasskey(id: String)
  case setPassword(new: String)
  case changePassword(new: String)
  case removePassword
  case removeDevice(id: String)
  case removeThisIPhoneLosingUnsent
  case signOutEverywhere
  case freeze
  case unfreeze
  case deleteAccount

  var explainer: String {
    switch self {
    case .addPasskey: "Confirm it's you to add a passkey"
    case .removePasskey: "Confirm it's you to remove this passkey"
    case .setPassword: "Confirm it's you to set a password"
    case .changePassword: "Confirm it's you to change your password"
    case .removePassword: "Confirm it's you to remove your password"
    case .removeDevice, .removeThisIPhoneLosingUnsent: "Confirm it's you to remove this device"
    case .signOutEverywhere: "Confirm it's you to sign out everywhere"
    case .freeze: "Confirm it's you to freeze your account"
    case .unfreeze: "Confirm it's you to unfreeze your account"
    case .deleteAccount: "Confirm it's you to delete your account"
    }
  }
}

struct AccountProfile: Equatable, Sendable {
  var displayName: String
  var email: String
  var method: SignInMethod

  var greetingName: String {
    displayName.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

nonisolated struct AccountCapabilities: OptionSet, Sendable {
  let rawValue: UInt32

  init(rawValue: UInt32) { self.rawValue = rawValue }

  static let signupPasskey = AccountCapabilities(rawValue: 1 << 0)
  static let signupPassword = AccountCapabilities(rawValue: 1 << 1)

  static let signInPasskey = AccountCapabilities(rawValue: 1 << 2)
  static let signInPassword = AccountCapabilities(rawValue: 1 << 3)

  static let unlockWithPhrase = AccountCapabilities(rawValue: 1 << 4)

  static let signOut = AccountCapabilities(rawValue: 1 << 5)
  static let signOutEverywhere = AccountCapabilities(rawValue: 1 << 6)
  static let deleteAccount = AccountCapabilities(rawValue: 1 << 7)
  static let removeThisIPhone = AccountCapabilities(rawValue: 1 << 8)

  static let resetPassword = AccountCapabilities(rawValue: 1 << 9)
  static let recoverAccess = AccountCapabilities(rawValue: 1 << 10)
  static let recoverWithPassword = AccountCapabilities(rawValue: 1 << 19)

  static let rotatePhrase = AccountCapabilities(rawValue: 1 << 11)
  static let addPasskey = AccountCapabilities(rawValue: 1 << 12)
  static let changeEmail = AccountCapabilities(rawValue: 1 << 13)
  static let freeze = AccountCapabilities(rawValue: 1 << 14)
  static let viewPhrase = AccountCapabilities(rawValue: 1 << 15)
  static let removePasskey = AccountCapabilities(rawValue: 1 << 16)
  static let changePassword = AccountCapabilities(rawValue: 1 << 17)
  static let removeDevice = AccountCapabilities(rawValue: 1 << 18)
  static let unfreeze = AccountCapabilities(rawValue: 1 << 20)
  static let changeName = AccountCapabilities(rawValue: 1 << 21)

  static let all: AccountCapabilities = [
    .signupPasskey, .signupPassword,
    .signInPasskey, .signInPassword,
    .unlockWithPhrase,
    .signOut, .signOutEverywhere,
    .deleteAccount, .removeThisIPhone,
    .resetPassword, .recoverAccess, .recoverWithPassword,
    .rotatePhrase, .addPasskey, .changeEmail,
    .freeze, .unfreeze, .viewPhrase,
    .removePasskey, .changePassword, .removeDevice,
    .changeName,
  ]

  static let beta: AccountCapabilities = [
    .signupPasskey, .signupPassword,
    .signInPasskey, .signInPassword,
    .unlockWithPhrase,
    .signOut, .signOutEverywhere,
    .deleteAccount,
    .recoverAccess, .recoverWithPassword,
    .viewPhrase,
    .addPasskey,
    .changeName,
    .unfreeze,
  ]
}

struct NewPasskey: Equatable, Sendable {
  var prf: Bool
  var synced: Bool
}

@MainActor
protocol AccountService: AnyObject {
  var capabilities: AccountCapabilities { get }

  var keysOnThisIPhone: Bool { get }

  func beginSignup(code: InviteCode, linkKey: String?, email: String, displayName: String)
    async throws(AuthFailure) -> SignupTicket
  func verifySignupEmail(_ ticket: SignupTicket, code: String) async throws(AuthFailure)
  func resendSignupCode(_ ticket: SignupTicket) async throws(AuthFailure) -> SignupTicket
  @discardableResult func registerPasskey(_ ticket: SignupTicket) async throws(AuthFailure) -> NewPasskey
  func makeRecoveryPhrase() throws(AuthFailure) -> RecoveryPhrase
  func finishAccount(_ ticket: SignupTicket, credential: NewCredential, phrase: RecoveryPhrase)
    async throws(AuthFailure) -> AccountProfile
  func finishAccountWithoutWords(_ ticket: SignupTicket) async throws(AuthFailure) -> AccountProfile

  func signInWithPasskey() async throws(AuthFailure) -> SignInOutcome
  func signInWithPassword(email: String, password: String) async throws(AuthFailure) -> SignInOutcome
  func unlockWithPasskey() async throws(AuthFailure)
  func unlockWithPhrase(_ words: [String]) async throws(AuthFailure)
  func endUnlockOffer()
  func sessionEnded()

  func resumeSignedIn() async throws(AuthFailure) -> SignInOutcome
  func finishInterruptedSetup(phrase: RecoveryPhrase) async throws(AuthFailure) -> AccountProfile

  func beginPasswordReset(email: String) async throws(AuthFailure) -> ResetTicket
  func verifyPasswordReset(_ ticket: ResetTicket, code: String) async throws(AuthFailure) -> ResetTicket
  func requestResetApproval(_ ticket: ResetTicket, newPassword: String) async throws(AuthFailure) -> ResetTicket
  func pollResetApproval(_ ticket: ResetTicket) async throws(AuthFailure) -> Bool

  func beginRecovery(words: [String]) async throws(AuthFailure) -> RecoveryTicket
  func verifyRecovery(_ ticket: RecoveryTicket, code: String, kind: SignInMethod) async throws(AuthFailure)
  func finishRecovery(_ ticket: RecoveryTicket, credential: NewCredential) async throws(AuthFailure)
  func recoveryCanContinue(_ ticket: RecoveryTicket) -> Bool

  var profile: AccountProfile? { get }
  func securityState() async throws(AuthFailure) -> SecurityState
  func perform(_ action: SecurityAction, password: String?) async throws(AuthFailure)
  func viewRecoveryPhrase() async throws(AuthFailure) -> [String]
  func signOut() async

  func beginEmailChange(password: String?) async throws(AuthFailure) -> EmailChangeTicket
  func sendEmailChangeCodes(_ ticket: EmailChangeTicket, to newEmail: String) async throws(AuthFailure)
    -> EmailChangeTicket
  func finishEmailChange(_ ticket: EmailChangeTicket, currentCode: String, newCode: String) async throws(AuthFailure)

  func pendingResetRequest() async -> PendingReset?
  func approveReset(_ request: PendingReset, code: String) async throws(AuthFailure)

  func updateDisplayName(_ name: String) async throws(AuthFailure) -> String
}

extension AccountService {
  func finishAccountWithoutWords(_ ticket: SignupTicket) async throws(AuthFailure) -> AccountProfile {
    try await finishAccount(ticket, credential: .passkey, phrase: try makeRecoveryPhrase())
  }

  var capabilities: AccountCapabilities { .all }

  var keysOnThisIPhone: Bool { true }

  func endUnlockOffer() {}

  func sessionEnded() {}

  func beginEmailChange(password: String?) async throws(AuthFailure) -> EmailChangeTicket { throw .notInThisBuild }
  func sendEmailChangeCodes(_ ticket: EmailChangeTicket, to newEmail: String) async throws(AuthFailure)
    -> EmailChangeTicket
  { throw .notInThisBuild }
  func finishEmailChange(_ ticket: EmailChangeTicket, currentCode: String, newCode: String) async throws(AuthFailure) {
    throw .notInThisBuild
  }

  func updateDisplayName(_ name: String) async throws(AuthFailure) -> String { throw .notInThisBuild }
}
