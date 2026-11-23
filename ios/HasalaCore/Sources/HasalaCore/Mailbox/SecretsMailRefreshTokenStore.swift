import CorePrimitives
import CoreStore
import Foundation

public struct SecretsMailRefreshTokenStore: MailRefreshTokenStore {
  let store: any SecretStore
  let item: SecretItem

  public init(secrets: Secrets, userID: UserID, provider: MailProviderID) {
    store = secrets.store
    item = .mailRefresh(provider: provider.secretProvider, userID: userID)
  }

  public init(secrets: Secrets, userID: UserID) {
    self.init(secrets: secrets, userID: userID, provider: .gmail)
  }

  public func read() throws(SecretUnavailable) -> String? {
    let d: Data?
    do { d = try store.read(item) } catch { throw SecretUnavailable() }
    guard let d else { return nil }
    guard let s = String(data: d, encoding: .utf8), !s.isEmpty else {
      do { try store.delete(item) } catch { throw SecretUnavailable() }
      return nil
    }
    return s
  }

  public func write(_ token: String) throws(SecretUnavailable) {
    let bytes = Data(token.utf8)
    do {
      try store.write(item, bytes)
      guard try store.read(item) == bytes else { throw SecretUnavailable() }
    } catch {
      throw SecretUnavailable()
    }
  }

  public func delete() throws(SecretUnavailable) {
    do { try store.delete(item) } catch { throw SecretUnavailable() }
  }
}

public typealias SecretsGmailRefreshTokenStore = SecretsMailRefreshTokenStore

extension MailProviderID {
  public var secretProvider: MailSecretProvider {
    switch self {
    case .gmail: .gmail
    case .outlook: .outlook
    }
  }
}
