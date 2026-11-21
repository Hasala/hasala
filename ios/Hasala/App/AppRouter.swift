import Observation

@MainActor
@Observable
final class AppRouter {
  var tab: AppTab = .home
  var home: [HomeRoute] = []
  var plan: [PlanRoute] = []
  var projects: [PlanRoute] = []
  var activity: [ActivityRoute] = []
  var review: [ReviewRoute] = []
  var profile: [ProfileRoute] = []
  var transaction: [TransactionRoute] = []
  var sheet: SheetRoute?
  var overProfile: SheetRoute?
  var cover: CoverRoute?
  var nextSheet: (SheetRoute, profilePath: [ProfileRoute])?
  var nextCover: CoverRoute?
  var pasteBankText = false

  #if HASALA_MOCKS
    var pendingLaunch: PendingLaunch?
  #endif

  func open(_ route: SheetRoute, profile path: [ProfileRoute] = []) {
    nextCover = nil
    if sheet != nil {
      nextSheet = (route, path)
      sheet = nil
      return
    }
    present(route, profile: path)
  }

  func sheetDismissed() {
    guard sheet == nil else { return }
    MailConnectCoordinator.release()
    MailboxMoment.discard()
    profile = []
    overProfile = nil
    transaction = []
    if let queued = nextCover {
      nextCover = nil
      cover = queued
      return
    }
    guard let next = nextSheet else { return }
    nextSheet = nil
    present(next.0, profile: next.profilePath)
  }

  func popToRoot(_ tab: AppTab) {
    switch tab {
    case .home: home = []
    case .plan: plan = []
    case .projects: projects = []
    case .activity: activity = []
    case .review: review = []
    case .add: break
    }
  }

  var projectsPath: [PlanRoute] {
    get { BuildSurface.showsPlanTab ? plan : projects }
    set {
      if BuildSurface.showsPlanTab { plan = newValue } else { projects = newValue }
    }
  }

  var projectsTab: AppTab { BuildSurface.showsPlanTab ? .plan : .projects }

  func clearPresentation() {
    MailboxMoment.discard()
    sheet = nil
    overProfile = nil
    cover = nil
    nextSheet = nil
    nextCover = nil
  }

  var sheetUpOrClosing: Bool { sheet != nil || nextSheet != nil || nextCover != nil }

  private func present(_ route: SheetRoute, profile path: [ProfileRoute]) {
    switch route {
    case .profile: profile = path
    case .transaction: transaction = []
    default: break
    }
    sheet = route
  }
}

#if HASALA_MOCKS
  struct PendingLaunch {
    var sheet: SheetRoute?
    var cover: CoverRoute?
    var profile: [ProfileRoute] = []
    var overProfile: SheetRoute?
    var transaction: [TransactionRoute] = []
  }
#endif
