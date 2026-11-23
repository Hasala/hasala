import HasalaModels
import Observation

#if HASALA_MOCKS
  import HasalaMocks
#endif

struct Bell: Equatable {
  var needsALook: [NotificationItem]
  var earlier: [NotificationItem]
  var unread: Int = 0

  var count: Int { needsALook.count }

  static func label(_ count: Int) -> String {
    switch count {
    case ...0: "Notifications"
    case 1: "Notifications, 1 needs a look"
    default: "Notifications, \(count) need a look"
    }
  }
}

@MainActor
protocol HomeModel: AnyObject, Observable {
  var snapshot: HomeSnapshot { get }
  var canvas: [HomeCanvasItem] { get }
  var hidden: Bool { get }
  var bell: Bell { get }
  func openWidget(_ id: String, setPlan: (() -> Void)?) -> HomeRoute?
  func widgetOpens(_ id: String) -> Bool
  func openNotCounted(_ line: SpendHero.NotCounted)
  func openNotification(_ destination: NotificationDestination) -> (@MainActor () -> Void)?
  func markAllRead()
}

extension HomeModel {
  func openWidget(_ id: String) -> HomeRoute? { openWidget(id, setPlan: nil) }
}

@MainActor
@Observable
final class HomeViewModel: HomeModel {
  private let app: AppModel
  @ObservationIgnored private let feed: (any NotificationFeed)?

  init(app: AppModel) {
    self.app = app
    #if HASALA_MOCKS
      feed = BuildSurface.showsUnfinished && app.store is InMemoryLedger ? MockNotificationFeed() : nil
    #else
      feed = nil
    #endif
  }

  var snapshot: HomeSnapshot { app.snapshot }

  var canvas: [HomeCanvasItem] {
    let snapshot = app.snapshot
    guard snapshot.isThisMonth else {
      return snapshot.widgets.map { HomeCanvasItem(entry: HomeLayout.Entry($0.kind), widget: $0) }
    }
    return app.homeCanvas
  }

  var hidden: Bool { app.amountsHidden }

  var bell: Bell {
    let items = app.needsALook
    return Bell(
      needsALook: items, earlier: feed?.earlier(now: app.store.now) ?? [],
      unread: app.notificationReads.unread(items).count)
  }

  func markAllRead() {
    app.notificationReads.markAllRead(
      app.needsALook.filter { !Self.staysUnread($0) }, keeping: app.mailOfferKnown ? [] : [Self.connectRow])
  }

  static func staysUnread(_ item: NotificationItem) -> Bool {
    item.id.hasPrefix("mail.signIn.")
  }

  static let connectRow = NotificationItem(
    id: "mail.connect", disc: .neutral(.envelope), title: "Connect your email",
    line: "Then Hasala can read your bank alerts.", when: nil, destination: .bankAlerts)

  static func mailItem(_ offer: MailOffer?, mailboxes: [MailboxSnapshot]) -> NotificationItem? {
    switch offer {
    case nil:
      return nil
    case .connect:
      return connectRow
    case .signInAgain(let id, let provider):
      let address = mailboxes.first { $0.id == id }?.address ?? provider.appName
      return NotificationItem(
        id: "mail.signIn.\(id)", disc: .neutral(.envelope), title: "Sign in again to \(address)",
        line: "Hasala can't read this mailbox right now.", when: nil, destination: .bankAlerts)
    }
  }

  func openNotification(_ destination: NotificationDestination) -> (@MainActor () -> Void)? {
    let router = app.router
    switch destination {
    case .bankAlerts:
      router.open(.profile, profile: [.bankAlerts])
      return nil
    case .review(let preset):
      close()
      router.tab = .review
      return { [app] in
        if let preset { app.startReview(over: preset) } else { app.startReview() }
      }
    case .unreadMail:
      close()
      router.tab = .review
      router.review = [.unreadMail]
      return nil
    case .unreadTexts:
      close()
      router.tab = .review
      router.review = [.unreadTexts]
      return nil
    case .bill(let id):
      close()
      router.tab = .home
      router.home = [.bill(id)]
      return nil
    case .bills:
      close()
      router.tab = .home
      router.home = [.bills]
      return nil
    case .category(let id):
      if BuildSurface.showsPlanTab {
        close()
        app.openPlan(category: id)
      } else {
        router.open(.profile, profile: [.plan, .category(id)])
      }
      return nil
    }
  }

  private func close() {
    if app.router.sheet == .notifications { app.router.sheet = nil }
  }

  func openWidget(_ id: String, setPlan: (() -> Void)?) -> HomeRoute? {
    switch id {
    case "budgetPace":
      if let setPlan, app.snapshot.hero.state == .noPlan { setPlan() } else { app.openPlan() }
      return nil
    case "today", "spentSoFar":
      app.tab = .activity
      return nil
    case "nextBill", "comingUp":
      return .bills
    case "netWorth":
      return .accounts
    case "toReview":
      app.startReview()
      return nil
    default:
      if id.hasPrefix(Self.categoryPrefix) {
        app.openPlan(category: String(id.dropFirst(Self.categoryPrefix.count)))
        return nil
      }
      if id.hasPrefix(Self.projectPrefix) {
        app.openProjectsTab(String(id.dropFirst(Self.projectPrefix.count)))
        return nil
      }
      app.openPlan()
      return nil
    }
  }

  func openNotCounted(_ line: SpendHero.NotCounted) {
    app.openProjectsTab(line.projectID)
  }

  static func hold(_ hero: SpendHero, reading: ReadingState?, period: Period) -> ReadingHold? {
    guard period.isMonth, !period.isAllTime, hero.state != .range, hero.state != .syncing else { return nil }
    return ReadingOnScreen.hold(reading, month: period.first)
  }

  static let categoryPrefix = HomeWidgetKind.categoryWatch.rawValue + "."
  static let projectPrefix = HomeWidgetKind.project.rawValue + "."
  static let goalPrefix = HomeWidgetKind.goal.rawValue + "."

  static let widgetsWithDestinations: Set<String> = ["budgetPace", "today", "spentSoFar", "nextBill", "comingUp", "toReview"]

  func widgetOpens(_ id: String) -> Bool {
    if id == "netWorth" { return BuildSurface.showsUnfinished || !app.store.state.accounts.isEmpty }
    return BuildSurface.showsUnfinished || Self.widgetsWithDestinations.contains(id) || id.hasPrefix(Self.categoryPrefix)
      || id.hasPrefix(Self.projectPrefix) || id.hasPrefix(Self.goalPrefix)
  }
}

extension AppModel {
  var needsALook: [NotificationItem] {
    NotificationsEngine.snapshot(store.state, now: store.now).needsALook.filter { $0.id != "review" }
      + [HomeViewModel.mailItem(mailOffer, mailboxes: mailbox?.mailboxes ?? [])].compactMap { $0 }
  }

  var bellCount: Int { notificationReads.unread(needsALook).count }
}

@MainActor
protocol NotificationFeed {
  func earlier(now: LocalDateTime) -> [NotificationItem]
}
