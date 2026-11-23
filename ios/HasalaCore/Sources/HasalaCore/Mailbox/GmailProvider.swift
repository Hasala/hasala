import CoreMail
import Foundation

public struct GmailProvider: MailProvider {
  public let google: GoogleOAuthClient
  let http: any HTTPExchange
  let base: String

  public init(oauth: GoogleOAuthClient, http: any HTTPExchange, base: String = GmailClient.defaultBase) {
    google = oauth
    self.http = http
    self.base = base
  }

  public var id: MailProviderID { .gmail }
  public var oauth: any MailOAuthClient { google }

  public func source(accessToken: AccessToken) -> any MailSource {
    GmailClient(http: http, accessToken: accessToken.value, base: base)
  }

  public func analyzeAuthResults(_ headerBlock: String) -> AuthResults.Analysis { AuthResults.analyze(headerBlock) }
}
