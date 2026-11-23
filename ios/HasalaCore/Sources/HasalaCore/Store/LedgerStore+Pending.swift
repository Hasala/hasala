import Foundation
import GRDB

extension LedgerStore {
  public func hasPendingIngest(_ ingestID: String) throws(StoreError) -> Bool {
    let u = Array(ingestID.utf8)
    guard u.count == 64, u.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }) else { return false }
    let pattern = "%\"ingest_id\":\"\(ingestID)\"%"
    return try read { db in
      try Int.fetchOne(
        db,
        sql: """
          SELECT count(*) FROM pending_ops
           WHERE op_type IN ('txn_ingested', 'txn_superseded') AND CAST(op_json AS TEXT) LIKE ?
          """,
        arguments: [pattern]) ?? 0
    } > 0
  }

  public func latestPendingAuthoredAt() throws(StoreError) -> String? {
    try read { db in
      try String.fetchOne(
        db,
        sql: """
          SELECT max(substr(j, instr(j, '"authored_at":"') + 15, 24))
            FROM (SELECT CAST(op_json AS TEXT) AS j FROM pending_ops) WHERE instr(j, '"authored_at":"') > 0
          """)
    }
  }
}
