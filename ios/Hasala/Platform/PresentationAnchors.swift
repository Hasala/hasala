import AuthenticationServices
import UIKit

enum PresentationAnchors {
  typealias Lookup = @MainActor () -> ASPresentationAnchor?

  static func current() -> ASPresentationAnchor? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let windows = scenes.flatMap(\.windows)
    if let window = windows.first(where: \.isKeyWindow) ?? windows.first { return window }
    return scenes.first.map { ASPresentationAnchor(windowScene: $0) }
  }
}

final class FixedPresentationAnchor: NSObject, ASWebAuthenticationPresentationContextProviding,
  ASAuthorizationControllerPresentationContextProviding
{
  let anchor: ASPresentationAnchor

  init(_ anchor: ASPresentationAnchor) {
    self.anchor = anchor
    super.init()
  }

  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { anchor }

  nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
    MainActor.assumeIsolated { anchor }
  }
}
