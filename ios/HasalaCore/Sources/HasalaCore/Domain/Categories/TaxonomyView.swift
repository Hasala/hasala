import CoreCategorize
import CoreReplay
import HasalaText

public struct TaxonomyView: Sendable, CategoryLookup {
  public let ordered: [CategoryInfo]
  private let byID: [ExactKey: CategoryInfo]

  public init(_ infos: [CategoryInfo]) {
    ordered = infos.sorted { $0.sortKey != $1.sortKey ? $0.sortKey < $1.sortKey : compareUTF8($0.id, $1.id) < 0 }
    var m: [ExactKey: CategoryInfo] = [:]
    for i in infos { m[ExactKey(i.id)] = i }
    byID = m
  }

  public init(state: State) {
    var infos: [CategoryInfo] = []
    for b in TaxonomyV1.builtins {
      guard let d = state.categories[ExactKey(b.id)] else {
        infos.append(b)
        continue
      }
      infos.append(Self.info(d, sortKey: b.sortKey, builtin: true, defaultIcon: b.icon))
    }
    var userIndex = 0
    for (id, d) in state.categories where TaxonomyV1.builtin(id.value) == nil {
      infos.append(Self.info(d, sortKey: 100 + userIndex, builtin: false, defaultIcon: TaxonomyV1.userIcon))
      userIndex += 1
    }
    self.init(infos)
  }

  private static func info(_ d: CategoryDef, sortKey: Int, builtin: Bool, defaultIcon: String) -> CategoryInfo {
    CategoryInfo(
      id: d.id, name: d.name, kind: CategoryKind(rawValue: d.kind) ?? .excluded, bucket: d.bucket.flatMap(Bucket.init(rawValue:)),
      icon: d.shape >= 4 ? (d.icon ?? defaultIcon) : defaultIcon, active: d.active, builtin: builtin, sortKey: sortKey,
      parent: builtin || d.shape < 4 ? nil : d.parent)
  }

  public func info(_ id: String) -> CategoryInfo? { byID[ExactKey(id)] }

  public func isSpending(_ id: String) -> Bool { byID[ExactKey(id)]?.kind == .spending }
}
