import CorePrimitives
import Foundation
import HasalaText

public enum FrameV3 {
  public static let version: UInt8 = 0x03
  public static let epochSize = 4
  public static let fixedHeaderSize = 7
  public static let nonceSize = 12
  public static let tagSize = 16
  public static let payloadLengthSize = 4

  public static let buckets = [1024, 4096, 16384, 65536, 262_144, 524_288, 1_048_576]
  public static let maxBucket = 1_048_576
  public static let maxPlaintext = 2_097_152
  public static let maxEpoch: UInt32 = 0x7FFF_FFFF

  public static func overhead(aadLength: Int) -> Int { fixedHeaderSize + aadLength + nonceSize + payloadLengthSize + tagSize }

  public static func isBucket(_ n: Int) -> Bool { buckets.contains(n) }

  public static func bucket(for n: Int) -> Int? { buckets.first { n <= $0 } }

  public static func isValidEpoch(_ e: UInt32) -> Bool { e >= 1 && e <= maxEpoch }

  public struct Layout: Sendable, Hashable {
    public let aadLength: Int
    public let frameLength: Int

    public init(aadLength: Int, frameLength: Int) {
      self.aadLength = aadLength
      self.frameLength = frameLength
    }

    public var header: Range<Int> { 0..<(FrameV3.fixedHeaderSize + aadLength) }
    public var aad: Range<Int> { FrameV3.fixedHeaderSize..<(FrameV3.fixedHeaderSize + aadLength) }
    public var nonce: Range<Int> { header.upperBound..<(header.upperBound + FrameV3.nonceSize) }
    public var region: Range<Int> { nonce.upperBound..<(frameLength - FrameV3.tagSize) }
    public var tag: Range<Int> { (frameLength - FrameV3.tagSize)..<frameLength }
    public var regionLength: Int { frameLength - 35 - aadLength }
  }

  public struct Header: Sendable, Hashable {
    public let version: UInt8
    public let epoch: UInt32
    public let aadLength: Int
  }

  public static func parseHeader(_ frame: some DataProtocol) -> Header? {
    guard frame.count >= fixedHeaderSize else { return nil }
    let b = [UInt8](frame.prefix(fixedHeaderSize))
    let epoch = UInt32(b[1]) << 24 | UInt32(b[2]) << 16 | UInt32(b[3]) << 8 | UInt32(b[4])
    return Header(version: b[0], epoch: epoch, aadLength: Int(b[5]) << 8 | Int(b[6]))
  }

  public static func header(epoch: UInt32, aad: some DataProtocol) -> Data {
    var h = Data([version])
    h.append(contentsOf: [UInt8(epoch >> 24), UInt8(epoch >> 16 & 0xff), UInt8(epoch >> 8 & 0xff), UInt8(epoch & 0xff)])
    h.append(contentsOf: [UInt8(aad.count >> 8), UInt8(aad.count & 0xff)])
    h.append(contentsOf: aad)
    return h
  }
}

public enum EnvelopeError: Error, Equatable, Sendable {
  case invalid(String)
}

public struct Envelope: Sendable, Hashable {
  public static let stream = "hot"

  public let userID: UserID
  public let writerID: WriterID
  public let counter: Int64

  public init(userID: UserID, writerID: WriterID, counter: Int64) throws(EnvelopeError) {
    guard counter >= 1 else { throw .invalid("writer_counter is \(counter), and counters are 1-based") }
    self.userID = userID
    self.writerID = writerID
    self.counter = counter
  }

  public var aad: Data {
    Data("\(userID.string)|\(Envelope.stream)|\(writerID.string)|\(counter)".utf8)
  }
}
