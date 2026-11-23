import CoreAuth
import CorePrimitives
import CoreStore
import CoreSync
import CoreTime
import Foundation
import HasalaKeychain
import HasalaWidgetData
import UIKit

@MainActor
final class AppEnvironment {
  static let keychainGroup = "8CFG28JHP3.app.hasala.ios"
  static let sharedKeychainGroup = "8CFG28JHP3.app.hasala.shared"

  let build: BuildInfo
  let apiBaseURL: URL
  let transport: URLSessionTransport
  let account: AccountEnvironment
  let hasPasscode: @MainActor () -> Bool
  private(set) var installCheck: InstallCheck.Outcome
  let secretsInMemory: Bool
  private let keychain: KeychainSecretStore

  init(
    build: BuildInfo, apiBaseURL: URL, transport: URLSessionTransport, account: AccountEnvironment,
    keychain: KeychainSecretStore, installCheck: InstallCheck.Outcome, secretsInMemory: Bool,
    hasPasscode: @escaping @MainActor () -> Bool
  ) {
    self.build = build
    self.apiBaseURL = apiBaseURL
    self.transport = transport
    self.account = account
    self.keychain = keychain
    self.installCheck = installCheck
    self.secretsInMemory = secretsInMemory
    self.hasPasscode = hasPasscode
  }

  var buildNumber: Int { Int(build.buildNumber.split(separator: ".").joined()) ?? 0 }

  func retryInstallCheck() -> InstallCheck.Outcome {
    if case .done = installCheck { return installCheck }
    if secretsInMemory { return .done }
    installCheck = Self.purge(keychain)
    return installCheck
  }

  private static func purge(_ keychain: KeychainSecretStore, defaults: UserDefaults = .standard)
    -> InstallCheck.Outcome
  {
    if defaults.string(forKey: InstallCheck.installIDKey) != nil { return .done }
    return InstallCheck.run(
      protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable, defaults: defaults, keychain: keychain,
      groups: [keychainGroup, sharedKeychainGroup], widgetsDirectory: WidgetSnapshotStore.shared()?.directory,
      apiHost: BuildInfo.apiBaseURL().host() ?? "api.hasala.app")
  }

  func eraseLocalData(defaults: UserDefaults = .standard) async {
    let secrets = account.secrets
    let binding = try? secrets.binding()
    let session = try? secrets.session()
    let confirmed = await AccountSignIn.signOut(account)
    let pending = confirmed ? nil : (try? secrets.session()).flatMap { $0.pending_logout ? $0 : nil }
    if let b = binding, let u = b.userID {
      let build = self.build
      await MailboxLane.endGrantThenWipe(account, userID: u, writerID: b.writerID) {
        await MailboxLane.endGrant($0, build: build, stopWatch: false)
      }
    }
    if let s = session, let u = UserID(s.user_id) { AccountWipe.wipe(account, userID: u, writerID: nil) }
    if let dir = account.accountsDirectory,
      let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
    {
      for item in items { try? FileManager.default.removeItem(at: item) }
    }
    let purged = InstallCheck.erase(defaults: defaults, keychain: keychain, groups: [Self.keychainGroup, Self.sharedKeychainGroup])
    installCheck = secretsInMemory ? .done : purged
    LocalAccountData.forget(defaults: defaults)
    if let pending { try? secrets.writeSession(pending) }
  }

  static func accountsDirectory() -> URL? {
    guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
      return nil
    }
    let dir = support.appendingPathComponent("Hasala", isDirectory: true).appendingPathComponent(
      "accounts", isDirectory: true)
    try? FileHygiene.prepareDirectory(dir)
    return dir
  }

  static func live(build: BuildInfo = .current) -> AppEnvironment {
    let base = BuildInfo.apiBaseURL()
    let keychain = KeychainSecretStore(accessGroup: keychainGroup)
    let install = purge(keychain)
    var store: any SecretStore = keychain
    var inMemory = false
    #if DEBUG && targetEnvironment(simulator)
      if let fallback = debugSecretStore(keychain) {
        store = fallback
        inMemory = true
      }
    #endif
    let transport = URLSessionTransport(
      baseURL: base, clientHeader: "ios/\(build.marketingVersion)/\(build.buildNumber)")
    let approvalKeys: any ApprovalKeySigner
    #if DEBUG && targetEnvironment(simulator)
      approvalKeys = SimulatorApprovalKey()
    #else
      approvalKeys = SecureEnclaveApprovalKey(store: store)
    #endif
    let env = AccountEnvironment(
      client: AuthClient(transport: transport), secrets: Secrets(store: store, apiHost: base.host() ?? "api.hasala.app"),
      approvalKeys: approvalKeys, passkeys: PasskeyProviderAdapter(), clock: SystemClock(), random: SystemRandom(),
      apiBase: base.absoluteString, accountsDirectory: accountsDirectory())
    let hasPasscode: @MainActor () -> Bool
    #if DEBUG && targetEnvironment(simulator)
      hasPasscode = { true }
    #else
      hasPasscode = { DevicePasscode.isSet() }
    #endif
    return AppEnvironment(
      build: build, apiBaseURL: base, transport: transport, account: env, keychain: keychain, installCheck: install,
      secretsInMemory: inMemory, hasPasscode: hasPasscode)
  }

  #if DEBUG && targetEnvironment(simulator)
    static func debugSecretStore(_ keychain: KeychainSecretStore) -> (any SecretStore)? {
      let probe = SecretItem.gmailRefresh(userID: UserID("00000000-0000-4000-8000-000000000000")!)
      do {
        try keychain.write(probe, Data([1]))
        try keychain.delete(probe)
        return nil
      } catch {
        return MemorySecretStore()
      }
    }
  #endif
}
