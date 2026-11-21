import CoreWire
import Foundation

public enum LooksSealedCheck: String, Sendable, Hashable, CaseIterable {
  case bucket
  case version
  case epoch
  case aadLen = "aad_len"
  case nonce
  case tag
  case tail
  case gzip
}

public enum LooksSealed {
  public static func check(_ frame: some DataProtocol) -> LooksSealedCheck? {
    let b = [UInt8](frame)
    let n = b.count
    guard FrameV3.isBucket(n) else { return .bucket }
    guard b[0] == FrameV3.version else { return .version }
    guard b[1] < 0x80, b[1..<5].contains(where: { $0 != 0 }) else { return .epoch }
    let l = Int(b[5]) << 8 | Int(b[6])
    guard l + 67 <= n else { return .aadLen }
    guard b[(7 + l)..<(19 + l)].contains(where: { $0 != 0 }) else { return .nonce }
    guard b[(n - 16)..<n].contains(where: { $0 != 0 }) else { return .tag }
    guard b[(n - 48)..<(n - 16)].contains(where: { $0 != 0 }) else { return .tail }
    guard !(b[23 + l] == 0x1f && b[24 + l] == 0x8b && b[25 + l] == 0x08) else { return .gzip }
    return nil
  }
}
