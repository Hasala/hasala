import CoreSync
import Foundation

public enum OutboxError: Error, Sendable, Hashable {
  case invalidOp(String)
  case opTooLarge(opID: String)
  case store(StoreError)
}

public actor Outbox {
  public static let maxOpBytes = 8 * 1024
  public static let debounce: Duration = .milliseconds(1500)

  let store: LedgerStore
  let clock: any CoreTime.Clock
  let onAuthored: @Sendable () async -> Void
  let debounceWindow: Duration
  let sleep: @Sendable (Duration) async -> Void
  private var pendingTrigger: Task<Void, Never>?

  public init(
    store: LedgerStore, clock: any CoreTime.Clock, debounce: Duration = Outbox.debounce,
    sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
    onAuthored: @escaping @Sendable () async -> Void
  ) {
    self.store = store
    self.clock = clock
    self.debounceWindow = debounce
    self.sleep = sleep
    self.onAuthored = onAuthored
  }

  public var latch: OutboxLatch? { (try? store.syncState().latch) ?? nil }

  public func pendingCount() -> Int { (try? store.pendingCount()) ?? 0 }

  public func enqueue(_ ops: [Op], importing imports: [(domain: String, sinceMs: Int64)] = []) throws(OutboxError) {
    guard !ops.isEmpty else { return }
    let now = clock.nowMs()
    var rows: [PendingOp] = []
    for op in ops {
      let json = try Self.canonicalJSON(op)
      guard json.count <= Self.maxOpBytes else { throw .opTooLarge(opID: op.opID) }
      rows.append(
        PendingOp(
          opID: op.opID, opJSON: json, opType: op.type.rawValue, entityKind: op.entity?.kind, entityID: op.entity?.id,
          enqueuedAt: now))
    }
    do { try store.enqueue(rows, imports: imports) } catch { throw .store(error) }
    scheduleTrigger()
  }

  public static func canonicalJSON(_ op: Op) throws(OutboxError) -> Data {
    let blob: [UInt8]
    do { blob = try OpCodec.encodeBlobOps([op]) } catch {
      switch error {
      case .invalid(let m), .unknownNewerVersion(let m): throw .invalidOp(m)
      }
    }
    guard let doc = try? JSONParser.parse(blob), let first = doc["ops"]?.arrayValue?.first else {
      throw .invalidOp("encode")
    }
    return Data(JSONWriter().bytes(first))
  }

  private func scheduleTrigger() {
    pendingTrigger?.cancel()
    let run = onAuthored
    let wait = debounceWindow
    let sleep = sleep
    pendingTrigger = Task {
      await sleep(wait)
      guard !Task.isCancelled else { return }
      pendingTrigger = nil
      await run()
    }
  }

  public func flushTriggerNow() async {
    pendingTrigger?.cancel()
    pendingTrigger = nil
    await onAuthored()
  }
}
