import Foundation

public final class SecureBytes: ContiguousBytes, CustomStringConvertible, CustomDebugStringConvertible {
  private let buffer: UnsafeMutableRawBufferPointer

  public init(count: Int) {
    precondition(count >= 0, "SecureBytes count must not be negative")
    buffer = .allocate(byteCount: count, alignment: 1)
    buffer.initializeMemory(as: UInt8.self, repeating: 0)
  }

  public convenience init(copying bytes: some ContiguousBytes) {
    let count = bytes.withUnsafeBytes { $0.count }
    self.init(count: count)
    bytes.withUnsafeBytes { src in
      if let base = src.baseAddress, count > 0 { buffer.baseAddress!.copyMemory(from: base, byteCount: count) }
    }
  }

  deinit {
    Self.zero(buffer)
    buffer.deallocate()
  }

  public var count: Int { buffer.count }

  public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
    try body(UnsafeRawBufferPointer(buffer))
  }

  public func withUnsafeMutableBytes<R>(_ body: (UnsafeMutableRawBufferPointer) throws -> R) rethrows -> R {
    try body(buffer)
  }

  public func wipe() { Self.zero(buffer) }

  public var description: String { "<redacted>" }
  public var debugDescription: String { "<redacted>" }

  private static func zero(_ b: UnsafeMutableRawBufferPointer) {
    guard let base = b.baseAddress, b.count > 0 else { return }
    _ = memset_s(base, b.count, 0, b.count)
  }
}

public func constantTimeEquals(_ a: some ContiguousBytes, _ b: some ContiguousBytes) -> Bool {
  a.withUnsafeBytes { x in
    b.withUnsafeBytes { y in
      guard x.count == y.count else { return false }
      var diff: UInt8 = 0
      for i in 0..<x.count { diff |= x[i] ^ y[i] }
      return diff == 0
    }
  }
}
