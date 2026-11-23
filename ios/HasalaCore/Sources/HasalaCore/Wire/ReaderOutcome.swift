import Foundation

public enum TamperReason: String, Sendable, Hashable, CaseIterable {
  case rowShape
  case unknownWriter
  case chainBreak
  case headUnsigned, headInvalid, afterRevocation
  case legacyFrame
  case badHeader, epochInvalid
  case aadMismatch
  case ownChainConflict
}

public enum ReaderHardStop: Error, Sendable, Hashable {
  case tampered(TamperReason)
  case updateRequired
}

public enum SetAsideReason: String, Sendable, Hashable, CaseIterable {
  case aeadFailed
  case regionMalformed
  case payloadInvalid
  case opsUndecodable
}

public enum OpsDecodeOutcome: Sendable, Hashable {
  case ops([Op])
  case hardStop(ReaderHardStop)
  case setAside(SetAsideReason, message: String)
}

extension OpCodec {
  public static func decodeR10(_ plaintext: some Collection<UInt8>) -> OpsDecodeOutcome {
    do {
      return .ops(try decodeBlobOps(plaintext))
    } catch {
      switch error {
      case .unknownNewerVersion: return .hardStop(.updateRequired)
      case .setAside(let m): return .setAside(.opsUndecodable, message: m)
      }
    }
  }
}
