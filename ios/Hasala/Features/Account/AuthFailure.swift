import Foundation

enum AuthFailure: Error, Equatable, Sendable {
  case cancelled
  case unsupported
  case noCredential
  case notInvited
  case badName
  case badEmail
  case orphanedPasskey
  case wrongCredentials
  case refused
  case emailInUse
  case codeWrong(triesLeft: Int)
  case codeExpired
  case rateLimited
  case lastAuthenticator
  case frozen
  case frozenByOperator
  case sessionEnded
  case stepUpFailed
  case passkeyCantShowPhrase
  case passkeyCantShowUnseenPhrase
  case wordsBeforeRemovingPasskey
  case wordsInSignup
  case noDeviceKey
  case offline
  case phraseMismatch
  case noAccountForPhrase
  case badPhrase(String)
  case signupExpired
  case signupExpiredPhrase
  case approvalExpired
  case noPasscode
  case codeMismatch
  case notInThisBuild
  case integrity
  case updateRequired

  var message: String? {
    switch self {
    case .cancelled: nil
    case .unsupported:
      "Couldn't make a passkey. Turn on a passcode and iCloud Keychain, or use a password."
    case .noCredential: "No Hasala passkey on this iPhone."
    case .notInvited: "We couldn't find that invite. Check each character against your email."
    case .badName: "Use 1 to 64 letters. Spaces, hyphens, apostrophes and periods are fine."
    case .badEmail: "Can't use this address yet. Try another."
    case .orphanedPasskey:
      "No account matches this passkey. If the beta was reset, join again with your invite, then delete the old passkey in the Passwords app."
    case .wrongCredentials: "Wrong email or password. Try again or reset your password."
    case .refused: "That didn't go through. Start again."
    case .emailInUse: "This address already has an account. Sign in instead."
    case .codeWrong(let n):
      "Wrong code. Check our newest email or get a new one. \(n) \(n == 1 ? "try" : "tries") left."
    case .codeExpired: "That code expired. Codes last 10 minutes; get a new one."
    case .rateLimited: "Too many tries. Try again in 15 minutes."
    case .lastAuthenticator: "It's your only way to sign in. Add a passkey or password first."
    case .frozen: "Your account is frozen. Confirm it's you to unfreeze it."
    case .frozenByOperator: "We froze your account to protect it. Talk to us to unfreeze it."
    case .sessionEnded: "You're signed out. Sign in again."
    case .stepUpFailed: "That didn't confirm. Try again."
    case .passkeyCantShowPhrase: "This passkey can't show your 12 words. Use your written copy."
    case .passkeyCantShowUnseenPhrase:
      "This passkey can't show your 12 words. Stay signed in here, where your data opens, and talk to us at hasala.app/support."
    case .wordsBeforeRemovingPasskey:
      "Write down your 12 words first. Until then, only this passkey can show them."
    case .wordsInSignup: "Write down your 12 words to finish."
    case .noDeviceKey:
      "This iPhone can't confirm yet. Use one where your data is open."
    case .offline: "Try again in a moment."
    case .phraseMismatch: "These words are for another account."
    case .noAccountForPhrase:
      "No active account matches these words. Frozen? Unfreeze it on a signed-in iPhone, or contact us."
    case .badPhrase(let text): text
    case .signupExpired: "Time ran out, so we started again. Your invite still works."
    case .signupExpiredPhrase:
      "Time ran out, so we started again with 12 new words. Cross out the old ones."
    case .approvalExpired: "No answer from your other iPhone. Try again, or use your 12 words."
    case .codeMismatch: "That code doesn't match a request. Nothing was approved."
    case .notInThisBuild: "Not in the beta yet. Need it? Talk to us at hasala.app/support."
    case .integrity:
      "Something didn't match, so nothing was changed. Talk to us at hasala.app/support."
    case .updateRequired:
      "This version is too old. Update Hasala in TestFlight, then try again."
    case .noPasscode:
      "Set an iPhone passcode to use Hasala. It protects your data and confirms it's you."
    }
  }
}
