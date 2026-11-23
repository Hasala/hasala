import CoreJSON
import CorePrimitives
import Foundation
import HasalaText

public enum Chain {
  public static func hash(prev: Hash32, frame: some DataProtocol) -> Hash32 {
    var buf = Data(capacity: Hash32.byteCount + frame.count)
    buf.append(prev.bytes)
    buf.append(contentsOf: frame)
    return Hash32.of(buf)
  }

  public struct Head: Sendable, Hashable {
    public let counter: Int64
    public let hash: Hash32
    public init(counter: Int64, hash: Hash32) {
      self.counter = counter
      self.hash = hash
    }
    public static let genesis = Head(counter: 0, hash: .zero)
  }

  public struct Row: Sendable, Hashable {
    public let writerID: String
    public let stream: String
    public let counter: Int64
    public let prevHash: Hash32
    public let blobHash: Hash32
    public let blob: Data
    public init(writerID: String, stream: String, counter: Int64, prevHash: Hash32, blobHash: Hash32, blob: Data) {
      self.writerID = writerID
      self.stream = stream
      self.counter = counter
      self.prevHash = prevHash
      self.blobHash = blobHash
      self.blob = blob
    }
  }

  public struct HashRow: Sendable, Hashable {
    public let seq: Int64
    public let writerID: String
    public let counter: Int64
    public let prevHash: Hash32
    public let blobHash: Hash32
    public init(seq: Int64, writerID: String, counter: Int64, prevHash: Hash32, blobHash: Hash32) {
      self.seq = seq
      self.writerID = writerID
      self.counter = counter
      self.prevHash = prevHash
      self.blobHash = blobHash
    }
  }

  public struct Break: Error, Equatable, Sendable {
    public let message: String
  }

  public static func verify(writerID: String, stream: String, rows: [Row], pinned: Head) throws(Break) {
    let key = "\(writerID)|\(stream)"
    var prev = pinned.hash
    var want = pinned.counter + 1
    for (i, r) in rows.enumerated() {
      try requireSameChain(key: key, writer: writerID, stream: stream, index: i, rowWriter: r.writerID, rowStream: r.stream)
      guard r.counter == want else { throw Break(message: "(\(key)) row \(i) has counter \(r.counter), want \(want)") }
      guard r.prevHash == prev else {
        throw Break(message: "(\(key)) counter \(r.counter) links to \(r.prevHash.hex), but the chain is at \(prev.hex)")
      }
      let got = hash(prev: prev, frame: r.blob)
      guard r.blobHash == got else {
        throw Break(
          message: "(\(key)) counter \(r.counter) claims hash \(r.blobHash.hex), but its bytes hash to \(got.hex)")
      }
      prev = got
      want += 1
    }
  }

  public static func headAfter(_ rows: [Row], pinned: Head) -> Head {
    guard let last = rows.last else { return pinned }
    return Head(counter: last.counter, hash: last.blobHash)
  }

  public static func verifyHashList(writerID: String, stream: String, list: [HashRow], pinned: Head) throws(Break)
    -> Head
  {
    let key = "\(writerID)|\(stream)"
    var prev = pinned.hash
    var want = pinned.counter + 1
    var lastSeq: Int64?
    for (i, h) in list.enumerated() {
      try requireSameChain(key: key, writer: writerID, stream: stream, index: i, rowWriter: h.writerID, rowStream: nil)
      guard h.counter == want else {
        throw Break(message: "(\(key)) hash list entry \(i) has counter \(h.counter), want \(want)")
      }
      if let lastSeq, h.seq <= lastSeq {
        throw Break(message: "(\(key)) hash list entry \(i) has seq \(h.seq), which does not follow \(lastSeq)")
      }
      guard h.prevHash == prev else {
        throw Break(message: "(\(key)) hash list entry \(i) links to \(h.prevHash.hex), but the chain is at \(prev.hex)")
      }
      lastSeq = h.seq
      prev = h.blobHash
      want += 1
    }
    return Head(counter: want - 1, hash: prev)
  }

  public static func verifyFetchedRange(pinned: [Int64: Hash32], rows: [Row]) throws(Break) {
    for r in rows {
      guard let want = pinned[r.counter] else {
        throw Break(message: "counter \(r.counter) was never pinned, so its body cannot be verified")
      }
      let got = hash(prev: r.prevHash, frame: r.blob)
      guard got == want else { throw Break(message: "counter \(r.counter) hashes to \(got.hex), but \(want.hex) was pinned") }
    }
  }

  private static func requireSameChain(
    key: String, writer: String, stream: String, index i: Int, rowWriter: String, rowStream: String?
  ) throws(Break) {
    if rowWriter.isEmpty {
      throw Break(message: "row \(i) names no writer, so it cannot be attributed to the chain (\(key))")
    }
    if !utf8Equal(rowWriter, writer) {
      throw Break(message: "row \(i) is from writer \(showValue(.string(rowWriter))), but the chain is (\(key))")
    }
    if let rowStream, !utf8Equal(rowStream, stream) {
      throw Break(message: "row \(i) is on stream \(showValue(.string(rowStream))), but the chain is (\(key))")
    }
  }
}
