import CoreAuth
import CoreStore
import CoreSync
import Foundation
import UIKit
import os

@MainActor
final class PushRegistrar {
  static let shared = PushRegistrar()

  private var env: AccountEnvironment?
  private var userID: String?
  private var forgets = 0
  private let defaults: UserDefaults
  private let resolveEnvironment: () -> APNsEnvironmentResolution
  private let askForToken: () -> Void
  private let log = Logger(subsystem: "app.hasala.ios", category: "push")
  private nonisolated static let lastKey = "push.apns.registered.v2"
  private nonisolated static let legacyLastKey = "push.apns.registered.v1"

  init(
    defaults: UserDefaults = .standard, resolveEnvironment: @escaping () -> APNsEnvironmentResolution = resolveAPNsEnvironment,
    askForToken: @escaping () -> Void = { UIApplication.shared.registerForRemoteNotifications() }
  ) {
    self.defaults = defaults
    self.resolveEnvironment = resolveEnvironment
    self.askForToken = askForToken
  }

  func register(env: AccountEnvironment, userID: String) {
    self.env = env
    self.userID = userID
    askForToken()
  }

  func didRegister(token: Data) async {
    guard let env, let userID else { return }
    guard case .resolved(let raw) = resolveEnvironment(), let environment = APNsTokenEnvironment(rawValue: raw) else {
      log.info("apns environment unknown: token not registered")
      return
    }
    let hex = AuthClient.tokenHex(token)
    let key = LocalAccountData.digest("\(userID)|\(hex)|\(raw)", salt: LocalAccountData.salt(defaults))
    defaults.removeObject(forKey: Self.legacyLastKey)
    guard defaults.string(forKey: Self.lastKey) != key else { return }
    guard let session = try? env.secrets.activeSession() else { return }
    let forgetsBefore = forgets
    do {
      try await env.client.putAPNs(tokenHex: hex, environment: environment, bearer: session.token)
      guard forgets == forgetsBefore else { return }
      defaults.set(key, forKey: Self.lastKey)
    } catch {
      log.info("apns registration failed; retried next launch")
    }
  }

  func unregister() async {
    defer { forget() }
    guard let env, let session = try? env.secrets.activeSession() else { return }
    try? await env.client.deleteAPNs(bearer: session.token)
  }

  func forget() {
    forgets += 1
    Self.forgetRegistration(defaults)
    env = nil
    userID = nil
  }

  nonisolated static func forgetRegistration(_ defaults: UserDefaults) {
    defaults.removeObject(forKey: lastKey)
    defaults.removeObject(forKey: legacyLastKey)
  }
}
