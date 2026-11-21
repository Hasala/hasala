import CoreMailbox
import CorePrimitives
import CoreStore
import Foundation
import HasalaKeychain

@MainActor
enum LocalAccountData {
  static let setupFinishedKey = "app.hasala.prefs.setup.finished"
  static let legacySetupFinishedKey = "setup.finished.v1"
  static let mailboxProviderKey = "app.hasala.prefs.mailbox.provider"

  static func mailboxProvider(_ defaults: UserDefaults = .standard) -> MailboxProvider? {
    defaults.string(forKey: mailboxProviderKey).flatMap(MailboxProvider.init(rawValue:))
  }

  static func setMailboxProvider(_ p: MailboxProvider, _ defaults: UserDefaults = .standard) {
    defaults.set(p.rawValue, forKey: mailboxProviderKey)
  }

  static let mailboxMovedAwayKey = "app.hasala.prefs.mailbox.movedAway"

  static func mailboxMovedAway(_ defaults: UserDefaults = .standard) -> Int64? {
    (defaults.object(forKey: mailboxMovedAwayKey) as? NSNumber)?.int64Value
  }

  static func setMailboxMovedAway(_ ms: Int64?, _ defaults: UserDefaults = .standard) {
    if let ms { defaults.set(NSNumber(value: ms), forKey: mailboxMovedAwayKey) } else {
      defaults.removeObject(forKey: mailboxMovedAwayKey)
    }
  }

  static let mailboxPhaseSeenKey = "app.hasala.prefs.mailbox.phaseSeen"

  static func mailboxPhaseSeen(_ defaults: UserDefaults = .standard) -> MailboxPhase? {
    defaults.string(forKey: mailboxPhaseSeenKey).flatMap(MailboxPhase.init(rawValue:))
  }

  static func setMailboxPhaseSeen(_ phase: MailboxPhase?, _ defaults: UserDefaults = .standard) {
    if let phase { defaults.set(phase.rawValue, forKey: mailboxPhaseSeenKey) } else {
      defaults.removeObject(forKey: mailboxPhaseSeenKey)
    }
  }

  static let amountsHiddenKey = "app.hasala.prefs.amounts.hidden"

  static func amountsHidden(_ defaults: UserDefaults = .standard) -> Bool {
    defaults.bool(forKey: amountsHiddenKey)
  }

  static func setAmountsHidden(_ hidden: Bool, _ defaults: UserDefaults = .standard) {
    defaults.set(hidden, forKey: amountsHiddenKey)
  }

  static func setupFinished(_ defaults: UserDefaults = .standard) -> Bool {
    defaults.bool(forKey: setupFinishedKey)
  }

  static func markSetupFinished(_ defaults: UserDefaults = .standard) {
    defaults.set(true, forKey: setupFinishedKey)
  }

  static func migrate(boundUserID: String?, defaults: UserDefaults = .standard) {
    guard let ids = defaults.stringArray(forKey: legacySetupFinishedKey) else { return }
    if let u = boundUserID, ids.contains(u) { markSetupFinished(defaults) }
    defaults.removeObject(forKey: legacySetupFinishedKey)
  }

  static func forget(
    defaults: UserDefaults = .standard, facts: BankTextsFacts = .shared, marker: LockedTextsMarkerFile = .shared,
    gravatar: GravatarPreference = .shared
  ) {
    SearchHistory.shared.clear()
    gravatar.forgetPictures()
    WidgetLinkInbox.shared.pending = nil
    defaults.removeObject(forKey: setupFinishedKey)
    defaults.removeObject(forKey: legacySetupFinishedKey)
    defaults.removeObject(forKey: mailboxProviderKey)
    defaults.removeObject(forKey: mailboxMovedAwayKey)
    defaults.removeObject(forKey: mailboxPhaseSeenKey)
    defaults.removeObject(forKey: amountsHiddenKey)
    DevicePrefsStore(defaults: defaults).forgetAccountData()
    MerchantSuggestionsSetting.forget(defaults)
    TrustCounts.forget(defaults)
    StoredUnseenPhrase.forget(defaults)
    ManualEntryChoice.forget(defaults)
    FinishSetupRows.forget(defaults)
    HomeLayoutStore.forgetAll(defaults)
    NotificationReads.forget(defaults)
    PushRegistrar.forgetRegistration(defaults)
    BankTextsDeviceData.forgetFiles(facts: facts, marker: marker)
    #if DEBUG && targetEnvironment(simulator)
      SimulatorApprovalKey.forgetAll(defaults)
    #endif
  }

  static func forgetIfNoAccount(
    binding: () throws -> AccountBinding?, defaults: UserDefaults = .standard, facts: BankTextsFacts = .shared,
    marker: LockedTextsMarkerFile = .shared
  ) {
    do {
      guard try binding() == nil else { return }
    } catch {
      return
    }
    forget(defaults: defaults, facts: facts, marker: marker)
  }

  nonisolated static func digest(_ value: String, salt: String) -> String {
    Hex.encode(sha256(Data("\(salt)|\(value)".utf8)).prefix(8))
  }

  nonisolated static func salt(_ defaults: UserDefaults = .standard) -> String {
    defaults.string(forKey: InstallCheck.installIDKey) ?? ""
  }
}
