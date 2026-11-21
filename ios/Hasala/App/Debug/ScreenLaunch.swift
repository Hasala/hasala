#if HASALA_MOCKS
  import Foundation
  import HasalaModels

  struct ScreenLaunch {
    struct Screen {
      let id: String
      let scenario: String
      var prepare: @MainActor (MockGraph) -> Void = { _ in }
      var drive: @MainActor (MockGraph) async -> Void = { _ in }

      init(
        _ id: String, scenario: String, drive: @escaping @MainActor (MockGraph) async -> Void = { _ in },
        prepare: @escaping @MainActor (MockGraph) -> Void = { _ in }
      ) {
        self.id = id
        self.scenario = scenario
        self.prepare = prepare
        self.drive = drive
      }
    }

    enum Area: String, CaseIterable {
      case join, setup, mail, signIn, home, activity, plan, profile

      var prefixes: Set<String> {
        switch self {
        case .join: ["welcome", "join", "phrase", "resume"]
        case .setup: ["setup"]
        case .mail: ["mail", "bankAlerts"]
        case .signIn: ["signin", "unlock", "forgot", "recover", "approval", "security", "confirm", "frozen", "unfreeze"]
        case .home: ["home"]
        case .activity: ["activity", "review", "search"]
        case .plan: ["plan"]
        case .profile: ["profile", "bills", "accounts"]
        }
      }

      var screens: [Screen] {
        switch self {
        case .join: ScreenLaunch.joinScreens
        case .setup: ScreenLaunch.setupScreens
        case .mail: ScreenLaunch.mailScreens
        case .signIn: ScreenLaunch.signInScreens
        case .home: ScreenLaunch.homeScreens
        case .activity: ScreenLaunch.activityScreens
        case .plan: ScreenLaunch.planScreens
        case .profile: ScreenLaunch.profileScreens
        }
      }

      static func of(_ id: String) -> Area? {
        let prefix = String(id.split(separator: ".", maxSplits: 1).first ?? "")
        return allCases.first { $0.prefixes.contains(prefix) }
      }
    }

    let screen: Screen
    var id: String { screen.id }
    var scenario: String { screen.scenario }

    static let argument = "-HasalaScreen"

    static var registry: [Screen] { Area.allCases.flatMap(\.screens) }

    static func from(_ arguments: [String]) -> ScreenLaunch? {
      guard let id = arguments.launchValue(after: argument),
        let screen = Area.of(id)?.screens.first(where: { $0.id == id })
      else { return nil }
      return ScreenLaunch(screen: screen)
    }

    static func isMockLaunch(_ arguments: [String]) -> Bool {
      arguments.contains("-HasalaScenario") || arguments.contains(argument)
    }

    func arguments(_ arguments: [String]) -> [String] {
      arguments.contains("-HasalaScenario") ? arguments : arguments + ["-HasalaScenario", scenario]
    }

    func open(_ graph: MockGraph) {
      if let account = graph.session.account as? MockAccountService { account.delay = .zero }
      if let mailbox = graph.session.services.mailbox as? MockMailbox { mailbox.connectDelay = .zero }
      screen.prepare(graph)
      let drive = screen.drive
      Task { await drive(graph) }
    }

    static func shell(
      _ tab: AppTab, home: [HomeRoute] = [], plan: [PlanRoute] = [], projects: [PlanRoute] = [],
      activity: [ActivityRoute] = [], sheet: SheetRoute? = nil, cover: CoverRoute? = nil,
      profile: [ProfileRoute] = [], overProfile: SheetRoute? = nil,
      transaction: [TransactionRoute] = [], review: [ReviewRoute] = []
    ) -> @MainActor (MockGraph) -> Void {
      { graph in
        let router = graph.app.router
        router.tab = tab
        router.home = home
        router.plan = plan
        router.projects = projects
        router.activity = activity
        router.review = review
        if sheet != nil || cover != nil {
          router.pendingLaunch = PendingLaunch(
            sheet: sheet, cover: cover, profile: profile, overProfile: overProfile, transaction: transaction)
        }
      }
    }

    static func profile(_ path: [ProfileRoute]) -> @MainActor (MockGraph) -> Void {
      shell(.home, sheet: .profile, profile: path)
    }

    static func cloudSort(
      _ phase: CloudSortStatus.Phase, then next: @escaping @MainActor (MockGraph) -> Void
    ) -> @MainActor (MockGraph) -> Void {
      { graph in
        if graph.app.cloudSort == nil { graph.app.cloudSort = MockCloudSortController(MockCloudSortController.sample(phase)) }
        next(graph)
      }
    }
  }

  enum MotionLaunch: String, Sendable {
    case off
    case reduce

    static let argument = "-HasalaMotion"

    static func from(_ arguments: [String]) -> MotionLaunch? {
      arguments.launchValue(after: argument).flatMap(MotionLaunch.init(rawValue:))
    }

    static let current = from(ProcessInfo.processInfo.arguments)

    var settled: Bool { self == .off }
    var reduceMotion: Bool { self == .reduce }
  }

  enum JackpotLaunch {
    static let argument = "-HasalaJackpot"

    static func from(_ arguments: [String]) -> TimeInterval? {
      guard let i = arguments.firstIndex(of: argument) else { return nil }
      guard i + 1 < arguments.count, let every = TimeInterval(arguments[i + 1]), every.isFinite else { return 0 }
      return max(every, 0)
    }

    static let current = from(ProcessInfo.processInfo.arguments)
  }

  extension [String] {
    nonisolated func launchValue(after flag: String) -> String? {
      guard let i = firstIndex(of: flag), i + 1 < count else { return nil }
      return self[i + 1]
    }
  }
#endif
