import HasalaModels

enum AppTab: Hashable {
  case home, plan, projects, review, activity, add
}

enum HomeRoute: Hashable {
  case bills
  case bill(BillID)
  case accounts
  case insights
  case sortedForYou
}

enum PlanRoute: Hashable {
  case category(CategoryID)
  case project(ProjectID)
  case projects
  case addToProject(ProjectID)
}

enum ActivityRoute: Hashable {
  case bill(BillID)
}

enum ReviewRoute: Hashable {
  case unreadMail
  case unreadTexts
}

enum TransactionRoute: Hashable {
  case category, note, rename, split, project
  case reviewReason(TxnReviewReason)
}

enum ProfileRoute: Hashable {
  case bankAlerts
  case mailbox(String)
  case addMailbox
  case connectMail(MailProviderKind)
  case accounts
  case bills
  case bill(BillID)
  case rules
  case categories
  case categoryEditor(CategoryID?)
  case categoryMove(CategoryID)
  case project(ProjectID)
  case projects
  case addToProject(ProjectID)
  case editProject(ProjectID?)
  case newProject(ProjectStarter)
  case plan
  case category(CategoryID)
  case security
  case editName
  case notifications
  case exchangeRates
  case editRate(String?)
  case privacy
  case help
  case deleteAccount
}

enum SheetRoute: Hashable, Identifiable {
  case transaction(TxnID)
  case budget(CategoryID)
  case moveMoney(to: CategoryID?)
  case profile
  case notifications
  case period
  case widgetGallery
  case widgetConfig(HomeWidgetKind, entry: String?)
  case project(ProjectID?)
  case newProject(ProjectStarter)
  case addTransaction
  case addFromEmail(TxnID)
  case search

  var id: String {
    switch self {
    case .transaction(let id): "txn.\(id)"
    case .budget(let id): "budget.\(id)"
    case .moveMoney(let id): "move.\(id ?? "assign")"
    case .profile: "profile"
    case .notifications: "notifications"
    case .period: "period"
    case .widgetGallery: "widgetGallery"
    case .widgetConfig(let kind, let entry): "widgetConfig.\(kind.rawValue).\(entry ?? "new")"
    case .project(let id): "project.\(id ?? "new")"
    case .newProject(let starter): "project.new.\(starter.name)"
    case .addTransaction: "addTransaction"
    case .addFromEmail(let id): "addFromEmail.\(id)"
    case .search: "search"
    }
  }
}

enum CoverRoute: Hashable, Identifiable {
  case review
  var id: Self { self }
}

struct ProjectStarter: Hashable {
  let name: String
  let glyph: Glyph

  static let quickStarts: [ProjectStarter] = [
    ProjectStarter(name: "Trip", glyph: .travel),
    ProjectStarter(name: "Move", glyph: .rent),
    ProjectStarter(name: "Eid gifts", glyph: .shopping),
  ]
}
