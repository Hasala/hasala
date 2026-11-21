#if DEBUG && targetEnvironment(simulator)
  import CoreAuth
  import CorePrimitives
  import CryptoKit
  import Foundation

  nonisolated final class SimulatorApprovalKey: ApprovalKeySigner, @unchecked Sendable {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
      self.defaults = defaults
    }

    private static let prefix = "debug.simulatorApprovalKey."

    private static func key(_ userID: UserID, _ writerID: WriterID) -> String {
      "\(prefix)\(userID.string):\(writerID.string)"
    }

    static func forgetAll(_ defaults: UserDefaults) {
      for k in defaults.dictionaryRepresentation().keys where k.hasPrefix(prefix) {
        defaults.removeObject(forKey: k)
      }
    }

    func create(userID: UserID, writerID: WriterID) async throws(ApprovalKeyError) -> Data {
      let key = P256.Signing.PrivateKey()
      defaults.set(key.rawRepresentation, forKey: Self.key(userID, writerID))
      return key.publicKey.x963Representation
    }

    func publicKeyX963(userID: UserID, writerID: WriterID) throws(ApprovalKeyError) -> Data {
      try handle(userID, writerID).publicKey.x963Representation
    }

    func sign(_ message: Data, userID: UserID, writerID: WriterID, reason: String) async throws(ApprovalKeyError)
      -> Data
    {
      do {
        return try handle(userID, writerID).signature(for: message).rawRepresentation
      } catch {
        throw .unavailable
      }
    }

    private func handle(_ userID: UserID, _ writerID: WriterID) throws(ApprovalKeyError) -> P256.Signing.PrivateKey {
      guard let raw = defaults.data(forKey: Self.key(userID, writerID)),
        let key = try? P256.Signing.PrivateKey(rawRepresentation: raw)
      else { throw .missing }
      return key
    }
  }
#endif
