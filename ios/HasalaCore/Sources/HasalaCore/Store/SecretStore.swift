import CoreAuth
import CorePrimitives
import Foundation
import Synchronization

public enum SecretItem: Sendable, Hashable {
  case session(apiHost: String)
  case accountBinding
  case epochKey(userID: UserID, epoch: UInt32)
  case writerKey(userID: UserID, writerID: WriterID)
  case approvalKey(userID: UserID, writerID: WriterID)
  case mailRefresh(provider: MailSecretProvider, userID: UserID)
  case outlookClientState(userID: UserID)
  case textKeySecret
  case readerWordKey

  public static func gmailRefresh(userID: UserID) -> SecretItem { .mailRefresh(provider: .gmail, userID: userID) }

  public var service: String {
    switch self {
    case .session: "app.hasala.session"
    case .accountBinding: "app.hasala.account"
    case .epochKey: "app.hasala.epoch-key"
    case .writerKey: "app.hasala.writer-key"
    case .approvalKey: "app.hasala.approval-key"
    case .mailRefresh(.gmail, _): "app.hasala.gmail.refresh"
    case .mailRefresh(.outlook, _): "app.hasala.outlook.refresh"
    case .outlookClientState: "app.hasala.outlook.clientstate"
    case .textKeySecret: "app.hasala.text-key"
    case .readerWordKey: "app.hasala.reader-key"
    }
  }

  public var account: String {
    switch self {
    case .session(let host): host
    case .accountBinding: "binding"
    case .epochKey(let u, let e): "\(u.string):\(e)"
    case .writerKey(let u, let w), .approvalKey(let u, let w): "\(u.string):\(w.string)"
    case .mailRefresh(_, let u), .outlookClientState(let u): u.string
    case .textKeySecret, .readerWordKey: "device"
    }
  }

  public var accessibility: SecretAccessibility {
    switch self {
    case .approvalKey: .whenPasscodeSetThisDeviceOnly
    default: .afterFirstUnlockThisDeviceOnly
    }
  }

  public static let writerServices = ["app.hasala.writer-key", "app.hasala.approval-key"]

  public static let allServices = [
    "app.hasala.session", "app.hasala.account", "app.hasala.epoch-key", "app.hasala.writer-key",
    "app.hasala.approval-key", "app.hasala.gmail.refresh", "app.hasala.outlook.refresh",
    "app.hasala.outlook.clientstate", "app.hasala.text-key", "app.hasala.reader-key",
  ]
}

public enum MailSecretProvider: String, Sendable, Hashable, CaseIterable {
  case gmail
  case outlook
}

public enum SecretAccessibility: Sendable, Hashable {
  case afterFirstUnlockThisDeviceOnly
  case whenPasscodeSetThisDeviceOnly
}

public enum SecretStoreError: Error, Sendable, Hashable {
  case notNow(status: Int32)
  case readBackMismatch
  case failed(status: Int32)
}

extension ApprovalKeyError {
  public init(storeError: SecretStoreError) {
    if case .notNow = storeError { self = .notNow } else { self = .unavailable }
  }
}

public protocol SecretStore: Sendable {
  func read(_ item: SecretItem) throws(SecretStoreError) -> Data?
  func write(_ item: SecretItem, _ value: Data) throws(SecretStoreError)
  func delete(_ item: SecretItem) throws(SecretStoreError)
  func accounts(service: String) throws(SecretStoreError) -> [String]
}

public final class MemorySecretStore: SecretStore {
  private struct Key: Hashable {
    let service: String
    let account: String
  }

  private let items = Mutex<[Key: Data]>([:])
  private let lockedState = Mutex(false)

  public init() {}

  public var locked: Bool {
    get { lockedState.withLock { $0 } }
    set { lockedState.withLock { $0 = newValue } }
  }

  public func read(_ item: SecretItem) throws(SecretStoreError) -> Data? {
    if locked { throw .notNow(status: -25308) }
    return items.withLock { $0[Key(service: item.service, account: item.account)] }
  }

  public func write(_ item: SecretItem, _ value: Data) throws(SecretStoreError) {
    if locked { throw .notNow(status: -25308) }
    items.withLock { $0[Key(service: item.service, account: item.account)] = value }
  }

  public func delete(_ item: SecretItem) throws(SecretStoreError) {
    if locked { throw .notNow(status: -25308) }
    _ = items.withLock { $0.removeValue(forKey: Key(service: item.service, account: item.account)) }
  }

  public func accounts(service: String) throws(SecretStoreError) -> [String] {
    if locked { throw .notNow(status: -25308) }
    return items.withLock { $0.keys.filter { $0.service == service }.map(\.account) }
  }

  public var count: Int { items.withLock { $0.count } }

  public func removeAll() { items.withLock { $0.removeAll() } }
}
