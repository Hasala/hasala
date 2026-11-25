import CoreAuth
import CoreStore
import CoreWire
import Foundation

public enum HaltKind: Sendable, Hashable {
  case updateRequired
  case tampered(TamperReason)
  case tamperedResend
  case serverRestored
  case inconsistent(String)
  case rosterInvalid
  case unprovedRevocation
  case unexpectedGone
}

public enum SyncPhase: Sendable, Hashable {
  case idle
  case reconciling
  case pulling
  case pushing
  case selfPull
  case offline(sinceMs: Int64)
  case halted(HaltKind)
  case frozen
  case needsSignIn
  case needsRebind
  case needsUnlock(epoch: UInt32)
  case keysRequired
  case wiping
}

public struct SyncStatus: Sendable, Hashable {
  public var phase: SyncPhase = .idle
  public var lastSuccessAt: Int64?
  public var latch: OutboxLatch?
  public var pendingCount: Int = 0
  public var suspended: Bool = false
  public var integrityAlarms: Int = 0
  public var rowAlarms: Int = 0
  public var retryAfterSeconds: Int?

  public init() {}

  public var uploadsStuck: Bool { latch?.keepsChangesFromUploading == true }
}

public enum SyncStop: Error, Sendable, Hashable {
  case offline
  case rateLimited(retryAfter: Int?)
  case halted(HaltKind)
  case latched(OutboxLatch, alarm: Bool = false)
  case frozen
  case needsSignIn
  case needsRebind
  case needsUnlock(epoch: UInt32)
  case keysRequired
  case wipe
  case suspended
  case notNow
  case store(StoreError)
  case protocolError(String)
  case cancelled
}

extension SyncStop {
  static func common(_ e: APIError) -> SyncStop? {
    switch e {
    case .transport(.cancelled): return .cancelled
    case .transport: return .offline
    case .malformed(let m): return .protocolError(m)
    case .refused(let f):
      switch (f.status, f.code) {
      case (401, _): return .needsSignIn
      case (403, "account_frozen"): return .frozen
      case (403, "account_suspended"): return .suspended
      case (410, "account_deleted"): return .wipe
      case (410, _): return .halted(.unexpectedGone)
      case (403, "writer_revoked"): return .halted(.unprovedRevocation)
      case (403, "writer_unbound"), (403, "writer_mismatch"): return .needsRebind
      case (403, "keys_required"): return .keysRequired
      case (426, _): return .halted(.updateRequired)
      case (429, _): return .rateLimited(retryAfter: f.retryAfterSeconds)
      case (500..., _): return .offline
      default: return nil
      }
    }
  }

  static func read(_ e: APIError) -> SyncStop {
    if let f = e.failure, f.status == 409, f.code == "cursor_ahead" { return .halted(.tampered(.chainBreak)) }
    return common(e) ?? .protocolError("refused \(e.failure?.status ?? 0) \(e.failure?.code ?? "")")
  }
}
