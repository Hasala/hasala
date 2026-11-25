import AuthenticationServices
import CoreMailbox
import UIKit

@MainActor
final class WebAuthenticationPresenter: NSObject, GmailAuthSessionPresenter {
  private var session: ASWebAuthenticationSession?
  private var anchorProvider: FixedPresentationAnchor?
  private let currentAnchor: PresentationAnchors.Lookup
  let ephemeral: Bool

  init(ephemeral: Bool, anchor: @escaping PresentationAnchors.Lookup = PresentationAnchors.current) {
    self.ephemeral = ephemeral
    self.currentAnchor = anchor
    super.init()
  }

  convenience init(for provider: MailboxProvider) {
    self.init(ephemeral: provider.providerID.prefersEphemeralSession)
  }

  nonisolated func authorize(url: URL, callbackScheme: String) async throws(GmailOAuthError) -> URL {
    let result: Result<URL, GmailOAuthError> = await withCheckedContinuation { continuation in
      Task { @MainActor in
        self.start(url: url, scheme: callbackScheme) { continuation.resume(returning: $0) }
      }
    }
    return try result.get()
  }

  func makeSession(
    url: URL, scheme: String, completion: @escaping ASWebAuthenticationSession.CompletionHandler
  ) -> ASWebAuthenticationSession {
    let session = ASWebAuthenticationSession(url: url, callback: .customScheme(scheme), completionHandler: completion)
    session.prefersEphemeralWebBrowserSession = ephemeral
    return session
  }

  private func start(url: URL, scheme: String, done: @escaping (Result<URL, GmailOAuthError>) -> Void) {
    guard let anchor = currentAnchor() else {
      done(.failure(.malformedCallback))
      return
    }
    let provider = FixedPresentationAnchor(anchor)
    let session = makeSession(url: url, scheme: scheme) { [weak self] callback, error in
      Task { @MainActor in
        self?.session = nil
        self?.anchorProvider = nil
      }
      if let callback {
        done(.success(callback))
      } else if let e = error as? ASWebAuthenticationSessionError, e.code == .canceledLogin {
        done(.failure(.cancelled))
      } else {
        done(.failure(.malformedCallback))
      }
    }
    session.presentationContextProvider = provider
    self.session = session
    self.anchorProvider = provider
    if !session.start() {
      self.session = nil
      self.anchorProvider = nil
      done(.failure(.malformedCallback))
    }
  }
}
