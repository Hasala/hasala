import CoreJSON
import CorePrimitives
import CoreTime
import Foundation
import HasalaText

public enum FrameV1Reader {
  public static let version: UInt8 = 1

  public struct Envelope: Sendable, Hashable {
    public let userID: String
    public let stream: String
    public let writerID: String
    public let counter: Int64
    public init(userID: String, stream: String, writerID: String, counter: Int64) {
      self.userID = userID
      self.stream = stream
      self.writerID = writerID
      self.counter = counter
    }

    public func aad() throws(EnvelopeError) -> Data {
      let id = ASCII.lowercased(userID)
      guard UserID(id) != nil else {
        throw .invalid("user_id \(showValue(.string(userID))) is not a canonical UUID")
      }
      guard stream == "hot" || stream == "cold" else {
        throw .invalid("stream is \(showValue(.string(stream))), want \"hot\" or \"cold\"")
      }
      guard !writerID.isEmpty else { throw .invalid("writer_id is empty") }
      guard !writerID.utf8.contains(0x7c) else { throw .invalid("writer_id may not contain \"|\"") }
      guard counter >= 1 else { throw .invalid("writer_counter is \(counter), and counters are 1-based") }
      let bytes = Data("\(id)|\(stream)|\(writerID)|\(counter)".utf8)
      let n = 1 + 2 + bytes.count + 12 + 4 + 16
      guard n <= FrameV3.buckets[0] else { throw .invalid("framing overhead \(n) does not fit the smallest bucket") }
      return bytes
    }
  }

  public struct Parsed: Sendable, Hashable {
    public let aad: Data
    public let payload: Data
  }

  public static func parse(_ bytes: some DataProtocol) throws(WireDecodeError) -> Parsed {
    let b = [UInt8](bytes)
    guard FrameV3.isBucket(b.count) else { throw .setAside("\(b.count) bytes is not a size bucket") }
    guard b[0] == version else { throw .setAside("unsupported envelope version \(b[0])") }
    let aadLength = Int(b[1]) << 8 | Int(b[2])
    let start = 3 + aadLength + 12
    let end = b.count - 16
    guard end >= start + 4 else { throw .setAside("aadLen \(aadLength) leaves no room for a payload") }
    let m = Int(b[start]) << 24 | Int(b[start + 1]) << 16 | Int(b[start + 2]) << 8 | Int(b[start + 3])
    guard m <= end - start - 4 else { throw .setAside("payload length \(m) runs past the sealed region") }
    return Parsed(aad: Data(b[3..<(3 + aadLength)]), payload: Data(b[(start + 4)..<(start + 4 + m)]))
  }

  public static func open(_ bytes: some DataProtocol, envelope: Envelope) throws(WireDecodeError) -> Data {
    let expected: Data
    do { expected = try envelope.aad() } catch { throw .setAside(error.message) }
    let parsed = try parse(bytes)
    guard constantTimeEquals(parsed.aad, expected) else {
      throw .setAside("associated data mismatch: sealed at a different position")
    }
    do {
      return try Gzip.decompress(parsed.payload, maxOutputBytes: FrameV3.maxPlaintext)
    } catch .overCap {
      throw .setAside("decompressed payload exceeds \(FrameV3.maxPlaintext) bytes")
    } catch {
      throw .setAside("gzip: \(error)")
    }
  }

  public struct RawBody: Sendable, Hashable {
    public let ingestID: String
    public let receivedAt: String
    public let raw: Data
  }

  public static func decodeRawBody(_ bytes: some Collection<UInt8>) throws(WireDecodeError) -> RawBody {
    let doc = try OpCodec.parseBody(bytes, what: "raw body")
    try OpCodec.requireIntegerLiteral(doc, "v", what: "raw body")
    _ = try OpCodec.readVersion(doc, what: "raw body")
    guard doc["kind"]?.stringValue == BlobKind.rawBody.rawValue else {
      throw .setAside("blob kind is \(showValue(doc["kind"])), not \"raw_body\"")
    }
    guard let ingest = doc["ingest_id"]?.stringValue, ASCII.isLowerHex(ingest, count: 64) else {
      throw .setAside("raw body has no usable ingest_id: \(showValue(doc["ingest_id"]))")
    }
    guard let received = doc["received_at"]?.stringValue else {
      throw .setAside("raw body received_at is \(showValue(doc["received_at"]))")
    }
    do { _ = try canonicalTime(received) } catch { throw .setAside(OpCodec.timeMessage(received, error)) }
    guard let b64 = doc["raw_base64"]?.stringValue, let raw = try? Base64.decode(b64) else {
      throw .setAside("raw_base64 is not standard base64")
    }
    return RawBody(ingestID: ingest, receivedAt: received, raw: raw)
  }
}

extension EnvelopeError {
  public var message: String {
    switch self {
    case .invalid(let m): m
    }
  }
}
