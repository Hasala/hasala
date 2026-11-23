#if HASALA_MOCKS
  import Foundation

  extension ScreenLaunch {
    static let planScreens: [Screen] = [
      Screen("plan", scenario: "maya", prepare: planShell()),
      Screen("plan.dining", scenario: "maya", prepare: planShell([.category("dining")])),
      Screen("plan.budget", scenario: "maya", prepare: planShell([.category("dining")], sheet: .budget("dining"))),
      Screen("plan.move", scenario: "maya",
             prepare: planShell([.category("groceries")], sheet: .moveMoney(to: "groceries"))),
      Screen("plan.project", scenario: "maya", prepare: projectsShell([.project("japan")])),
      Screen("plan.assign", scenario: "maya", prepare: planShell(sheet: .moveMoney(to: nil))),
      Screen("plan.groceries", scenario: "maya", prepare: planShell([.category("groceries")])),
      Screen("plan.rent", scenario: "maya", prepare: planShell([.category("rent")])),
      Screen("plan.dining.hidden", scenario: "mayaHidden", prepare: planShell([.category("dining")])),
      Screen("plan.projects", scenario: "maya", prepare: projectsShell()),
    ]

    static func planShell(_ path: [PlanRoute] = [], sheet: SheetRoute? = nil) -> @MainActor (MockGraph) -> Void {
      if BuildSurface.showsPlanTab { return shell(.plan, plan: path, sheet: sheet) }
      return shell(.home, sheet: .profile, profile: [.plan] + path.map(profileRoute), overProfile: sheet)
    }

    static func projectsShell(_ path: [PlanRoute] = []) -> @MainActor (MockGraph) -> Void {
      if BuildSurface.showsPlanTab { return shell(.plan, plan: path.isEmpty ? [.projects] : path) }
      return shell(.projects, projects: path)
    }

    private static func profileRoute(_ route: PlanRoute) -> ProfileRoute {
      switch route {
      case .category(let id): .category(id)
      case .project(let id): .project(id)
      case .projects: .projects
      case .addToProject(let id): .addToProject(id)
      }
    }
  }
#endif
