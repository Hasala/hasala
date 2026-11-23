import Foundation
import zlib

public enum Gzip {
  public static let level: Int32 = 9

  public static func compress(_ data: some DataProtocol) throws(GzipError) -> Data {
    let input = [UInt8](data)
    var stream = z_stream()
    let initStatus = deflateInit2_(
      &stream, level, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY, zlibVersion(),
      Int32(MemoryLayout<z_stream>.size))
    guard initStatus == Z_OK else { throw .zlib(status: initStatus) }
    defer { deflateEnd(&stream) }

    let bound = Int(deflateBound(&stream, uLong(input.count)))
    var out = [UInt8](repeating: 0, count: bound)
    let status: Int32 = input.withUnsafeBufferPointer { inp in
      out.withUnsafeMutableBufferPointer { o in
        stream.next_in = UnsafeMutablePointer(mutating: inp.baseAddress)
        stream.avail_in = uInt(inp.count)
        stream.next_out = o.baseAddress
        stream.avail_out = uInt(o.count)
        return deflate(&stream, Z_FINISH)
      }
    }
    guard status == Z_STREAM_END else { throw .zlib(status: status) }
    return Data(out[0..<Int(stream.total_out)])
  }

  public static func decompress(_ data: some DataProtocol, maxOutputBytes: Int) throws(GzipError) -> Data {
    let input = [UInt8](data)
    var stream = z_stream()
    let initStatus = inflateInit2_(&stream, 31, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
    guard initStatus == Z_OK else { throw .zlib(status: initStatus) }
    defer { inflateEnd(&stream) }

    let chunkSize = 64 * 1024
    var chunk = [UInt8](repeating: 0, count: chunkSize)
    var out = Data()
    var finished = false

    try input.withUnsafeBufferPointer { (inp: UnsafeBufferPointer<UInt8>) throws(GzipError) in
      stream.next_in = UnsafeMutablePointer(mutating: inp.baseAddress)
      stream.avail_in = uInt(inp.count)
      while !finished {
        let (status, produced) = chunk.withUnsafeMutableBufferPointer { o -> (Int32, Int) in
          stream.next_out = o.baseAddress
          stream.avail_out = uInt(o.count)
          let s = inflate(&stream, Z_NO_FLUSH)
          return (s, o.count - Int(stream.avail_out))
        }
        switch status {
        case Z_STREAM_END: finished = true
        case Z_OK: break
        case Z_BUF_ERROR:
          if produced == 0 { throw .truncated }
        case Z_DATA_ERROR: throw .corrupt
        default: throw .zlib(status: status)
        }
        if produced > 0 {
          guard out.count + produced <= maxOutputBytes else { throw .overCap(maxOutputBytes) }
          out.append(contentsOf: chunk[0..<produced])
        }
        if !finished, stream.avail_in == 0, produced == 0 { throw .truncated }
      }
      guard stream.avail_in == 0 else { throw .trailingData }
    }
    return out
  }
}

public enum GzipError: Error, Equatable, Sendable {
  case overCap(Int)
  case truncated
  case corrupt
  case trailingData
  case zlib(status: Int32)
}
