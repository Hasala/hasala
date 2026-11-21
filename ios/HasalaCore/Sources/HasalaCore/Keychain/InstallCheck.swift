import CorePrimitives
import CoreStore
import Foundation

public enum InstallCheck {
  public static let installIDKey = "app.hasala.installID"

  public enum Outcome: Sendable, Hashable {
    case done
    case notNow(statuses: [Int32])
  }

  public static func run(
    protectedDataAvailable: Bool, defaults: UserDefaults, keychain: KeychainSecretStore, groups: [String?],
    widgetsDirectory: URL?, apiHost: String? = nil, random: any RandomSource = SystemRandom()
  ) -> Outcome {
    guard protectedDataAvailable else { return .notNow(statuses: []) }
    if defaults.string(forKey: installIDKey) != nil { return .done }
    let id: String
    do {
      id = try random.uuidV4()
    } catch .randomUnavailable(let status) {
      return .notNow(statuses: [status])
    } catch {
      return .notNow(statuses: [])
    }
    var kept: SecretItem?
    if let apiHost {
      switch markStranded(Secrets(store: keychain, apiHost: apiHost)) {
      case .wait(let statuses): return .notNow(statuses: statuses)
      case .nothing: break
      case .marked: kept = .session(apiHost: apiHost)
      }
    }
    let (complete, statuses) = keychain.purgeAll(groups: groups, sparing: kept)
    guard complete else { return .notNow(statuses: statuses) }
    if let w = widgetsDirectory { removeWidgets(w) }
    defaults.set(id, forKey: installIDKey)
    return .done
  }

  private static let log = CoreLog(category: "HasalaKeychain")

  private enum Stranded {
    case nothing
    case marked
    case wait(statuses: [Int32])
  }

  private static func markStranded(_ secrets: Secrets) -> Stranded {
    var stranded: SessionRecord?
    do {
      stranded = try secrets.session()
    } catch .notNow(let status) {
      return .wait(statuses: [status])
    } catch {
      log.error("install_session_unreadable")
      return .nothing
    }
    guard var record = stranded else { return .nothing }
    if record.pending_logout { return .marked }
    record.pending_logout = true
    do {
      try secrets.writeSession(record)
    } catch .notNow(let status), .failed(let status) {
      return .wait(statuses: [status])
    } catch {
      return .wait(statuses: [])
    }
    return .marked
  }

  private static func removeWidgets(_ directory: URL) {
    guard FileManager.default.fileExists(atPath: directory.path) else { return }
    do {
      try FileManager.default.removeItem(at: directory)
    } catch {
      log.error("install_widget_snapshot_not_removed")
    }
  }

  public static func erase(defaults: UserDefaults, keychain: KeychainSecretStore, groups: [String?]) -> Outcome {
    let (complete, statuses) = keychain.purgeAll(groups: groups)
    guard !complete else { return .done }
    defaults.removeObject(forKey: installIDKey)
    return .notNow(statuses: statuses)
  }
}
