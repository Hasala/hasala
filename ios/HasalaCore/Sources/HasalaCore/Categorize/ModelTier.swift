import CorePrimitives
import Foundation
import HasalaText
import Synchronization

public enum ModelAvailability: String, Sendable, Equatable {
  case available, notEligible, notEnabled, notReady, unsupportedLanguage
}

public enum ModelFailure: String, Sendable, Equatable {
  case timeout, guardrail, refusal, rateLimited, busy, contextOverflow, assetsUnavailable, decoding, unsupportedLanguage, notEnabled,
    refused, offScreen, cancelled, other
}

public enum ModelAnswer: Sendable, Equatable {
  case category(String)
  case unknown
  case failed(ModelFailure)
}

public struct AllowedCategory: Sendable, Equatable {
  public let id: String
  public let name: String
  public let hint: String?

  public init(id: String, name: String, hint: String?) {
    self.id = id
    self.name = name
    self.hint = hint
  }
}

public protocol CategoryModel: Sendable {
  func availability() -> ModelAvailability
  func suggest(subject: String, allowed: [AllowedCategory]) async -> ModelAnswer
  var modelTag: String { get }
}

public protocol GradedCategoryModel: CategoryModel {
  func suggestGraded(subject: String, allowed: [AllowedCategory]) async -> (answer: ModelAnswer, autoFile: Bool)
}

public enum ModelTier {
  public static let autoConfirm = false

  public static let autoFilePrefix = "cf-clef/"

  public static func mayAutoFile(modelTag: String) -> Bool { modelTag.hasPrefix(autoFilePrefix) }

  public enum Context: Sendable {
    case foreground, processing, refresh, backlog

    public var budget: (calls: Int, phaseMs: Int64, callMs: Int64) {
      switch self {
      case .foreground: (40, 20_000, 6_000)
      case .processing: (200, 120_000, 6_000)
      case .refresh: (0, 0, 0)
      case .backlog: (12, 30_000, 6_000)
      }
    }
  }

  public static func allowed(_ categories: [CategoryInfo]) -> [AllowedCategory] {
    categories
      .filter { $0.active && $0.kind == .spending && ($0.bucket == .need || $0.bucket == .want) }
      .sorted { $0.sortKey != $1.sortKey ? $0.sortKey < $1.sortKey : compareUTF8($0.id, $1.id) < 0 }
      .map { c in
        AllowedCategory(id: c.id, name: c.name, hint: c.builtin ? TaxonomyV1.modelHints.first { $0.id == c.id }?.hint : nil)
      }
  }

  public static func instructions(_ allowed: [AllowedCategory]) -> String {
    var lines = [
      "You sort card payments made in the United Arab Emirates into budget categories.",
      "You are given one merchant name as printed by a bank.",
      "Choose the single category that best fits what is usually bought there.",
      "If you do not know the merchant, or it could fit several categories, choose unknown.",
      "Categories:",
    ]
    for a in allowed {
      lines.append(a.hint.map { "- \(a.id): \(a.name) (\($0))" } ?? "- \(a.id): \(a.name)")
    }
    return lines.joined(separator: "\n")
  }

  public static func prompt(subject: String) -> String {
    var out = String.UnicodeScalarView()
    var lastSpace = false
    for s in truncateRunes(subject, 64).unicodeScalars {
      let c: Unicode.Scalar = (0x20...0x7E).contains(s.value) ? s : " "
      if c == " " {
        if lastSpace { continue }
        lastSpace = true
      } else {
        lastSpace = false
      }
      out.append(c)
    }
    return "Merchant: " + String(out).trimming(.asciiSpace)
  }

  public static func taxonomyHash(_ allowed: [AllowedCategory]) -> String {
    var text = "["
    for (i, a) in allowed.enumerated() {
      if i > 0 { text += "," }
      text += "\"\(a.id)\""
    }
    text += "]"
    return domainHash("hasala/v1/category-taxonomy", [Array(text.utf8)])
  }

  public static func cacheKey(subject: String, taxonomyHash: String, modelTag: String) -> String {
    domainHash("hasala/v1/fm-cache", [Array(subject.utf8), Array(taxonomyHash.utf8), Array(modelTag.utf8)])
  }

  public static func keptKey(subject: String, modelTag: String) -> String {
    domainHash("hasala/v1/fm-kept", [Array(subject.utf8), Array(modelTag.utf8)])
  }

  static func domainHash(_ domain: String, _ fields: [[UInt8]]) -> String {
    var bytes = Array(domain.utf8)
    for f in fields {
      bytes.append(0)
      bytes += f
    }
    return Hex.encode(sha256(bytes))
  }

  public struct Suggestion: Sendable, Equatable {
    public let subject: String
    public let category: String
  }

  public static func run(
    subjects: [String], model: any CategoryModel, allowed: [AllowedCategory], context: Context, now: @Sendable () -> Int64,
    callTimeout: Duration? = nil
  ) async -> (suggestions: [Suggestion], unknown: [String], stoppedBy: ModelFailure?) {
    let r = await run(
      subjects: subjects, stages: [ModelStage(model: model, accepts: LatinGate.passes)], allowed: allowed, context: context, now: now,
      callTimeout: callTimeout)
    return (
      r.suggestions.map { Suggestion(subject: $0.subject, category: $0.category) }, r.unknown.map(\.subject),
      r.stoppedBy[model.modelTag]
    )
  }

  struct Graded: Sendable {
    let answer: ModelAnswer
    let autoFile: Bool
  }

  static func graded(_ model: any CategoryModel, subject: String, allowed: [AllowedCategory], within limit: Duration) async -> Graded {
    let race = Race()
    let timedOut = Graded(answer: .failed(.timeout), autoFile: false)
    let cancelled = Graded(answer: .failed(.cancelled), autoFile: false)
    return await withTaskCancellationHandler {
      await withCheckedContinuation { (k: CheckedContinuation<Graded, Never>) in
        race.start(
          k,
          call: Task {
            if let g = model as? any GradedCategoryModel {
              let r = await g.suggestGraded(subject: subject, allowed: allowed)
              race.finish(Graded(answer: r.answer, autoFile: r.autoFile))
            } else {
              race.finish(Graded(answer: await model.suggest(subject: subject, allowed: allowed), autoFile: false))
            }
          },
          timer: Task {
            try? await Task.sleep(for: limit)
            race.finish(timedOut)
          })
      }
    } onCancel: {
      race.finish(cancelled)
    }
  }

  private final class Race: Sendable {
    private struct Inner {
      var k: CheckedContinuation<Graded, Never>?
      var tasks: [Task<Void, Never>] = []
      var done: Graded?
    }
    private let inner = Mutex(Inner())

    func start(_ k: CheckedContinuation<Graded, Never>, call: Task<Void, Never>, timer: Task<Void, Never>) {
      let early: Graded? = inner.withLock { i in
        if let d = i.done { return d }
        i.k = k
        i.tasks = [call, timer]
        return nil
      }
      if let early {
        call.cancel()
        timer.cancel()
        k.resume(returning: early)
      }
    }

    func finish(_ a: Graded) {
      let (k, tasks) = inner.withLock { i -> (CheckedContinuation<Graded, Never>?, [Task<Void, Never>]) in
        guard i.done == nil else { return (nil, []) }
        i.done = a
        defer {
          i.k = nil
          i.tasks = []
        }
        return (i.k, i.tasks)
      }
      for t in tasks { t.cancel() }
      k?.resume(returning: a)
    }
  }
}
