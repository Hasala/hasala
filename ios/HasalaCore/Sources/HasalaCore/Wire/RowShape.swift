import CorePrimitives
import Foundation
import HasalaText

public enum RowShape {
  public struct Checked: Sendable, Hashable {
    public let writerID: WriterID
    public let counter: Int64
    public let prevHash: Hash32
    public let blobHash: Hash32
    public let blob: Data
  }

  public static func check(
    stream: String, writerID: String, counter: String, sizeBucket: Int, blob: Data, prevHash: Data, blobHash: Data
  ) -> Checked? {
    guard utf8Equal(stream, Envelope.stream), let w = WriterID(writerID) else { return nil }
    guard ASCII.isDecimal(counter), let c = Int64(counter), c >= 1 else { return nil }
    guard sizeBucket == blob.count, FrameV3.isBucket(sizeBucket) else { return nil }
    guard let p = Hash32(prevHash), let h = Hash32(blobHash) else { return nil }
    return Checked(writerID: w, counter: c, prevHash: p, blobHash: h, blob: blob)
  }
}
