import Foundation
import Security

public protocol RandomSource: Sendable {
  func fill(_ buffer: UnsafeMutableRawBufferPointer) throws(PrimitivesError)
}

extension RandomSource {
  public func bytes(_ count: Int) throws(PrimitivesError) -> Data {
    var out = Data(count: count)
    var failure: PrimitivesError?
    out.withUnsafeMutableBytes { (b: UnsafeMutableRawBufferPointer) in
      do throws(PrimitivesError) { try fill(b) } catch { failure = error }
    }
    if let failure { throw failure }
    return out
  }

  public func uuidV4() throws(PrimitivesError) -> String {
    var b = [UInt8](try bytes(16))
    b[6] = (b[6] & 0x0f) | 0x40
    b[8] = (b[8] & 0x3f) | 0x80
    return UserID.canonicalString(b)
  }
}

public struct SystemRandom: RandomSource {
  public init() {}

  public func fill(_ buffer: UnsafeMutableRawBufferPointer) throws(PrimitivesError) {
    guard let base = buffer.baseAddress, buffer.count > 0 else { return }
    let status = SecRandomCopyBytes(kSecRandomDefault, buffer.count, base)
    guard status == errSecSuccess else { throw .randomUnavailable(status: status) }
  }
}
