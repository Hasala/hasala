import Foundation

nonisolated enum APNsEnvironmentResolution: Sendable, Equatable {
  case resolved(String)
  case unknown
}

nonisolated func resolveAPNsEnvironment() -> APNsEnvironmentResolution {
  #if targetEnvironment(simulator)
    return .unknown
  #else
    return APNsProfile.resolve(profileAt: Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"))
  #endif
}

nonisolated enum APNsProfile {
  static let production = "production"
  static let sandbox = "sandbox"

  static func resolve(profileAt url: URL?) -> APNsEnvironmentResolution {
    guard let url, FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
      return .resolved(production)
    }
    guard let data = try? Data(contentsOf: url) else { return .unknown }
    return resolve(profile: data)
  }

  static func resolve(profile data: Data) -> APNsEnvironmentResolution {
    guard let plist = embeddedPlist(data),
      let root = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
      let entitlements = root["Entitlements"] as? [String: Any],
      let environment = entitlements["aps-environment"] as? String
    else { return .unknown }
    switch environment {
    case "development": return .resolved(sandbox)
    case "production": return .resolved(production)
    default: return .unknown
    }
  }

  static func embeddedPlist(_ data: Data) -> Data? {
    guard let start = data.firstRange(of: Data("<?xml".utf8)),
      let end = data[start.lowerBound...].firstRange(of: Data("</plist>".utf8))
    else { return nil }
    return Data(data[start.lowerBound..<end.upperBound])
  }
}
