import CorePrimitives
import CoreWire
import Foundation

public enum PageReader {
  public struct Row: Sendable, Hashable {
    public let stream: String
    public let writerID: String
    public let counter: String
    public let sizeBucket: Int
    public let prevHash: Data
    public let blobHash: Data
    public let headSig: Data?
    public let blob: Data

    public init(
      stream: String, writerID: String, counter: String, sizeBucket: Int, prevHash: Data, blobHash: Data, headSig: Data?,
      blob: Data
    ) {
      self.stream = stream
      self.writerID = writerID
      self.counter = counter
      self.sizeBucket = sizeBucket
      self.prevHash = prevHash
      self.blobHash = blobHash
      self.headSig = headSig
      self.blob = blob
    }
  }

  public struct State: Sendable {
    public let userID: UserID
    public let opener: Opener
    public let serverEpoch: UInt32?
    public let pinnedHeads: [WriterID: Chain.Head]
    public let roster: [WriterID: HeadCheck.RosterWriter]
    public let rosterRefreshed: Bool
    public let newerVersionUnshipped: Bool
    public let own: (writer: WriterID, authoredHead: Int64)?

    public init(
      userID: UserID, opener: Opener, serverEpoch: UInt32?, pinnedHeads: [WriterID: Chain.Head],
      roster: [WriterID: HeadCheck.RosterWriter], rosterRefreshed: Bool = false,
      own: (writer: WriterID, authoredHead: Int64)?, newerVersionUnshipped: Bool = false
    ) {
      self.userID = userID
      self.opener = opener
      self.serverEpoch = serverEpoch
      self.pinnedHeads = pinnedHeads
      self.roster = roster
      self.rosterRefreshed = rosterRefreshed
      self.own = own
      self.newerVersionUnshipped = newerVersionUnshipped
    }
  }

  public enum RowOutcome: Sendable, Hashable {
    case opened(plaintext: Data, ops: [Op])
    case setAside(SetAsideReason, alarm: Bool)
  }

  public enum Stop: Sendable, Hashable {
    case hardStop(ReaderHardStop)
    case needsUnlock(epoch: UInt32)
    case refreshEpoch(UInt32)
    case refreshRoster
    case budgetReached
  }

  public enum RowDecision: Sendable, Hashable {
    case row(RowOutcome)
    case stop(Stop)
  }

  public struct Result: Sendable, Hashable {
    public let rows: [RowOutcome]
    public let stop: Stop?
    public let stopRow: Int?
  }

  public static let maxPagePlaintext = 8 * 1024 * 1024

  public static func read(_ page: [Row], state: State, plaintextBudget: Int = maxPagePlaintext) -> Result {
    func stopped(_ i: Int, _ s: Stop, _ rows: [RowOutcome] = []) -> Result { Result(rows: rows, stop: s, stopRow: i) }

    var checked: [RowShape.Checked] = []
    for (i, r) in page.enumerated() {
      guard
        let c = RowShape.check(
          stream: r.stream, writerID: r.writerID, counter: r.counter, sizeBucket: r.sizeBucket, blob: r.blob,
          prevHash: r.prevHash, blobHash: r.blobHash)
      else { return stopped(i, .hardStop(.tampered(.rowShape))) }
      if state.roster[c.writerID] == nil {
        return stopped(i, state.rosterRefreshed ? .hardStop(.tampered(.unknownWriter)) : .refreshRoster)
      }
      if let own = state.own, c.writerID == own.writer, c.counter > own.authoredHead {
        return stopped(i, .hardStop(.tampered(.ownChainConflict)))
      }
      checked.append(c)
    }
    var heads = state.pinnedHeads
    for (i, c) in checked.enumerated() {
      let head = heads[c.writerID] ?? .genesis
      guard c.counter == head.counter + 1, c.prevHash == head.hash,
        Chain.hash(prev: c.prevHash, frame: c.blob) == c.blobHash
      else { return stopped(i, .hardStop(.tampered(.chainBreak))) }
      heads[c.writerID] = Chain.Head(counter: c.counter, hash: c.blobHash)
    }
    let headRows = zip(checked, page).map {
      HeadCheck.Row(writerID: $0.writerID, counter: $0.counter, blobHash: $0.blobHash, headSig: $1.headSig)
    }
    if let f = HeadCheck.firstFailure(userID: state.userID, rows: headRows, roster: state.roster) {
      return stopped(f.index, .hardStop(.tampered(f.reason)))
    }
    var out: [RowOutcome] = []
    var held = 0
    for (i, c) in checked.enumerated() {
      let setsAsideNewer = state.newerVersionUnshipped || state.roster[c.writerID]?.revokedAt != nil
      let envelope: Envelope
      do {
        envelope = try Envelope(userID: state.userID, writerID: c.writerID, counter: c.counter)
      } catch {
        return stopped(i, .hardStop(.tampered(.rowShape)), out)
      }
      let opened = state.opener.open(c.blob, envelope: envelope, prevHash: c.prevHash, serverEpoch: state.serverEpoch)
      switch decide(opened, setsAsideNewer: setsAsideNewer) {
      case .stop(let s): return stopped(i, s, out)
      case .row(let outcome): out.append(outcome)
      }
      if case .opened(let plaintext) = opened {
        held += plaintext.count
        if held >= plaintextBudget, i < checked.count - 1 { return stopped(i, .budgetReached, out) }
      }
    }
    return Result(rows: out, stop: nil, stopRow: nil)
  }

  public static func decide(_ opened: OpenOutcome, setsAsideNewer: Bool) -> RowDecision {
    switch opened {
    case .hardStop(.updateRequired) where setsAsideNewer: return .row(.setAside(.opsUndecodable, alarm: false))
    case .hardStop(let h): return .stop(.hardStop(h))
    case .needsUnlock(let e): return .stop(.needsUnlock(epoch: e))
    case .refreshEpoch(let e): return .stop(.refreshEpoch(e))
    case .setAside(let reason, let alarm): return .row(.setAside(reason, alarm: alarm))
    case .opened(let plaintext):
      switch OpCodec.decodeR10(plaintext) {
      case .ops(let ops): return .row(.opened(plaintext: plaintext, ops: ops))
      case .hardStop(.updateRequired) where setsAsideNewer: return .row(.setAside(.opsUndecodable, alarm: false))
      case .hardStop(let h): return .stop(.hardStop(h))
      case .setAside(let reason, _): return .row(.setAside(reason, alarm: false))
      }
    }
  }
}
