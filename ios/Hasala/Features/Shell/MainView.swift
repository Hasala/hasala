import HasalaDesign
import HasalaModels
import HasalaWidgetData
import SwiftUI

struct MainView: View {
  @State private var app: AppModel
  @State private var home: HomeViewModel
  @State private var plan: PlanViewModel
  @State private var activity: ActivityViewModel
  @Environment(\.scenePhase) private var scenePhase

  init(app: AppModel) {
    _app = State(initialValue: app)
    _home = State(initialValue: HomeViewModel(app: app))
    _plan = State(initialValue: PlanViewModel(app: app))
    _activity = State(initialValue: ActivityViewModel(app: app))
  }

  private var selection: Binding<AppTab> {
    Binding(
      get: { app.router.tab },
      set: { tab in
        if tab == .add {
          app.router.open(.addTransaction)
        } else if tab == app.router.tab {
          app.router.popToRoot(tab)
        } else {
          app.router.tab = tab
        }
      })
  }

  var body: some View {
    TabView(selection: selection) {
      Tab("Home", image: "TabHome", value: AppTab.home) {
        HomeView(app: app, model: home)
      }
      if BuildSurface.showsPlanTab {
        Tab("Plan", image: "TabPlan", value: AppTab.plan) {
          PlanView(app: app, model: plan)
        }
      } else {
        Tab("Projects", image: "TabProjects", value: AppTab.projects) {
          ProjectsTabView(app: app)
        }
      }
      Tab("Review", image: "TabReview", value: AppTab.review) {
        ReviewTabView(app: app)
      }
      .badge(app.reviewCount > 99 ? Text("99+") : app.reviewCount > 0 ? Text("\(app.reviewCount)") : nil)
      Tab("Activity", image: "TabActivity", value: AppTab.activity) {
        ActivityView(app: app, model: activity)
      }
      Tab("Add a transaction", systemImage: "plus", value: AppTab.add, role: .search) {
        Color.clear
      }
    }
    .tabBarMinimizeBehavior(.never)
    .tabViewSearchActivation(.searchTabSelection)
    .onAppear {
      app.router.clearPresentation()
      applyPendingLaunch()
      openPendingWidgetLink()
    }
    .onChange(of: WidgetLinkInbox.shared.pending) { _, _ in openPendingWidgetLink() }
    .onChange(of: scenePhase, initial: true) { _, phase in
      app.sceneChanged(onScreen: phase != .background)
      if phase == .active { app.bankTexts?.refresh() }
    }
    .alert(
      "Bank texts while locked", isPresented: lockedNoticeShowing,
      presenting: app.bankTexts?.lockedNotice
    ) { _ in
      Button("Paste a text") {
        app.bankTexts?.lockedNoticeShown()
        app.router.tab = .review
        app.router.pasteBankText = true
      }
      .accessibilityIdentifier("lockedTexts.paste")
      Button("OK", role: .cancel) { app.bankTexts?.lockedNoticeShown() }
        .accessibilityIdentifier("lockedTexts.ok")
    } message: { count in
      Text(BankTexts.lockedNoticeLine(count))
    }
    .sheet(isPresented: Self.setAsideShowing(app)) {
      SetAsideSheet()
    }
    .sheet(item: Bindable(app.router).sheet, onDismiss: { app.router.sheetDismissed() }) { route in
      switch route {
      case .transaction(let id):
        TransactionHost(app: app, id: id)
      case .budget(let id):
        BudgetHost(app: app, category: id)
          .presentationDetents([.large])
      case .moveMoney(let id):
        MoveMoneyHost(app: app, category: id)
      case .profile:
        ProfileSheet(app: app)
      case .notifications:
        NotificationsSheet(app: app)
      case .period:
        PeriodSheet(app: app)
      case .widgetGallery:
        WidgetGallerySheet(app: app)
      case .widgetConfig(let kind, let entry):
        WidgetConfigSheet(app: app, kind: kind, entry: entry)
      case .project(let id):
        ProjectEditorSheet(app: app, project: id)
      case .newProject(let starter):
        ProjectEditorSheet(app: app, project: nil, starter: starter)
      case .addTransaction:
        AddTransactionHost(app: app)
      case .addFromEmail(let id):
        AddTransactionHost(app: app, resolving: id)
      case .search:
        SearchView(app: app)
      }
    }
    .fullScreenCover(item: Bindable(app.router).cover) { cover in
      switch cover {
      case .review: ReviewCover(app: app)
      }
    }
  }

  static func setAsideShowing(_ app: AppModel) -> Binding<Bool> {
    Binding(
      get: { app.syncNotices.setAside > 0 && app.router.sheet == nil && app.router.cover == nil },
      set: { if !$0, app.router.sheet == nil, app.router.cover == nil { app.syncNotices.acknowledgeSetAside() } })
  }

  private var lockedNoticeShowing: Binding<Bool> {
    Binding(
      get: { app.bankTexts?.lockedNotice != nil && app.router.sheet == nil && app.router.cover == nil },
      set: { if !$0 { app.bankTexts?.lockedNoticeShown() } })
  }

  private func openPendingWidgetLink() {
    guard let link = WidgetLinkInbox.shared.pending else { return }
    WidgetLinkInbox.shared.pending = nil
    app.open(link)
  }

  private func applyPendingLaunch() {
    #if HASALA_MOCKS
      guard let launch = app.router.pendingLaunch else { return }
      app.router.pendingLaunch = nil
      app.router.profile = launch.profile
      app.router.overProfile = launch.overProfile
      app.router.transaction = launch.transaction
      app.router.sheet = launch.sheet
      app.router.cover = launch.cover
    #endif
  }
}

struct TransactionHost: View {
  let app: AppModel
  @State private var model: TransactionViewModel

  init(app: AppModel, id: TxnID, close: (() -> Void)? = nil) {
    self.app = app
    _model = State(initialValue: TransactionViewModel(app: app, id: id, close: close))
  }

  var body: some View { TransactionSheet(app: app, model: model) }
}

extension View {
  func nestedTransactionSheet<Item: Identifiable>(item: Binding<Item?>, app: AppModel) -> some View where Item.ID == TxnID {
    sheet(item: item, onDismiss: { app.router.transaction = [] }) { opened in
      TransactionHost(app: app, id: opened.id) { item.wrappedValue = nil }
    }
  }
}

struct BudgetHost: View {
  @State private var model: BudgetSheetViewModel

  init(app: AppModel, category: CategoryID) {
    _model = State(initialValue: BudgetSheetViewModel(app: app, category: category))
  }

  var body: some View { BudgetEditSheet(model: model) }
}

struct MoveMoneyHost: View {
  @State private var model: BudgetSheetViewModel

  init(app: AppModel, category: CategoryID?) {
    _model = State(initialValue: BudgetSheetViewModel(app: app, category: category))
  }

  var body: some View { MoveMoneySheet(model: model) }
}

private struct ReviewCover: View {
  @Bindable var app: AppModel
  @State private var model: ReviewViewModel

  init(app: AppModel) {
    self.app = app
    _model = State(initialValue: ReviewViewModel(app: app))
  }

  var body: some View { ReviewDeckView(app: app, model: model) }
}

enum TabBadge {
  static let color = HColor.badgeCount

  @MainActor static func apply() {
    UITabBarItem.appearance().badgeColor = UIColor(color)
  }
}
