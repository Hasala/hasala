import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

@MainActor
final class PasskeyAuthenticator: NSObject {
  static let relyingParty = "hasala.app"

  struct RawRegistration: Sendable, Equatable {
    var credentialID: Data
    var rawClientDataJSON: Data
    var rawAttestationObject: Data
    var prfFirst: Data?
  }

  struct RawAssertion: Sendable, Equatable {
    var credentialID: Data
    var rawClientDataJSON: Data
    var authenticatorData: Data
    var signature: Data
    var userHandle: Data
    var prfFirst: Data?
  }

  private let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: relyingParty)
  private var continuation: CheckedContinuation<ASAuthorization, Error>?
  private var controller: ASAuthorizationController?
  private var anchorProvider: FixedPresentationAnchor?
  private let currentAnchor: PresentationAnchors.Lookup

  init(anchor: @escaping PresentationAnchors.Lookup = PresentationAnchors.current) {
    self.currentAnchor = anchor
    super.init()
  }

  func register(challenge: Data, userID: Data, excludedCredentials: [Data] = [], prfSalt: Data?)
    async throws(AuthFailure) -> RawRegistration
  {
    let request = provider.createCredentialRegistrationRequest(challenge: challenge, name: "Hasala", userID: userID)
    request.userVerificationPreference = .required
    request.excludedCredentials = excludedCredentials.map {
      ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0)
    }
    if let prfSalt {
      request.prf = .inputValues(.init(saltInput1: prfSalt))
    }
    let auth = try await perform(request)
    guard let reg = auth.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration else {
      throw .refused
    }
    guard let attestation = reg.rawAttestationObject else { throw .refused }
    return RawRegistration(
      credentialID: reg.credentialID, rawClientDataJSON: reg.rawClientDataJSON,
      rawAttestationObject: attestation, prfFirst: reg.prf?.first.map(Self.bytes))
  }

  func assert(challenge: Data, allowedCredentials: [Data] = [], prfSalt: Data?) async throws(AuthFailure)
    -> RawAssertion
  {
    let request = provider.createCredentialAssertionRequest(challenge: challenge)
    request.userVerificationPreference = .required
    request.allowedCredentials = allowedCredentials.map { ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0) }
    if let prfSalt {
      request.prf = .inputValues(.init(saltInput1: prfSalt))
    }
    let auth = try await perform(request)
    guard let a = auth.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion else { throw .refused }
    return RawAssertion(
      credentialID: a.credentialID, rawClientDataJSON: a.rawClientDataJSON, authenticatorData: a.rawAuthenticatorData,
      signature: a.signature, userHandle: a.userID, prfFirst: a.prf.map { Self.bytes($0.first) })
  }

  static func reportUnknown(credentialID: Data) async {
    if #available(iOS 26.2, *) {
      try? await ASCredentialDataManager().reportUnknownPublicKeyCredential(
        relyingPartyIdentifier: relyingParty, credentialID: credentialID)
    } else {
      try? await ASCredentialUpdater().reportUnknownPublicKeyCredential(
        relyingPartyIdentifier: relyingParty, credentialID: credentialID)
    }
  }

  private static func bytes(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

  private func perform(_ request: ASAuthorizationRequest) async throws(AuthFailure) -> ASAuthorization {
    guard let anchor = currentAnchor() else { throw .unsupported }
    let anchorProvider = FixedPresentationAnchor(anchor)
    self.anchorProvider = anchorProvider
    do {
      return try await withCheckedThrowingContinuation { (c: CheckedContinuation<ASAuthorization, Error>) in
        continuation = c
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = anchorProvider
        self.controller = controller
        controller.performRequests()
      }
    } catch let error as ASAuthorizationError {
      switch error.code {
      case .canceled: throw .cancelled
      case .notInteractive, .matchedExcludedCredential: throw .noCredential
      case .notHandled, .failed, .invalidResponse, .unknown: throw .unsupported
      default: throw .unsupported
      }
    } catch {
      throw .unsupported
    }
  }

  private func finish(_ result: Result<ASAuthorization, Error>) {
    controller = nil
    anchorProvider = nil
    let c = continuation
    continuation = nil
    c?.resume(with: result)
  }
}

extension PasskeyAuthenticator: ASAuthorizationControllerDelegate {
  nonisolated func authorizationController(controller: ASAuthorizationController,
                                           didCompleteWithAuthorization authorization: ASAuthorization) {
    MainActor.assumeIsolated { finish(.success(authorization)) }
  }

  nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
    MainActor.assumeIsolated { finish(.failure(error)) }
  }
}
