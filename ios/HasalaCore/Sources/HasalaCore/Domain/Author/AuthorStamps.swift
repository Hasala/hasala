import Synchronization

public final class AuthorStamps: Sendable {
  private let last = Mutex<Int64?>(nil)

  public init() {}

  public var lastMs: Int64? { last.withLock { $0 } }

  public func authoring<T: Sendable, E: Error>(
    _ body: (_ lastMs: Int64?) throws(E) -> (value: T, lastMs: Int64?)
  ) throws(E) -> T {
    try last.withLock { (v: inout Int64?) throws(E) -> T in
      let r = try body(v)
      if let l = r.lastMs { v = max(v ?? l, l) }
      return r.value
    }
  }

  public func build(_ context: AuthorContext, _ body: (inout OpAuthor) throws(AuthorError) -> Void) throws(AuthorError)
    -> AuthoredBlob?
  {
    try authoring { (floor: Int64?) throws(AuthorError) -> (value: AuthoredBlob?, lastMs: Int64?) in
      var a = OpAuthor(context.raised(to: floor))
      try body(&a)
      guard a.count > 0 else { return (nil, nil) }
      let blob = try a.build()
      return (blob, blob.lastAuthoredMs)
    }
  }

  public func categorizations(_ items: [OpAuthor.Categorization], context: AuthorContext) throws(AuthorError) -> [AuthoredBlob] {
    try authoring { (floor: Int64?) throws(AuthorError) -> (value: [AuthoredBlob], lastMs: Int64?) in
      let blobs = try OpAuthor.categorizations(items, context: context.raised(to: floor))
      return (blobs, blobs.last?.lastAuthoredMs)
    }
  }
}

extension AuthorContext {
  public func raised(to floor: Int64?) -> AuthorContext {
    var c = self
    c.ownLastMs = [ownLastMs, floor].compactMap { $0 }.max()
    return c
  }
}
