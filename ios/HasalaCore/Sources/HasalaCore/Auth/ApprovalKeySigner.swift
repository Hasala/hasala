import CorePrimitives
import Foundation

public protocol ApprovalKeySigner: Sendable {
  func create(userID: UserID, writerID: WriterID) async throws(ApprovalKeyError) -> Data
  func publicKeyX963(userID: UserID, writerID: WriterID) throws(ApprovalKeyError) -> Data
  func sign(_ message: Data, userID: UserID, writerID: WriterID, reason: String) async throws(ApprovalKeyError) -> Data
}

public enum ApprovalKeyError: Error, Sendable, Equatable {
  case unavailable
  case missing
  case cancelled
  case notNow
}
