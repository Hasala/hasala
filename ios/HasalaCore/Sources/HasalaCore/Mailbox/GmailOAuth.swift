import CoreJSON
import CorePrimitives
import Foundation

public struct GmailOAuthConfig: Sendable, Equatable {
  public let clientID: String
  public let redirectScheme: String
  public let authorizeEndpoint: String
  public let tokenEndpoint: String
  public let revokeEndpoint: String

  public static let gmailReadonlyScope = "https://www.googleapis.com/auth/gmail.readonly"
  public static let scopes = "openid email \(gmailReadonlyScope)"

  public init(
    clientID: String, redirectScheme: String,
    authorizeEndpoint: String = "https://accounts.google.com/o/oauth2/v2/auth",
    tokenEndpoint: String = "https://oauth2.googleapis.com/token",
    revokeEndpoint: String = "https://oauth2.googleapis.com/revoke"
  ) {
    self.clientID = clientID
    self.redirectScheme = redirectScheme
    self.authorizeEndpoint = authorizeEndpoint
    self.tokenEndpoint = tokenEndpoint
    self.revokeEndpoint = revokeEndpoint
  }

  public var redirectURI: String { "\(redirectScheme):/oauth2redirect" }

  public var isConfigured: Bool {
    !clientID.isEmpty && clientID != "unset" && !redirectScheme.isEmpty && redirectScheme != "unset"
  }
}

public enum PKCE {
  public static func makeVerifier(random: any RandomSource) throws(PrimitivesError) -> String {
    Base64.encodeURL(try random.bytes(32))
  }

  public static func challenge(verifier: String) -> String {
    Base64.encodeURL(sha256(Data(verifier.utf8)))
  }

  public static func makeState(random: any RandomSource) throws(PrimitivesError) -> String {
    Base64.encodeURL(try random.bytes(32))
  }
}

public typealias GmailOAuthError = MailOAuthError

public struct GoogleIDTokenClaims: Sendable, Equatable {
  public let email: String?
  public let emailVerified: Bool
  public let nonce: String?
  public let sub: String?

  public init?(idToken: String) {
    guard let o = OAuthWire.claims(idToken) else { return nil }
    email = o["email"]?.stringValue
    emailVerified = o["email_verified"]?.boolValue ?? (o["email_verified"]?.stringValue == "true")
    nonce = o["nonce"]?.stringValue
    sub = o["sub"]?.stringValue
  }
}

public struct GoogleOAuthClient: Sendable {
  public let config: GmailOAuthConfig
  let http: any HTTPExchange

  public init(config: GmailOAuthConfig, http: any HTTPExchange) {
    self.config = config
    self.http = http
  }

  public func begin(nonce: String, random: any RandomSource) throws(GmailOAuthError) -> MailAuthorization {
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
        ("client_id", config.clientID), ("redirect_uri", config.redirectURI), ("response_type", "code"),
        ("scope", GmailOAuthConfig.scopes), ("code_challenge", PKCE.challenge(verifier: verifier)),
        ("code_challenge_method", "S256"), ("state", state), ("nonce", nonce), ("prompt", "select_account consent"),
        ("access_type", "offline"),
      ])
    return MailAuthorization(url: url, state: state, codeVerifier: verifier, nonce: nonce)
  }

  public func code(fromCallback callback: URL, for auth: MailAuthorization) throws(GmailOAuthError) -> String {
    try OAuthWire.code(fromCallback: callback, scheme: config.redirectScheme, state: auth.state)
  }

  public func exchange(code: String, auth: MailAuthorization) async throws(GmailOAuthError) -> MailTokenGrant {
    let grant = try await token([
      ("grant_type", "authorization_code"), ("code", code), ("client_id", config.clientID),
      ("code_verifier", auth.codeVerifier), ("redirect_uri", config.redirectURI),
    ])
    guard let r = grant.refreshToken, !r.isEmpty, let id = grant.idToken, !id.isEmpty,
      let scope = grant.scope,
      scope.split(separator: " ").contains(where: { $0 == GmailOAuthConfig.gmailReadonlyScope })
    else { throw .missingGrant }
    return grant
  }

  public func refresh(refreshToken: String) async throws(GmailOAuthError) -> MailTokenGrant {
    try await token([
      ("grant_type", "refresh_token"), ("refresh_token", refreshToken), ("client_id", config.clientID),
    ])
  }

  public func revoke(token: String) async throws(GmailOAuthError) {
    let req = HTTPRequest(
      method: .post, url: URL(string: config.revokeEndpoint)!,
      headers: [("Content-Type", "application/x-www-form-urlencoded")],
      body: Data(FormEncoding.encode([("token", token)]).utf8))
    let res: HTTPResponse
    do { res = try await http.send(req) } catch { throw .offline }
    if res.ok || res.status == 400 { return }
    throw .http(res.status)
  }

  func token(_ form: [(String, String)]) async throws(GmailOAuthError) -> MailTokenGrant {
    try await OAuthWire.token(http: http, endpoint: config.tokenEndpoint, form: form)
  }
}

enum OAuthWire {
  static func code(fromCallback callback: URL, scheme: String, state want: String) throws(MailOAuthError) -> String {
    guard callback.scheme == scheme, let comps = URLComponents(url: callback, resolvingAgainstBaseURL: false) else {
      throw .malformedCallback
    }
    let items = comps.queryItems ?? []
    func item(_ n: String) -> String? { items.first { $0.name == n }?.value }
    let state = item("state") ?? ""
    guard constantTimeEquals(Data(state.utf8), Data(want.utf8)) else { throw .stateMismatch }
    if let err = item("error") {
      throw err == "access_denied" ? .cancelled : .denied(String(err.prefix(64)))
    }
    guard let code = item("code"), !code.isEmpty else { throw .malformedCallback }
    return code
  }

  static func token(http: any HTTPExchange, endpoint: String, form: [(String, String)]) async throws(MailOAuthError)
    -> MailTokenGrant
  {
    let req = HTTPRequest(
      method: .post, url: URL(string: endpoint)!,
      headers: [("Content-Type", "application/x-www-form-urlencoded"), ("Accept", "application/json")],
      body: Data(FormEncoding.encode(form).utf8))
    let res: HTTPResponse
    do { res = try await http.send(req) } catch { throw .offline }
    let body = (try? JSONParser.parse([UInt8](res.body)))?.objectValue
    guard res.ok else {
      if body?["error"]?.stringValue == "invalid_grant" { throw .invalidGrant }
      throw .http(res.status)
    }
    guard let b = body, let access = b["access_token"]?.stringValue, !access.isEmpty else {
      throw .malformedResponse
    }
    let expires = b["expires_in"]?.numberValue?.int64Value ?? 3600
    return MailTokenGrant(
      accessToken: access, expiresIn: max(0, expires), refreshToken: b["refresh_token"]?.stringValue,
      idToken: b["id_token"]?.stringValue, scope: b["scope"]?.stringValue)
  }

  static func claims(_ jwt: String) -> JSONObject? {
    let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3, let payload = try? Base64.decodeURL(String(parts[1])),
      let v = try? JSONParser.parse([UInt8](payload))
    else { return nil }
    return v.objectValue
  }
}

public typealias GmailAuthSessionPresenter = MailAuthSessionPresenter

extension GoogleOAuthClient: MailOAuthClient {
  public var isConfigured: Bool { config.isConfigured }
  public var redirectScheme: String { config.redirectScheme }

  public func identity(idToken: String) -> MailIdentity? {
    GoogleIDTokenClaims(idToken: idToken).map { MailIdentity(email: $0.email, nonce: $0.nonce) }
  }
}
