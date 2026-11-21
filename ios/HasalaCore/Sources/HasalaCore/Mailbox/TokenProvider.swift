import CoreTime
import Foundation

public struct AccessToken: Sendable, Equatable {
  public let value: String
  public let expiresAtMs: Int64
  public init(value: String, expiresAtMs: Int64) {
    self.value = value
    self.expiresAtMs = expiresAtMs
  }
}

public enum MailAuthError: Error, Sendable, Equatable {
  case reconnectRequired
  case notNow
  case offline
}

public typealias GmailAuthError = MailAuthError

public protocol MailTokenProvider: Sendable {
  func accessToken(forceRefresh: Bool) async throws(MailAuthError) -> AccessToken
}

public struct SecretUnavailable: Error, Sendable, Equatable {
  public init() {}
}

public protocol MailRefreshTokenStore: Sendable {
  func read() throws(SecretUnavailable) -> String?
  func write(_ token: String) throws(SecretUnavailable)
  func delete() throws(SecretUnavailable)
}

public final class MemoryMailRefreshTokenStore: MailRefreshTokenStore, @unchecked Sendable {
  private let lock = NSLock()
  private var token: String?
  public var locked = false

  public init(token: String? = nil) { self.token = token }

  public func read() throws(SecretUnavailable) -> String? {
    lock.lock()
    defer { lock.unlock() }
    if locked { throw SecretUnavailable() }
    return token
  }
  public func write(_ t: String) throws(SecretUnavailable) {
    lock.lock()
    defer { lock.unlock() }
    if locked { throw SecretUnavailable() }
    token = t
  }
  public func delete() throws(SecretUnavailable) {
    lock.lock()
    defer { lock.unlock() }
    if locked { throw SecretUnavailable() }
    token = nil
  }
}

public typealias MemoryGmailRefreshTokenStore = MemoryMailRefreshTokenStore

public actor RefreshingMailTokenProvider: MailTokenProvider {
  let oauth: any MailOAuthClient
  let store: any MailRefreshTokenStore
  let clock: any Clock
  private var cached: AccessToken?

  public static let refreshMarginMs: Int64 = 60_000

  public static let writeCheckValue = "hasala.keychain-write-check"

  public init(oauth: any MailOAuthClient, store: any MailRefreshTokenStore, clock: any Clock) {
    self.oauth = oauth
    self.store = store
    self.clock = clock
  }

  public func accessToken(forceRefresh: Bool) async throws(MailAuthError) -> AccessToken {
    if !forceRefresh, let c = cached, c.expiresAtMs - clock.nowMs() > Self.refreshMarginMs { return c }
    let refresh: String?
    do { refresh = try store.read() } catch { throw .notNow }
    guard let refresh, !refresh.isEmpty else {
      cached = nil
      throw .reconnectRequired
    }
    if refresh == Self.writeCheckValue {
      cached = nil
      try? store.delete()
      throw .reconnectRequired
    }
    do {
      let grant = try await oauth.refresh(refreshToken: refresh)
      if let next = grant.refreshToken, !next.isEmpty, next != refresh { try? store.write(next) }
      let t = AccessToken(value: grant.accessToken, expiresAtMs: clock.nowMs() + grant.expiresIn * 1000)
      cached = t
      return t
    } catch .invalidGrant {
      cached = nil
      try? store.delete()
      throw .reconnectRequired
    } catch {
      throw .offline
    }
  }

  public func install(grant: MailTokenGrant) throws(MailAuthError) {
    guard let r = grant.refreshToken else { throw .reconnectRequired }
    do { try store.write(r) } catch { throw .notNow }
    cached = AccessToken(value: grant.accessToken, expiresAtMs: clock.nowMs() + grant.expiresIn * 1000)
  }

  @discardableResult
  public func replace(with grant: MailTokenGrant) throws(MailAuthError) -> String? {
    let prior: String?
    do { prior = try store.read() } catch { throw .notNow }
    try install(grant: grant)
    return prior
  }

  public func checkWritable(for grant: MailTokenGrant) throws(MailAuthError) {
    guard grant.refreshToken != nil else { throw .reconnectRequired }
    let prior: String?
    do { prior = try store.read() } catch { throw .notNow }
    do {
      try store.write(prior ?? Self.writeCheckValue)
      if prior == nil { try store.delete() }
    } catch {
      if prior == nil { try? store.delete() }
      throw .notNow
    }
  }

  public func restore(_ token: String?) {
    cached = nil
    if let token { try? store.write(token) } else { try? store.delete() }
  }

  public func hasRefreshToken() -> Bool? {
    do { return try store.read() != nil } catch { return nil }
  }

  public func forget() {
    cached = nil
    try? store.delete()
  }

  @discardableResult
  public func revokeAndForget(keepOnFailure: Bool = true) async -> Bool {
    let revoked = await revoke(stopOnFailure: keepOnFailure)
    if revoked || !keepOnFailure { try? store.delete() }
    return revoked
  }

  public func revoke(stopOnFailure: Bool = true) async -> Bool {
    cached = nil
    let token: String?
    do { token = try store.read() } catch { return false }
    if let token, !token.isEmpty, token != Self.writeCheckValue {
      do throws(MailOAuthError) {
        try await oauth.revoke(token: token)
      } catch {
        if stopOnFailure { return false }
      }
    }
    return true
  }

  public func invalidate() { cached = nil }
}

public typealias RefreshingGmailTokenProvider = RefreshingMailTokenProvider
