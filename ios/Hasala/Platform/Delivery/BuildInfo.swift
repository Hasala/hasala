import Foundation

nonisolated public struct BuildInfo: Sendable, Equatable {
  public let marketingVersion: String
  public let buildNumber: String
  public let gitCommit: String
  public let environment: String
  public let apiBaseURL: URL
  public let googleClientID: String
  public let googleRedirectScheme: String
  public let gmailPubSubTopic: String
  public let outlookClientID: String
  public let outlookRedirectScheme: String
  public let assistBaseURL: URL?

  public enum Problem: Error, Equatable {
    case missing(String)
    case malformed(String)
  }

  public init(infoDictionary info: [String: Any]) throws(Problem) {
    func string(_ key: String) throws(Problem) -> String {
      guard let v = info[key] as? String else { throw .missing(key) }
      let trimmed = v.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else { throw .malformed(key) }
      return trimmed
    }
    marketingVersion = try string("CFBundleShortVersionString")
    buildNumber = try string("CFBundleVersion")
    gitCommit = try string("HasalaGitCommit")
    environment = try string("HasalaEnvironment")
    let base = try string("HasalaAPIBaseURL")
    guard let url = URL(string: base), url.scheme == "https", url.host() != nil else {
      throw .malformed("HasalaAPIBaseURL")
    }
    apiBaseURL = url
    googleClientID = try string("HasalaGoogleClientID")
    googleRedirectScheme = try string("HasalaGoogleRedirectScheme")
    gmailPubSubTopic = try string("HasalaGmailPubSubTopic")
    outlookClientID = try string("HasalaOutlookClientID")
    outlookRedirectScheme = try string("HasalaOutlookRedirectScheme")
    assistBaseURL = Self.assistURL(info["HasalaAssistBaseURL"])
  }

  public static func assistURL(_ value: Any?) -> URL? {
    guard let raw = (value as? String)?.trimmingCharacters(in: .whitespaces), !raw.isEmpty, !raw.hasPrefix("$("),
      let url = URL(string: raw), url.scheme?.lowercased() == "https", let host = url.host(), !host.isEmpty
    else { return nil }
    return url
  }

  public static func assistBaseURL() -> URL? {
    current.assistBaseURL
  }

  public static let current: BuildInfo = {
    do {
      return try BuildInfo(infoDictionary: Bundle.main.infoDictionary ?? [:])
    } catch {
      fatalError("Info.plist is missing a Hasala build key: \(error)")
    }
  }()

  public static func apiBaseURL() -> URL {
    #if DEBUG
      do {
        if let url = try debugAPIBaseURLOverride(ProcessInfo.processInfo.environment) {
          return url
        }
      } catch {
        fatalError("HASALA_API_BASE_URL must be an http(s) URL with a host")
      }
    #endif
    return current.apiBaseURL
  }

  #if DEBUG
    static func debugAPIBaseURLOverride(_ environment: [String: String]) throws(Problem) -> URL? {
      let key = "HASALA_API_BASE_URL"
      guard let raw = environment[key]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
        return nil
      }
      guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
        scheme == "http" || scheme == "https", let host = url.host(), !host.isEmpty
      else { throw .malformed(key) }
      return url
    }
  #endif

  public var footer: String {
    "Hasala \(environment.uppercased()) · \(marketingVersion) (\(buildNumber)) · \(gitCommit)"
  }
}
