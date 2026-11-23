import CoreCategorize
import Foundation

#if canImport(FoundationModels)
  import FoundationModels

  public struct FoundationModelsCategoryModel: CategoryModel {
    public let modelTag: String

    public init(modelTag: String = HasalaModelFactory.osModelTag()) {
      self.modelTag = modelTag
    }

    static var options: GenerationOptions { .greedy(maximumResponseTokens: 24) }

    public func availability() -> ModelAvailability {
      let model = SystemLanguageModel(useCase: .general)
      switch model.availability {
      case .available:
        let english = model.supportedLanguages.contains { $0.languageCode?.identifier == "en" }
        return english ? .available : .unsupportedLanguage
      case .unavailable(let reason):
        switch reason {
        case .deviceNotEligible: return .notEligible
        case .appleIntelligenceNotEnabled: return .notEnabled
        case .modelNotReady: return .notReady
        @unknown default: return .notReady
        }
      }
    }

    public func suggest(subject: String, allowed: [AllowedCategory]) async -> ModelAnswer {
      guard !allowed.isEmpty else { return .unknown }
      do {
        let session = LanguageModelSession(
          model: SystemLanguageModel(useCase: .general), instructions: ModelTier.instructions(allowed))
        let choice = DynamicGenerationSchema(name: "CategoryId", anyOf: allowed.map(\.id) + ["unknown"])
        let root = DynamicGenerationSchema(name: "Answer", properties: [.init(name: "category", schema: choice)])
        let schema = try GenerationSchema(root: root, dependencies: [])
        let reply = try await session.respond(
          to: ModelTier.prompt(subject: subject), schema: schema, includeSchemaInPrompt: true,
          options: Self.options)
        let id: String = try reply.content.value(String.self, forProperty: "category")
        return allowed.contains { $0.id == id } ? .category(id) : .unknown
      } catch let error as LanguageModelSession.GenerationError {
        return .failed(ModelFailure(error))
      } catch is CancellationError {
        return .failed(.timeout)
      } catch {
        return .failed(.other)
      }
    }
  }

  extension GenerationOptions {
    static func greedy(maximumResponseTokens: Int) -> GenerationOptions {
      #if compiler(>=6.4)
        GenerationOptions(samplingMode: .greedy, maximumResponseTokens: maximumResponseTokens)
      #else
        GenerationOptions(sampling: .greedy, maximumResponseTokens: maximumResponseTokens)
      #endif
    }
  }

  extension ModelFailure {
    init(_ error: LanguageModelSession.GenerationError) {
      switch error {
      case .exceededContextWindowSize: self = .contextOverflow
      case .rateLimited: self = .rateLimited
      case .concurrentRequests: self = .busy
      case .guardrailViolation: self = .guardrail
      case .refusal: self = .refusal
      case .unsupportedLanguageOrLocale: self = .unsupportedLanguage
      case .assetsUnavailable: self = .assetsUnavailable
      case .decodingFailure: self = .decoding
      default: self = .other
      }
    }
  }
#endif

public struct UnavailableCategoryModel: CategoryModel {
  public let modelTag = "none"
  public init() {}
  public func availability() -> ModelAvailability { .notEligible }
  public func suggest(subject: String, allowed: [AllowedCategory]) async -> ModelAnswer { .failed(.assetsUnavailable) }
}

public enum HasalaModelFactory {
  public static func osModelTag(_ v: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> String {
    "apple-fm/\(v.majorVersion).\(v.minorVersion)"
  }

  public static func make() -> any CategoryModel {
    #if canImport(FoundationModels)
      return FoundationModelsCategoryModel()
    #else
      return UnavailableCategoryModel()
    #endif
  }
}
