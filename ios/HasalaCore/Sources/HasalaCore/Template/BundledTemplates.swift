import CorePrimitives
import CoreResources
import Foundation

public enum BundledTemplates {
  public struct Skipped: Sendable, Equatable {
    public let id: String
    public let reason: String
  }

  public struct LoadResult: Sendable {
    public let templates: [CompiledTemplate]
    public let skipped: [Skipped]
  }

  public enum Channel: Sendable {
    case mail, sms
  }

  public static func load(channel: Channel) -> LoadResult {
    load(entries: TemplatesManifest.entries, channel: channel) { file in
      CoreResources.bundle.url(forResource: file, withExtension: nil, subdirectory: "templates")
        .flatMap { try? Data(contentsOf: $0) }
    }
  }

  static func load(entries: [TemplatesManifest.Entry], channel: Channel, read: (String) -> Data?) -> LoadResult {
    var templates: [CompiledTemplate] = []
    var skipped: [Skipped] = []
    for e in entries {
      guard let data = read(e.file) else {
        skipped.append(Skipped(id: e.id, reason: "missing"))
        continue
      }
      guard Hex.encode(sha256(data)).utf8.elementsEqual(e.sha256.utf8) else {
        skipped.append(Skipped(id: e.id, reason: "sha256"))
        continue
      }
      do throws(TemplateError) {
        let d = try TemplateDefinition(json: [UInt8](data))
        if d.isSMS != (channel == .sms) { continue }
        let t = try CompiledTemplate(d)
        guard t.definition.id.utf8.elementsEqual(e.id.utf8), t.definition.version == e.version else {
          skipped.append(Skipped(id: e.id, reason: "definition"))
          continue
        }
        templates.append(t)
      } catch .dialect {
        skipped.append(Skipped(id: e.id, reason: "dialect"))
      } catch {
        skipped.append(Skipped(id: e.id, reason: "definition"))
      }
    }
    return LoadResult(templates: templates, skipped: skipped)
  }
}
