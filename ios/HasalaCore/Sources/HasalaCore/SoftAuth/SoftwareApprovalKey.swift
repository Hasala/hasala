import CoreAuth
import CorePrimitives
import CryptoKit
import Foundation
import Synchronization

public final class SoftwareApprovalKeySigner: ApprovalKeySigner {
  private struct Slot: Hashable {
    let user: UserID
    let writer: WriterID
  }

  private let keys = Mutex<[Slot: P256.Signing.PrivateKey]>([:])
  private let failure = Mutex<ApprovalKeyError?>(nil)
  private let count = Mutex(0)

  public init() {}

  public func install(privateScalar: Data, userID: UserID, writerID: WriterID) throws(ApprovalKeyError) {
    guard let k = try? P256.Signing.PrivateKey(rawRepresentation: privateScalar) else { throw .unavailable }
    keys.withLock { $0[Slot(user: userID, writer: writerID)] = k }
  }

  public func failNext(_ error: ApprovalKeyError) { failure.withLock { $0 = error } }

  public var signatureCount: Int { count.withLock { $0 } }

  public func create(userID: UserID, writerID: WriterID) async throws(ApprovalKeyError) -> Data {
    if let e = takeFailure() { throw e }
    let k = P256.Signing.PrivateKey()
    keys.withLock { $0[Slot(user: userID, writer: writerID)] = k }
    return k.publicKey.x963Representation
  }

  public func publicKeyX963(userID: UserID, writerID: WriterID) throws(ApprovalKeyError) -> Data {
    guard let k = keys.withLock({ $0[Slot(user: userID, writer: writerID)] }) else { throw .missing }
    return k.publicKey.x963Representation
  }

  public func sign(_ message: Data, userID: UserID, writerID: WriterID, reason: String) async throws(ApprovalKeyError)
    -> Data
  {
    if let e = takeFailure() { throw e }
    guard let k = keys.withLock({ $0[Slot(user: userID, writer: writerID)] }) else { throw .missing }
    guard let sig = try? k.signature(for: message) else { throw .unavailable }
    count.withLock { $0 += 1 }
    return sig.rawRepresentation
  }

  public func remove(userID: UserID, writerID: WriterID) {
    _ = keys.withLock { $0.removeValue(forKey: Slot(user: userID, writer: writerID)) }
  }

  private func takeFailure() -> ApprovalKeyError? {
    failure.withLock { f in
      defer { f = nil }
      return f
    }
  }
}
