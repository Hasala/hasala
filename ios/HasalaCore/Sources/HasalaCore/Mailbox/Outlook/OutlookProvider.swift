import CoreMail
import CoreTime
import Foundation

public struct OutlookProvider: MailProvider {
  public static let downloadWidth = 3

  public let microsoft: MicrosoftOAuthClient
  let http: any HTTPExchange
  let base: String
  let link: any OutlookLinkStore
  let clock: any Clock

  public init(
    oauth: MicrosoftOAuthClient, http: any HTTPExchange, link: any OutlookLinkStore, clock: any Clock,
    base: String = GraphClient.defaultBase
  ) {
    microsoft = oauth
    self.http = http
    self.link = link
    self.clock = clock
    self.base = base
  }

  public var id: MailProviderID { .outlook }
  public var oauth: any MailOAuthClient { microsoft }
  public var maxDownloadWidth: Int { Self.downloadWidth }
  public var stopIsDeviceScoped: Bool { true }

  public func source(accessToken: AccessToken) -> any MailSource { graph(accessToken: accessToken.value) }

  public var listsByAddress: Bool { true }

  public func source(accessToken: AccessToken, senderAddresses: [String]) -> any MailSource {
    graph(accessToken: accessToken.value, senderAddresses: senderAddresses)
  }

  public func unlisted(_ trusted: [String], senderAddresses: [String]) -> [String] {
    OutlookSenders.unlisted(trusted, known: OutlookSenders.known + senderAddresses)
  }

  public func graph(accessToken: String, senderAddresses: [String] = []) -> GraphClient {
    let clock = self.clock
    return GraphClient(
      http: http, accessToken: accessToken, link: link, base: base, knownSenders: OutlookSenders.known + senderAddresses,
      nowMs: { clock.nowMs() })
  }

  public func analyzeAuthResults(_ headerBlock: String) -> AuthResults.Analysis {
    analyzeAuthResults(headerBlock, inInbox: nil, senderAddresses: [])
  }

  public func analyzeAuthResults(_ headerBlock: String, inInbox: Bool?, senderAddresses: [String])
    -> AuthResults.Analysis
  {
    AuthResults.analyzeOutlookSender(
      headerBlock, inInbox: inInbox ?? false, knownSenders: OutlookSenders.known + senderAddresses,
      rejectDomains: OutlookSenders.dmarcReject)
  }

  public func installLink(_ result: MailboxLinkResult) throws(MailAuthError) {
    do {
      if let cs = result.clientState, !cs.isEmpty {
        try link.write(OutlookLinkState(clientState: cs))
      } else {
        try link.delete()
      }
    } catch {
      throw .notNow
    }
  }

  public func forgetLink() { try? link.delete() }
}
