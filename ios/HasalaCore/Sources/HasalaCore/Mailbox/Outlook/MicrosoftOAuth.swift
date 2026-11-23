import CoreJSON
import CorePrimitives
import Foundation

public struct MicrosoftOAuthConfig: Sendable, Equatable {
  public let clientID: String
  public let redirectScheme: String
  public let authorizeEndpoint: String
  public let tokenEndpoint: String

  public static let consumersTenantID = "9188040d-6c67-4c5b-b112-36a304b66dad"
  public static let mailReadScope = "https://graph.microsoft.com/Mail.Read"
  public static let scopes = "openid email profile offline_access \(mailReadScope)"
  public static let consentManagementURL = "https://account.live.com/consent/Manage"

  public init(
    clientID: String, redirectScheme: String,
    authorizeEndpoint: String = "https://login.microsoftonline.com/consumers/oauth2/v2.0/authorize",
    tokenEndpoint: String = "https://login.microsoftonline.com/consumers/oauth2/v2.0/token"
  ) {
    self.clientID = clientID
    self.redirectScheme = redirectScheme
    self.authorizeEndpoint = authorizeEndpoint
    self.tokenEndpoint = tokenEndpoint
  }

  public var redirectURI: String { "\(redirectScheme)://auth" }

  public var isConfigured: Bool {
    !clientID.isEmpty && clientID != "unset" && !redirectScheme.isEmpty && redirectScheme != "unset"
  }

  public static func grantsMailRead(_ scope: String?) -> Bool {
    guard let scope else { return false }
    return scope.split(separator: " ").contains { s in
      let l = s.lowercased()
      return l == mailReadScope.lowercased() || l == "mail.read"
    }
  }
}

public struct MicrosoftIDTokenClaims: Sendable, Equatable {
  public let email: String?
  public let preferredUsername: String?
  public let nonce: String?
  public let tid: String?

  public init?(idToken: String) {
    guard let o = OAuthWire.claims(idToken) else { return nil }
    email = o["email"]?.stringValue
    preferredUsername = o["preferred_username"]?.stringValue
    nonce = o["nonce"]?.stringValue
    tid = o["tid"]?.stringValue
  }

  public var address: String? {
    if let e = email, !e.isEmpty { return e }
    if let p = preferredUsername, p.contains("@") { return p }
    return nil
  }
}

public struct MicrosoftOAuthClient: Sendable {
  public let config: MicrosoftOAuthConfig
  let http: any HTTPExchange

  public init(config: MicrosoftOAuthConfig, http: any HTTPExchange) {
    self.config = config
    self.http = http
  }

  public func begin(nonce: String, random: any RandomSource) throws(MailOAuthError) -> MailAuthorization {
    guard config.isConfigured else { throw .notConfigured }
    let verifier: String
    let state: String
    do {
      verifier = try PKCE.makeVerifier(random: random)
      state = try PKCE.makeState(random: random)
    } catch {
      throw .malformedResponse
    }
    let url = URL.build(
      config.authorizeEndpoint, "",
      [
        ("client_id", config.clientID), ("response_type", "code"), ("redirect_uri", config.redirectURI),
        ("response_mode", "query"), ("scope", MicrosoftOAuthConfig.scopes),
        ("code_challenge", PKCE.challenge(verifier: verifier)), ("code_challenge_method", "S256"),
        ("state", state), ("nonce", nonce), ("prompt", "consent"),
      ])
    return MailAuthorization(url: url, state: state, codeVerifier: verifier, nonce: nonce)
  }

  public func code(fromCallback callback: URL, for auth: MailAuthorization) throws(MailOAuthError) -> String {
    try OAuthWire.code(fromCallback: callback, scheme: config.redirectScheme, state: auth.state)
  }

  public func exchange(code: String, auth: MailAuthorization) async throws(MailOAuthError) -> MailTokenGrant {
    let grant = try await OAuthWire.token(
      http: http, endpoint: config.tokenEndpoint,
      form: [
        ("client_id", config.clientID), ("grant_type", "authorization_code"), ("code", code),
        ("redirect_uri", config.redirectURI), ("code_verifier", auth.codeVerifier),
        ("scope", MicrosoftOAuthConfig.scopes),
      ])
    guard let r = grant.refreshToken, !r.isEmpty, let id = grant.idToken, !id.isEmpty,
      MicrosoftOAuthConfig.grantsMailRead(grant.scope)
    else { throw .missingGrant }
    return grant
  }

  public func refresh(refreshToken: String) async throws(MailOAuthError) -> MailTokenGrant {
    try await OAuthWire.token(
      http: http, endpoint: config.tokenEndpoint,
      form: [
        ("client_id", config.clientID), ("grant_type", "refresh_token"), ("refresh_token", refreshToken),
        ("scope", MicrosoftOAuthConfig.scopes),
      ])
  }
}

extension MicrosoftOAuthClient: MailOAuthClient {
  public var isConfigured: Bool { config.isConfigured }
  public var redirectScheme: String { config.redirectScheme }

  public func revoke(token: String) async throws(MailOAuthError) {}

  public func identity(idToken: String) -> MailIdentity? {
    guard let c = MicrosoftIDTokenClaims(idToken: idToken), c.tid == MicrosoftOAuthConfig.consumersTenantID else {
      return nil
    }
    return MailIdentity(email: c.address, nonce: c.nonce)
  }
}
