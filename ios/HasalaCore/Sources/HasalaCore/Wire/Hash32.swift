import CorePrimitives
import Foundation

public struct Hash32: Sendable, Hashable, CustomStringConvertible {
  public static let byteCount = 32
  public static let zero = Hash32(unchecked: Data(count: 32))

  public let bytes: Data

  public init?(_ bytes: some DataProtocol) {
    guard bytes.count == Hash32.byteCount else { return nil }
    self.bytes = Data(bytes)
  }

  public init?(hex: String) {
    guard let d = try? Hex.decode(hex), d.count == Hash32.byteCount else { return nil }
    bytes = d
  }

  init(unchecked bytes: Data) { self.bytes = bytes }

  public static func of(_ data: some DataProtocol) -> Hash32 { Hash32(unchecked: sha256(data)) }

  public var hex: String { Hex.encode(bytes) }
  public var description: String { hex }
}
