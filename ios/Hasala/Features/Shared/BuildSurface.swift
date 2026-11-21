import Foundation

nonisolated enum BuildSurface {
  static let showsUnfinished: Bool = {
    #if DEBUG
      !ProcessInfo.processInfo.arguments.contains(releaseArgument)
    #else
      false
    #endif
  }()

  static let showsPlanTab: Bool = {
    #if DEBUG
      ProcessInfo.processInfo.arguments.contains(planTabArgument)
    #else
      false
    #endif
  }()

  static let forcesIncreasedContrast: Bool = {
    #if DEBUG
      ProcessInfo.processInfo.arguments.contains(increaseContrastArgument)
    #else
      false
    #endif
  }()

  #if DEBUG
    static let increaseContrastArgument = "-HasalaIncreaseContrast"
    static let planTabArgument = "-HasalaPlanTab"
    static let releaseArgument = "-HasalaReleaseSurface"
  #endif

  static let showsCloudSuggestions: Bool = BuildInfo.assistBaseURL() != nil

  static let showsGoogleBriefing = true

  static let supportEmail = "support@hasala.app"
  static let supportMail = URL(string: "mailto:\(supportEmail)")!
  static let supportPage = URL(string: "https://hasala.app/support")!
}
