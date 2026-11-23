import CoreCategorize
import CoreReplay
import CoreWire
import Foundation
import GRDB
import Synchronization

public final class ProjectionStore: Sendable {
  let queue: DatabaseQueue
  public let reader: LedgerReader
  public let url: URL?
  private let projections = Atomic<UInt64>(0)

  public var generation: UInt64 { projections.load(ordering: .acquiring) }

  init(queue: DatabaseQueue, url: URL?) {
    self.queue = queue
    self.url = url
    reader = LedgerReader(queue)
  }

  public static func open(directory: URL) throws -> ProjectionStore {
    let url = directory.appendingPathComponent("projection.sqlite")
    return ProjectionStore(queue: try Projector.open(path: url.path), url: url)
  }

  public static func inMemory() throws -> ProjectionStore {
    ProjectionStore(queue: try Projector.open(path: nil), url: nil)
  }

  public func project(
    _ state: State, pending: [[Op]], writerID: String, dictionary: MerchantDictionary, projectedAtMs: Int64
  ) throws {
    try Projector.project(
      state, pending: pending, writerID: writerID, dictionary: dictionary, projectedAtMs: projectedAtMs, into: queue)
    projections.add(1, ordering: .releasing)
  }
}
