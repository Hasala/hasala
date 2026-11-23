import CorePrimitives
import CoreWire
import Foundation
import GRDB

public struct FoldSnapshotRecord: Sendable, Hashable {
  public static let currentVersion = 1
  public static let byteBudget = 6_000_000

  public var version: Int
  public var foldPrint: String
  public var cursorHot: Int64
  public var boundTip: Data
  public var digest: Data
  public var payload: Data
  public var savedAt: Int64

  public init(
    version: Int = FoldSnapshotRecord.currentVersion, foldPrint: String, cursorHot: Int64, boundTip: Data, digest: Data,
    payload: Data, savedAt: Int64
  ) {
    self.version = version
    self.foldPrint = foldPrint
    self.cursorHot = cursorHot
    self.boundTip = boundTip
    self.digest = digest
    self.payload = payload
    self.savedAt = savedAt
  }
}

public enum FoldSnapshotChange: Sendable, Hashable {
  case keep
  case save(foldPrint: String, payload: Data)
  case delete
}

public enum FoldSnapshotRejection: String, Error, Sendable, Hashable {
  case absent
  case version
  case foldPrint = "fold_print"
  case logDiverged = "log_diverged"
  case corrupt
  case undecodable
  case cursorDisagreement = "cursor_disagreement"
}

extension LedgerStore {
  public static func boundTip(seq: Int64, writerID: WriterID, counter: Int64, blobHash: Hash32, prevHash: Hash32) -> Data {
    var b = Data()
    b.append(contentsOf: Array(String(seq).utf8))
    b.append(0)
    b.append(contentsOf: Array("hot".utf8))
    b.append(0)
    b.append(contentsOf: Array(writerID.string.utf8))
    b.append(0)
    b.append(contentsOf: Array(String(counter).utf8))
    b.append(0)
    b.append(blobHash.bytes)
    b.append(prevHash.bytes)
    return sha256(b)
  }

  public func boundTip(at seq: Int64) throws(StoreError) -> Data? {
    let row = try read { db in try Self.tipRow(seq, db) }
    guard let row else { return nil }
    guard let tip = Self.boundTip(seq: seq, row: row) else { throw .corrupt("wire_rows") }
    return tip
  }

  private static func tipRow(_ seq: Int64, _ db: Database) throws -> Row? {
    try Row.fetchOne(
      db, sql: "SELECT writer_id, writer_counter, blob_hash, prev_hash FROM wire_rows WHERE seq = ?", arguments: [seq])
  }

  private static func boundTip(seq: Int64, row: Row) -> Data? {
    guard let w = WriterID(row["writer_id"] as String), let bh = Hash32(row["blob_hash"] as Data),
      let ph = Hash32(row["prev_hash"] as Data)
    else { return nil }
    return boundTip(seq: seq, writerID: w, counter: row["writer_counter"], blobHash: bh, prevHash: ph)
  }

  public func foldSnapshot() throws(StoreError) -> FoldSnapshotRecord? {
    let row = try read { db in try Row.fetchOne(db, sql: "SELECT * FROM fold_snapshot WHERE id = 1") }
    guard let row else { return nil }
    return FoldSnapshotRecord(
      version: row["version"], foldPrint: row["fold_print"], cursorHot: row["cursor_hot"], boundTip: row["bound_tip"],
      digest: row["digest"], payload: row["payload"], savedAt: row["saved_at"])
  }

  public func loadFoldSnapshot<Decoded>(
    foldPrint: String, at now: Int64, decode: (FoldSnapshotRecord) -> Decoded?
  ) throws(StoreError) -> Result<(record: FoldSnapshotRecord, decoded: Decoded), FoldSnapshotRejection>? {
    let cursor = try syncState().cursorHot
    guard let r = try foldSnapshot() else {
      guard cursor > 0 else { return nil }
      try recordFoldEvent(kind: "snapshot_rejected", detail: FoldSnapshotRejection.absent.rawValue, at: now)
      return .failure(.absent)
    }
    var rejection: FoldSnapshotRejection?
    var decoded: Decoded?
    if r.version != FoldSnapshotRecord.currentVersion {
      rejection = .version
    } else if r.foldPrint != foldPrint {
      rejection = .foldPrint
    } else if try boundTip(at: r.cursorHot) != r.boundTip {
      rejection = .logDiverged
    } else if sha256(r.payload) != r.digest {
      rejection = .corrupt
    } else if let d = decode(r) {
      decoded = d
      if r.cursorHot != cursor { rejection = .cursorDisagreement }
    } else {
      rejection = .undecodable
    }
    if let rejection {
      try rejectFoldSnapshot(rejection, at: now)
      return .failure(rejection)
    }
    guard let decoded else { return .failure(.undecodable) }
    return .success((r, decoded))
  }

  public func loadFoldSnapshot(foldPrint: String, at now: Int64) throws(StoreError) -> Result<
    FoldSnapshotRecord, FoldSnapshotRejection
  >? {
    try loadFoldSnapshot(foldPrint: foldPrint, at: now, decode: { _ in true }).map { r in r.map { $0.record } }
  }

  public func rejectFoldSnapshot(_ why: FoldSnapshotRejection, at now: Int64) throws(StoreError) {
    try write { db in try db.execute(sql: "DELETE FROM fold_snapshot") }
    try recordFoldEvent(kind: "snapshot_rejected", detail: why.rawValue, at: now)
  }

  @discardableResult
  public func saveFoldSnapshot(foldPrint: String, payload: Data, at now: Int64) throws(StoreError) -> Bool {
    try write { db in
      try Self.applySnapshot(.save(foldPrint: foldPrint, payload: payload), cursor: nil, tip: nil, at: now, db)
    }
  }

  @discardableResult
  static func applySnapshot(_ change: FoldSnapshotChange, cursor: Int64?, tip: Data?, at now: Int64, _ db: Database)
    throws -> Bool
  {
    switch change {
    case .keep:
      return false
    case .delete:
      try db.execute(sql: "DELETE FROM fold_snapshot")
      return false
    case .save(let print, let payload):
      guard payload.count <= FoldSnapshotRecord.byteBudget else {
        try db.execute(sql: "DELETE FROM fold_snapshot")
        try db.execute(
          sql: "INSERT INTO fold_events (at, kind, detail) VALUES (?, 'snapshot_skipped', 'over_budget')", arguments: [now])
        try pruneFoldEvents(db)
        return false
      }
      let c = try cursor ?? Int64.fetchOne(db, sql: "SELECT cursor_hot FROM sync_state WHERE id = 1") ?? 0
      var boundTip = tip
      if boundTip == nil, c > 0, let row = try tipRow(c, db) {
        boundTip = Self.boundTip(seq: c, row: row)
      }
      guard let boundTip else {
        try db.execute(sql: "DELETE FROM fold_snapshot")
        return false
      }
      try db.execute(
        sql: """
          INSERT INTO fold_snapshot (id, version, fold_print, cursor_hot, bound_tip, digest, payload, bytes, saved_at)
          VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET version = excluded.version, fold_print = excluded.fold_print,
            cursor_hot = excluded.cursor_hot, bound_tip = excluded.bound_tip, digest = excluded.digest,
            payload = excluded.payload, bytes = excluded.bytes, saved_at = excluded.saved_at
          """,
        arguments: [
          FoldSnapshotRecord.currentVersion, print, c, boundTip, sha256(payload), payload, payload.count, now,
        ])
      return true
    }
  }
}
