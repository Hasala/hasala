#if HASALA_MOCKS
  import CoreStore
  import CoreSync
  import Foundation
  import HasalaMocks
  import HasalaModels

  extension ScreenLaunch {
    static let homeScreens: [Screen] = [
      Screen("home", scenario: "maya"),
      Screen("home.insights", scenario: "maya", prepare: shell(.home, home: [.insights])),
      Screen("home.insights.firstDays", scenario: "firstDays", prepare: shell(.home, home: [.insights])),
      Screen("home.hidden", scenario: "maya") { graph in graph.app.toggleAmountsHidden() },
      Screen("home.notifications", scenario: "maya", prepare: shell(.home, sheet: .notifications)),
      Screen("home.allClear", scenario: "mayaCaughtUp", prepare: { graph in
        edit(graph, [.markBillPaid("axa"), .acceptBillAmount("du"), .dismissCandidate("apple-bill")])
        shell(.home, sheet: .notifications)(graph)
      }),
      Screen("home.overPace", scenario: "maya", prepare: { graph in
        edit(graph, [
          budget("groceries", 0), budget("transport", 50), budget("travel", 0), budget("shopping", 0),
          budget("entertainment", 0), budget("dining", 2_350),
        ])
      }),
      Screen("home.period", scenario: "maya", prepare: shell(.home, sheet: .period)),
      Screen("home.edit", scenario: "maya") { graph in graph.app.editingHome = true },
      Screen("home.gallery", scenario: "maya", prepare: { graph in
        graph.app.editingHome = true
        shell(.home, sheet: .widgetGallery)(graph)
      }),
      Screen("home.widgetConfig", scenario: "maya", prepare: { graph in
        graph.app.editingHome = true
        shell(.home, sheet: .widgetConfig(.categoryWatch, entry: nil))(graph)
      }),
      Screen("home.noWidgets", scenario: "maya") { graph in
        for id in graph.app.currentHomeLayout.ids { graph.app.removeWidget(id) }
      },
      Screen("home.periodRange", scenario: "maya", prepare: { graph in
        graph.app.period = Period(YearMonth(2026, 8), MayaLedger.october)
        shell(.home, sheet: .period)(graph)
      }),
      Screen("home.importing", scenario: "mailboxes2", prepare: { graph in
        mock(graph)?.importing = MailImport(state: .reading, read: 40, total: 268)
      }),
      Screen("home.finishSetup", scenario: "finishSetup", prepare: { graph in
        mock(graph)?.importing = MailImport(state: .reading, read: 40, total: 268)
      }),
      Screen("home.finishSetup.words", scenario: "finishSetup", prepare: { graph in
        graph.session.services.unseenPhrase.noteUnseen(at: .now)
        mock(graph)?.importing = MailImport(state: .reading, read: 40, total: 268)
      }),
      Screen("home.finishSetup.plan", scenario: "finishSetup") { graph in
        graph.onboarding.finishSetupModel().setPlan()
      },
      Screen("home.finishSetup.notifications", scenario: "finishSetup") { graph in
        graph.onboarding.finishSetupModel().askNotifications()
      },
      Screen("home.noAlerts", scenario: "noAlerts"),
      Screen("home.uploadsStuck", scenario: "maya", prepare: { graph in
        var status = CoreSync.SyncStatus()
        status.latch = .hardStop
        graph.app.syncNotices.update(status)
        graph.app.syncNotices.eraseThisIPhone = {}
      }),
      Screen("home.setAside", scenario: "maya", prepare: { graph in
        var status = CoreSync.SyncStatus()
        status.integrityAlarms = 1
        status.rowAlarms = 1
        graph.app.syncNotices.update(status)
      }),
      Screen("home.noAlerts.sheet", scenario: "noAlerts") { graph in
        graph.onboarding.finishSetupModel().openNoAlerts()
      },
      Screen("home.noAlerts.found", scenario: "noAlerts", prepare: { graph in
        mock(graph)?.total = 268
      }),
      Screen("home.september", scenario: "maya", prepare: { graph in
        graph.app.period = .month(YearMonth(2026, 9))
      }),
      Screen("home.range", scenario: "maya", prepare: { graph in
        graph.app.period = Period(YearMonth(2026, 8), MayaLedger.october)
      }),
      Screen("home.allTime", scenario: "mayaRange", prepare: { graph in
        graph.app.choose(.allTime)
      }),
      Screen("home.sortedForYou", scenario: "mayaBacklog", prepare: { graph in
        sortQasr(graph)
        shell(.home)(graph)
      }),
      Screen("home.sortedForYou.list", scenario: "mayaBacklog", prepare: { graph in
        sortQasr(graph)
        shell(.home, home: [.sortedForYou])(graph)
      }),
      Screen("home.overBudget", scenario: "maya", prepare: { graph in
        edit(graph, [budget("travel", 0), budget("rent", 0)])
      }),
    ]

    private static func budget(_ category: CategoryID, _ dirhams: Int64) -> LedgerEdit {
      .setBudget(category, MayaLedger.october, .aed(dirhams * 100))
    }

    @MainActor private static func sortQasr(_ graph: MockGraph) {
      edit(graph, [.categorize("bl-qasr-1", "groceries", learnRule: true, project: nil)])
    }

    @MainActor private static func edit(_ graph: MockGraph, _ edits: [LedgerEdit]) {
      for e in edits { _ = try? graph.app.store.apply(e) }
    }
  }
#endif
