import CorePrimitives
import CoreWire
import Foundation
import HasalaText

public enum KeyHistoryVerifier {
  public struct Entry: Sendable, Hashable {
    public let id: Int64
    public let writerID: String
    public let alg: String
    public let publicKey: Data
    public let dakPublicKey: Data?
    public let event: String
    public let authorizedBy: String
    public let authorizerWriterID: String?
    public let finalCounter: Int64?
    public let finalHead: Data?
    public let nonce: Data
    public let signature: Data

    public init(
      id: Int64, writerID: String, alg: String, publicKey: Data, dakPublicKey: Data?, event: String,
      authorizedBy: String, authorizerWriterID: String?, finalCounter: Int64?, finalHead: Data?, nonce: Data,
      signature: Data
    ) {
      self.id = id
      self.writerID = writerID
      self.alg = alg
      self.publicKey = publicKey
      self.dakPublicKey = dakPublicKey
      self.event = event
      self.authorizedBy = authorizedBy
      self.authorizerWriterID = authorizerWriterID
      self.finalCounter = finalCounter
      self.finalHead = finalHead
      self.nonce = nonce
      self.signature = signature
    }
  }

  public struct Writer: Sendable, Hashable {
    public let dwkPublicKey: Data
    public let dakPublicKey: Data
    public let final: Chain.Head?
    public var isLive: Bool { final == nil }
  }

  public struct Roster: Sendable, Hashable {
    public let writers: [WriterID: Writer]
    public let lastEntryID: Int64?

    public static let empty = Roster(writers: [:], lastEntryID: nil)

    public var forReader: [WriterID: HeadCheck.RosterWriter] {
      writers.mapValues { HeadCheck.RosterWriter(dwkPublicKey: $0.dwkPublicKey, revokedAt: $0.final) }
    }
  }

  public enum Alarm: Error, Sendable, Hashable {
    case keyHistoryInvalid(entryID: Int64)
    case rosterMismatch(writerID: String)
  }

  public static func verify(entries: [Entry], authorityPublicKey: Data, previous: Roster = .empty) throws(Alarm)
    -> Roster
  {
    var roster = previous.writers
    var last = previous.lastEntryID
    for e in entries {
      guard last.map({ e.id > $0 }) ?? true, check(e, &roster, authorityPublicKey: authorityPublicKey) else {
        throw .keyHistoryInvalid(entryID: e.id)
      }
      last = e.id
    }
    return Roster(writers: roster, lastEntryID: last)
  }

  static func check(_ e: Entry, _ roster: inout [WriterID: Writer], authorityPublicKey: Data) -> Bool {
    guard utf8Equal(e.alg, "ed25519"), e.publicKey.count == Ed25519.publicKeyByteCount, e.nonce.count == 32,
      e.signature.count == Ed25519.signatureByteCount, let w = WriterID(e.writerID)
    else { return false }
    switch e.event {
    case "registered":
      guard utf8Equal(e.authorizedBy, "authority"), let dak = e.dakPublicKey, dak.count == DAK.publicKeyByteCount,
        dak.first == 0x04, roster[w] == nil,
        let message = try? SigningMessage.registration(
          nonce: e.nonce, writerID: w, dwkPublicKey: e.publicKey, dakPublicKey: dak),
        Ed25519.verify(publicKey: authorityPublicKey, signature: e.signature, message: message)
      else { return false }
      roster[w] = Writer(dwkPublicKey: e.publicKey, dakPublicKey: dak, final: nil)
      return true
    case "revoked":
      guard utf8Equal(e.authorizedBy, "device"), let a = e.authorizerWriterID.flatMap(WriterID.init),
        let signer = roster[a], signer.isLive, let target = roster[w], target.isLive,
        let counter = e.finalCounter, counter >= 0, let head = e.finalHead.flatMap(Hash32.init),
        let message = try? SigningMessage.revocation(nonce: e.nonce, writerID: w, finalCounter: counter, finalHead: head),
        Ed25519.verify(publicKey: signer.dwkPublicKey, signature: e.signature, message: message)
      else { return false }
      roster[w] = Writer(
        dwkPublicKey: target.dwkPublicKey, dakPublicKey: target.dakPublicKey, final: Chain.Head(counter: counter, hash: head))
      return true
    default:
      return false
    }
  }

  public struct ServerWriter: Sendable, Hashable {
    public let writerID: String
    public let publicKey: Data
    public let dakPublicKey: Data?
    public let revoked: Bool

    public init(writerID: String, publicKey: Data, dakPublicKey: Data?, revoked: Bool) {
      self.writerID = writerID
      self.publicKey = publicKey
      self.dakPublicKey = dakPublicKey
      self.revoked = revoked
    }
  }

  public static func compare(writers: [ServerWriter], roster: Roster) throws(Alarm) {
    for s in writers {
      guard let w = WriterID(s.writerID), let r = roster.writers[w], r.dwkPublicKey == s.publicKey,
        s.dakPublicKey == r.dakPublicKey, s.revoked == !r.isLive
      else { throw .rosterMismatch(writerID: s.writerID) }
    }
  }
}
