import CoreSync
import CoreTestSupport
import Foundation
import Synchronization
import Testing

@testable import CoreOutbox

func op(_ id: String, payload: JSONValue = .object(JSONObject([("currency", .string("AED"))]))) -> Op {
  Op(v: 4, type: .homeCurrencySet, opID: id, authoredAt: "2026-10-11T08:00:00Z", payload: payload)
}

final class Counter: Sendable {
  let n = Mutex(0)
  func bump() { n.withLock { $0 += 1 } }
  var value: Int { n.withLock { $0 } }
}

final class Signal: Sendable {
  private let stream: AsyncStream<Void>
  private let continuation: AsyncStream<Void>.Continuation

  init() { (stream, continuation) = AsyncStream.makeStream() }

  func send() { continuation.yield() }

  func wait() async {
    for await _ in stream { return }
  }
}

final class ManualSleeper: Sendable {
  struct State {
    var nextID = 0
    var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
    var cancelled: Set<Int> = []
    var asked: [Duration] = []
  }

  let state = Mutex(State())
  let began = Signal()
  let cancelled = Signal()

  var asked: [Duration] { state.withLock { $0.asked } }
  var waitingCount: Int { state.withLock { $0.waiting.count } }

  func sleep(_ duration: Duration) async {
    let id = state.withLock {
      $0.nextID += 1
      $0.asked.append(duration)
      return $0.nextID
    }
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let done = state.withLock {
          if $0.cancelled.contains(id) { return true }
          $0.waiting[id] = continuation
          return false
        }
        if done { continuation.resume() }
        began.send()
      }
    } onCancel: {
      let continuation = state.withLock {
        $0.cancelled.insert(id)
        return $0.waiting.removeValue(forKey: id)
      }
      continuation?.resume()
      cancelled.send()
    }
  }

  func advance() {
    let due = state.withLock {
      let all = Array($0.waiting.values)
      $0.waiting.removeAll()
      return all
    }
    for continuation in due { continuation.resume() }
  }
}

@Suite("CoreOutbox")
struct OutboxTests {
  @Test("enqueue stores each op's canonical JSON in one transaction")
  func enqueue() async throws {
    let store = try LedgerStore.inMemory()
    let box = Outbox(store: store, clock: FakeClock(), onAuthored: {})
    try await box.enqueue([op("a"), op("b")])
    let rows = try store.pendingOps()
    #expect(rows.map(\.opID) == ["a", "b"])
    #expect(
      String(decoding: rows[0].opJSON, as: UTF8.self)
        == #"{"v":4,"type":"home_currency_set","op_id":"a","authored_at":"2026-10-11T08:00:00.000Z","parent_version":null,"payload":{"currency":"AED"}}"#
    )
  }

  @Test("an invalid op and an op over 8 KiB are refused and nothing is written")
  func refusals() async throws {
    let store = try LedgerStore.inMemory()
    let box = Outbox(store: store, clock: FakeClock(), onAuthored: {})
    let bad = Op(v: 4, type: .txnEdited, opID: "x", authoredAt: "2026-10-11T08:00:00Z", payload: .object(JSONObject()))
    await #expect(throws: OutboxError.self) { try await box.enqueue([op("ok"), bad]) }
    let huge = op("big", payload: .object(JSONObject([("currency", .string(String(repeating: "A", count: 9000)))])))
    await #expect(throws: OutboxError.opTooLarge(opID: "big")) { try await box.enqueue([huge]) }
    #expect(try store.pendingCount() == 0)
  }

  @Test("an edit made while the authored run is under way leaves that run alone and asks for its own")
  func enqueueDuringFiring() async throws {
    let store = try LedgerStore.inMemory()
    let started = Counter()
    let finished = Counter()
    let cancelled = Counter()
    let release = Mutex(false)
    let box = Outbox(
      store: store, clock: FakeClock(), debounce: .milliseconds(20),
      onAuthored: {
        started.bump()
        while !release.withLock({ $0 }) { await Task.yield() }
        if Task.isCancelled { cancelled.bump() }
        finished.bump()
      })
    try await box.enqueue([op("a")])
    for _ in 0..<200 where started.value == 0 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(started.value == 1)
    try await box.enqueue([op("b")])
    release.withLock { $0 = true }
    for _ in 0..<200 where finished.value < 2 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(finished.value == 2)
    #expect(cancelled.value == 0)
  }

  @Test("flushing the trigger while the authored run is under way leaves that run alone")
  func flushDuringFiring() async throws {
    let store = try LedgerStore.inMemory()
    let started = Counter()
    let finished = Counter()
    let cancelled = Counter()
    let release = Mutex(false)
    let box = Outbox(
      store: store, clock: FakeClock(), debounce: .milliseconds(20),
      onAuthored: {
        started.bump()
        while !release.withLock({ $0 }) { await Task.yield() }
        if Task.isCancelled { cancelled.bump() }
        finished.bump()
      })
    try await box.enqueue([op("a")])
    for _ in 0..<200 where started.value == 0 { try await Task.sleep(for: .milliseconds(10)) }
    async let flushed: Void = box.flushTriggerNow()
    for _ in 0..<200 where started.value < 2 { try await Task.sleep(for: .milliseconds(10)) }
    release.withLock { $0 = true }
    await flushed
    for _ in 0..<200 where finished.value < 2 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(finished.value == 2)
    #expect(cancelled.value == 0)
  }

  @Test("flushing inside the window fires once: the replaced wait never fires", .timeLimit(.minutes(1)))
  func flushInsideWindowFiresOnce() async throws {
    let store = try LedgerStore.inMemory()
    let fired = Counter()
    let sleeper = ManualSleeper()
    let box = Outbox(
      store: store, clock: FakeClock(), debounce: .milliseconds(300), sleep: sleeper.sleep,
      onAuthored: { fired.bump() })
    try await box.enqueue([op("a")])
    await box.flushTriggerNow()
    #expect(fired.value == 1)
    await sleeper.began.wait()
    await sleeper.cancelled.wait()
    _ = await box.pendingCount()
    sleeper.advance()
    _ = await box.pendingCount()
    #expect(fired.value == 1)
    #expect(sleeper.asked == [.milliseconds(300)])
  }

  @Test("a sender's pending import is written with its ops, or not at all")
  func enqueueWithImports() async throws {
    let store = try LedgerStore.inMemory()
    let tables = MailboxTableStore(writer: store.db)
    let box = Outbox(store: store, clock: FakeClock(), onAuthored: {})
    try await box.enqueue([op("a")], importing: [(domain: "emiratesnbd.com", sinceMs: 5_000)])
    #expect(try store.pendingOps().map(\.opID) == ["a"])
    #expect(try tables.pendingImports().map(\.domain) == ["emiratesnbd.com"])
    await #expect(throws: OutboxError.self) {
      try await box.enqueue([op("b"), op("a")], importing: [(domain: "dib.ae", sinceMs: 5_000)])
    }
    #expect(try store.pendingOps().map(\.opID) == ["a"])
    #expect(try tables.pendingImports().map(\.domain) == ["emiratesnbd.com"])
    try await box.enqueue([op("c")], importing: [(domain: "emiratesnbd.com", sinceMs: 9_000)])
    #expect(try tables.pendingImports().map(\.sinceMs) == [5_000])
  }

  @Test("several enqueues inside the debounce window fire one authored trigger", .timeLimit(.minutes(1)))
  func debounce() async throws {
    let store = try LedgerStore.inMemory()
    let fired = Counter()
    let done = Signal()
    let sleeper = ManualSleeper()
    let box = Outbox(
      store: store, clock: FakeClock(), debounce: .milliseconds(400), sleep: sleeper.sleep,
      onAuthored: {
        fired.bump()
        done.send()
      })
    try await box.enqueue([op("a")])
    try await box.enqueue([op("b")])
    await sleeper.began.wait()
    await sleeper.began.wait()
    await sleeper.cancelled.wait()
    _ = await box.pendingCount()
    #expect(fired.value == 0)
    #expect(sleeper.waitingCount == 1)
    sleeper.advance()
    await done.wait()
    _ = await box.pendingCount()
    #expect(fired.value == 1)
    #expect(sleeper.asked == [.milliseconds(400), .milliseconds(400)])
  }
}
