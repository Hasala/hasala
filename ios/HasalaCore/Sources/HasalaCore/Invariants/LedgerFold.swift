import CoreCrypto
import CoreReplay
import CoreWire

public enum FoldHalt: Error, Sendable, Equatable {
  case updateRequired
  case order(String)
  case inconsistent([Violation])
}

public struct FoldRow: Sendable {
  public let seq: Int64
  public let writerID: String
  public let counter: Int64
  public let outcome: PageReader.RowOutcome

  public init(seq: Int64, writerID: String, counter: Int64, outcome: PageReader.RowOutcome) {
    self.seq = seq
    self.writerID = writerID
    self.counter = counter
    self.outcome = outcome
  }
}

public enum LedgerFold {
  public static func page(_ rows: [FoldRow], onto state: State) throws(FoldHalt) -> State {
    var s = state
    do {
      for r in rows {
        switch r.outcome {
        case .opened(_, let ops):
          try Replay.foldOps(ops, seq: r.seq, writerID: r.writerID, into: &s)
        case .setAside(let reason, _):
          try Replay.foldSetAside(seq: r.seq, writerID: r.writerID, writerCounter: r.counter, reason: reason.rawValue, into: &s)
        }
      }
    } catch {
      switch error {
      case .newerVersion: throw .updateRequired
      case .order(let m): throw .order(m)
      }
    }
    let hard = Invariants.check(s).filter { $0.severity == .hardStop }
    if !hard.isEmpty { throw .inconsistent(hard) }
    return s
  }
}
