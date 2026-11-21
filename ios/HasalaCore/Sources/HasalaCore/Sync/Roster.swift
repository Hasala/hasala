import CoreAuth
import CoreCrypto
import CorePrimitives
import CoreStore
import CoreWire
import Foundation

public struct PinnedRoster: Codable, Sendable, Hashable {
  public struct Writer: Codable, Sendable, Hashable {
    public let dwk: String
    public let dak: String
    public let final_counter: Int64?
    public let final_head: String?

    public var isLive: Bool { final_counter == nil && final_head == nil }

    var final: Chain.Head? {
      guard let c = final_counter, let h = final_head.flatMap({ try? Base64.decode($0) }).flatMap(Hash32.init) else {
        return nil
      }
      return Chain.Head(counter: c, hash: h)
    }
  }

  public let authority_pubkey: String
  public let last_entry_id: Int64?
  public let writers: [String: Writer]

  public init(authorityPublicKey: Data, roster: KeyHistoryVerifier.Roster) {
    authority_pubkey = Base64.encode(authorityPublicKey)
    last_entry_id = roster.lastEntryID
    var w: [String: Writer] = [:]
    for (id, r) in roster.writers {
      w[id.string] = Writer(
        dwk: Base64.encode(r.dwkPublicKey), dak: Base64.encode(r.dakPublicKey), final_counter: r.final?.counter,
        final_head: r.final.map { Base64.encode($0.hash.bytes) })
    }
    writers = w
  }

  public var authorityPublicKey: Data? { try? Base64.decode(authority_pubkey) }

  public func forReader() -> [WriterID: HeadCheck.RosterWriter] {
    var out: [WriterID: HeadCheck.RosterWriter] = [:]
    for (id, w) in writers {
      guard let wid = WriterID(id), let dwk = try? Base64.decode(w.dwk), w.isLive || w.final != nil else { continue }
      out[wid] = HeadCheck.RosterWriter(dwkPublicKey: dwk, revokedAt: w.final)
    }
    return out
  }

  public func liveWriters() -> [WriterID] {
    writers.compactMap { $0.value.isLive ? WriterID($0.key) : nil }
  }

  public func shortOfFinal(heads: [WriterID: Chain.Head]) -> [(writer: WriterID, final: Chain.Head)] {
    writers.compactMap { id, w in
      guard let writer = WriterID(id), let final = w.final, (heads[writer] ?? .genesis).counter < final.counter else {
        return nil
      }
      return (writer, final)
    }
  }

  public func encoded() -> Data {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys]
    return (try? e.encode(self)) ?? Data()
  }

  public func extends(_ pinned: PinnedRoster) -> Bool {
    guard authority_pubkey == pinned.authority_pubkey else { return false }
    if let old = pinned.last_entry_id {
      guard let new = last_entry_id, new >= old else { return false }
    }
    for (id, old) in pinned.writers {
      guard let new = writers[id], new.dwk == old.dwk, new.dak == old.dak else { return false }
      if !old.isLive {
        guard new.final_counter == old.final_counter, new.final_head == old.final_head else { return false }
      }
    }
    return true
  }

  public static func decode(_ d: Data?) -> PinnedRoster? {
    guard let d else { return nil }
    return try? JSONDecoder().decode(PinnedRoster.self, from: d)
  }
}

public enum RosterService {
  static func entries(_ r: KeyHistoryResponse) throws(KeyHistoryVerifier.Alarm) -> [KeyHistoryVerifier.Entry] {
    try r.entries.map { e throws(KeyHistoryVerifier.Alarm) in
      func bytes(_ s: String) throws(KeyHistoryVerifier.Alarm) -> Data {
        guard let d = try? Base64.decode(s) else { throw .keyHistoryInvalid(entryID: e.id.value) }
        return d
      }
      return KeyHistoryVerifier.Entry(
        id: e.id.value, writerID: e.writer_id, alg: e.alg, publicKey: try bytes(e.pubkey),
        dakPublicKey: try e.dak_pubkey.map(bytes), event: e.event, authorizedBy: e.authorized_by,
        authorizerWriterID: e.authorizer_writer_id, finalCounter: e.final_counter?.value,
        finalHead: try e.final_head.map(bytes), nonce: try bytes(e.nonce), signature: try bytes(e.signature))
    }
  }

  static func serverWriters(_ r: WritersResponse) throws(KeyHistoryVerifier.Alarm) -> [KeyHistoryVerifier.ServerWriter] {
    try r.writers.map { w throws(KeyHistoryVerifier.Alarm) in
      guard let pub = try? Base64.decode(w.pubkey) else { throw .rosterMismatch(writerID: w.writer_id) }
      let dak = w.dak_pubkey.flatMap { try? Base64.decode($0) }
      return KeyHistoryVerifier.ServerWriter(
        writerID: w.writer_id, publicKey: pub, dakPublicKey: dak, revoked: w.revoked_at != nil)
    }
  }

  public static func refetch(client: AuthClient, bearer: String, pinned: PinnedRoster) async throws(SyncStop)
    -> PinnedRoster
  {
    guard let aak = pinned.authorityPublicKey else { throw .halted(.rosterInvalid) }
    let fresh = try await fetch(client: client, bearer: bearer, authorityPublicKey: aak)
    guard fresh.extends(pinned) else { throw .halted(.rosterInvalid) }
    return fresh
  }

  public static func fetch(client: AuthClient, bearer: String, authorityPublicKey: Data) async throws(SyncStop)
    -> PinnedRoster
  {
    let history: KeyHistoryResponse
    let writers: WritersResponse
    do {
      history = try await client.keyHistory(bearer: bearer)
      writers = try await client.writers(bearer: bearer)
    } catch {
      throw SyncStop.read(error)
    }
    do {
      let roster = try KeyHistoryVerifier.verify(
        entries: try entries(history), authorityPublicKey: authorityPublicKey)
      try KeyHistoryVerifier.compare(writers: try serverWriters(writers), roster: roster)
      return PinnedRoster(authorityPublicKey: authorityPublicKey, roster: roster)
    } catch {
      throw .halted(.rosterInvalid)
    }
  }
}
