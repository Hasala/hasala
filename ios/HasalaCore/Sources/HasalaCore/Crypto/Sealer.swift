import CorePrimitives
import CoreWire
import Foundation

public final class EpochKey: @unchecked Sendable {
  public let epoch: UInt32
  public let key: SecureBytes

  public init(epoch: UInt32, key: some ContiguousBytes) throws(PrimitivesError) {
    guard FrameV3.isValidEpoch(epoch) else {
      throw .invalidLength(what: "key epoch", expected: "1...2147483647", got: Int(epoch))
    }
    try KeyDerivation.requireLength(key, 32, "epoch key")
    self.epoch = epoch
    self.key = SecureBytes(copying: key)
  }

  public static func first(body: KeyBody, userID: UserID) throws(PrimitivesError) -> EpochKey {
    try EpochKey(epoch: 1, key: try body.epochKey1(userID: userID))
  }
}

public enum SealError: Error, Equatable, Sendable {
  case invalidEnvelope(String)
  case tooLarge
  case sealerFault
  case primitive(PrimitivesError)
  case gzip(GzipError)
}

public struct SealedFrame: Sendable, Hashable {
  public let bytes: Data
  public let blobHash: Hash32
  public let epoch: UInt32
  public let counter: Int64
  public let prevHash: Hash32

  fileprivate init(bytes: Data, blobHash: Hash32, epoch: UInt32, counter: Int64, prevHash: Hash32) {
    precondition(LooksSealed.check(bytes) == nil, "SealedFrame built from bytes LooksSealed refuses")
    self.bytes = bytes
    self.blobHash = blobHash
    self.epoch = epoch
    self.counter = counter
    self.prevHash = prevHash
  }
}

public struct Sealer: Sendable {
  public let epoch: UInt32
  public let key: EpochKey

  public init(epoch: UInt32, key: EpochKey) {
    self.epoch = epoch
    self.key = key
  }

  public func seal(plaintextOps: Data, envelope: Envelope, prevHash: Hash32, random: some RandomSource)
    throws(SealError) -> SealedFrame
  {
    guard FrameV3.isValidEpoch(epoch), key.epoch == epoch else {
      throw .invalidEnvelope("the key is for epoch \(key.epoch), the seal is at \(epoch)")
    }
    guard plaintextOps.count <= FrameV3.maxPlaintext else { throw .tooLarge }
    let g: Data
    do { g = try Gzip.compress(plaintextOps) } catch { throw .gzip(error) }
    let aad = envelope.aad
    guard let bucket = FrameV3.bucket(for: FrameV3.overhead(aadLength: aad.count) + g.count) else { throw .tooLarge }
    let header = FrameV3.header(epoch: epoch, aad: aad)
    let regionLength = bucket - 35 - aad.count
    var region = Data(count: regionLength)
    region[0] = UInt8(g.count >> 24 & 0xff)
    region[1] = UInt8(g.count >> 16 & 0xff)
    region[2] = UInt8(g.count >> 8 & 0xff)
    region[3] = UInt8(g.count & 0xff)
    region.replaceSubrange(4..<(4 + g.count), with: g)

    for _ in 0..<2 {
      let nonce: Data
      do { nonce = try random.bytes(FrameV3.nonceSize) } catch { throw .primitive(error) }
      let frame: Data
      do {
        frame = try FrameAEAD.seal(region: region, header: header, prevHash: prevHash, epochKey: key.key, nonce: nonce)
      } catch {
        throw .primitive(error)
      }
      guard frame.count == bucket else { throw .invalidEnvelope("frame is \(frame.count) bytes, bucket \(bucket)") }
      if LooksSealed.check(frame) == nil {
        return SealedFrame(
          bytes: frame, blobHash: Chain.hash(prev: prevHash, frame: frame), epoch: epoch, counter: envelope.counter,
          prevHash: prevHash)
      }
    }
    throw .sealerFault
  }
}

package enum FrameAEAD {
  package static func associatedData(header: some DataProtocol, prevHash: Hash32) -> Data {
    Domain.blob.prefix + Data(header) + prevHash.bytes
  }

  package static func seal(
    region: Data, header: Data, prevHash: Hash32, epochKey: some ContiguousBytes, nonce: Data
  ) throws(PrimitivesError) -> Data {
    guard nonce.count == FrameV3.nonceSize, nonce.contains(where: { $0 != 0 }) else {
      throw .invalidLength(what: "frame nonce", expected: "12 non-zero bytes", got: nonce.count)
    }
    let ad = associatedData(header: header, prevHash: prevHash)
    let kBlob = try KeyDerivation.blobKey(epochKey: epochKey, nonce: nonce, associatedData: ad)
    return header + nonce + (try AESGCM.seal(key: kBlob, nonce: nonce, aad: ad, plaintext: region))
  }

  package static func open(_ frame: [UInt8], layout: FrameV3.Layout, prevHash: Hash32, epochKey: some ContiguousBytes)
    -> Data?
  {
    let header = Data(frame[layout.header])
    let nonce = Data(frame[layout.nonce])
    let ad = associatedData(header: header, prevHash: prevHash)
    guard let kBlob = try? KeyDerivation.blobKey(epochKey: epochKey, nonce: nonce, associatedData: ad) else { return nil }
    return try? AESGCM.open(
      key: kBlob, nonce: nonce, aad: ad, sealed: Data(frame[layout.region.lowerBound..<layout.tag.upperBound]))
  }
}

public enum OpenOutcome: Sendable, Hashable {
  case opened(Data)
  case hardStop(ReaderHardStop)
  case refreshEpoch(UInt32)
  case needsUnlock(epoch: UInt32)
  case setAside(SetAsideReason, alarm: Bool)
}

public struct Opener: Sendable {
  public let epochHWM: UInt32
  public let keys: [UInt32: EpochKey]

  public init(epochHWM: UInt32, keys: [EpochKey]) {
    self.epochHWM = epochHWM
    var d: [UInt32: EpochKey] = [:]
    for k in keys { d[k.epoch] = k }
    self.keys = d
  }

  public func open(_ frame: Data, envelope: Envelope, prevHash: Hash32, serverEpoch: UInt32? = nil) -> OpenOutcome {
    let b = [UInt8](frame)
    let n = b.count
    guard FrameV3.isBucket(n) else { return .hardStop(.tampered(.rowShape)) }
    if b[0] > FrameV3.version { return .hardStop(.updateRequired) }
    guard b[0] == FrameV3.version, let h = FrameV3.parseHeader(b) else { return .hardStop(.tampered(.legacyFrame)) }
    guard h.aadLength + 67 <= n, FrameV3.isValidEpoch(h.epoch) else { return .hardStop(.tampered(.badHeader)) }
    if h.epoch > epochHWM {
      guard let serverEpoch else { return .refreshEpoch(h.epoch) }
      guard serverEpoch >= h.epoch else { return .hardStop(.tampered(.epochInvalid)) }
    }
    let layout = FrameV3.Layout(aadLength: h.aadLength, frameLength: n)
    guard constantTimeEquals(Data(b[layout.aad]), envelope.aad) else { return .hardStop(.tampered(.aadMismatch)) }
    guard let key = keys[h.epoch] else { return .needsUnlock(epoch: h.epoch) }
    guard let region = FrameAEAD.open(b, layout: layout, prevHash: prevHash, epochKey: key.key) else {
      return .setAside(.aeadFailed, alarm: true)
    }
    let r = [UInt8](region)
    let m = Int(r[0]) << 24 | Int(r[1]) << 16 | Int(r[2]) << 8 | Int(r[3])
    guard m <= r.count - 4 else { return .setAside(.regionMalformed, alarm: false) }
    guard let plaintext = try? Gzip.decompress(r[4..<(4 + m)], maxOutputBytes: FrameV3.maxPlaintext) else {
      return .setAside(.payloadInvalid, alarm: false)
    }
    return .opened(plaintext)
  }
}
