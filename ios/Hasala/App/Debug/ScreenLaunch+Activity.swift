#if HASALA_MOCKS
  import Foundation
  import HasalaMocks
  import HasalaModel
  import HasalaModels

  extension ScreenLaunch {
    static let activityScreens: [Screen] = [
      Screen("activity", scenario: "maya", prepare: shell(.activity)),
      Screen("activity.range", scenario: "maya", prepare: { graph in
        graph.app.period = Period(YearMonth(2026, 8), YearMonth(2026, 10))
        shell(.activity)(graph)
      }),
      Screen("activity.txn", scenario: "maya", prepare: shell(.activity, sheet: .transaction("carrefour"))),
      Screen("activity.category", scenario: "maya",
             prepare: shell(.activity, sheet: .transaction("lulu"), transaction: [.category])),
      Screen("activity.split", scenario: "maya", prepare: { graph in
        graph.app.perform(.split("carrefour", [
          SplitLine(id: 1, categoryID: "groceries", amount: .aed(297_00)),
          SplitLine(id: 2, categoryID: "shopping", amount: .aed(45_15), note: "Kitchen towels and batteries"),
        ]))
        graph.app.dismissToast()
        shell(.activity, sheet: .transaction("carrefour"), transaction: [.split])(graph)
      }),
      Screen("activity.filtered", scenario: "maya", prepare: { graph in
        graph.app.router.showActivity(TxnFilter(category: "dining"))
      }),
      Screen("review", scenario: "maya", prepare: shell(.review)),
      Screen("review.texts", scenario: "textsWorking", prepare: shell(.review)),
      Screen("review.pasteText", scenario: "textsWorking", prepare: { graph in
        BankTextsLaunch.pasted = MockBankTexts.sampleText
        BankTextsLaunch.openPaste = true
        shell(.review)(graph)
      }),
      Screen("review.pasteText.match", scenario: "textsWorking", prepare: { graph in
        (graph.session.services.bankTexts as? MockBankTexts)?.nextMatch = BankTextMatch(
          rowID: "sample-unread", kind: .unreadText, merchant: nil, amount: nil,
          postedAt: .now.addingTimeInterval(-2 * 86_400), fromText: true)
        BankTextsLaunch.pasted = MockBankTexts.undatedText
        BankTextsLaunch.openPaste = true
        shell(.review)(graph)
      }),
      Screen("review.pasteText.worst", scenario: "mayaWorstTexts", prepare: { graph in
        BankTextsLaunch.pasted = MockBankTexts.worstPasted
        BankTextsLaunch.openPaste = true
        shell(.review)(graph)
      }),
      Screen("review.cloudSort", scenario: "maya", prepare: { graph in
        (graph.session.services.cloudSort as? MockCloudSort)?.isOffered = true
        shell(.review)(graph)
      }),
      Screen("review.unread", scenario: "mayaUnreadMail", prepare: shell(.review)),
      Screen("review.unread.list", scenario: "mayaUnreadMail", prepare: shell(.review, review: [.unreadMail])),
      Screen("review.unread.add", scenario: "mayaUnreadMail",
             prepare: shell(.review, sheet: .addFromEmail("unread-gmail"), review: [.unreadMail])),
      Screen("review.range", scenario: "maya", prepare: { graph in
        graph.app.period = Period(YearMonth(2026, 8), YearMonth(2026, 10))
        shell(.review)(graph)
      }),
      Screen("review.deck", scenario: "maya", prepare: { graph in
        startDeck(graph, at: "apple") { $0.useSuggestion("apple") }
      }),
      Screen("review.pick", scenario: "maya", prepare: { graph in
        startDeck(graph, at: "apple") { deck in
          deck.useSuggestion("apple")
          deck.pick("lulu", .need)
        }
      }),
      Screen("review.done", scenario: "maya", prepare: { graph in
        startDeck(graph, at: "lulu", keepsToast: true) { deck in
          deck.sort("lulu", into: "groceries", alwaysUse: true, project: nil)
          deck.sort("dubai-taxi", into: "transport", alwaysUse: true, project: nil)
          deck.useSuggestion("apple")
          deck.sort("steam", into: "entertainment", alwaysUse: true, project: nil)
          deck.sort("transfer-in", into: "freelance", alwaysUse: false, project: nil)
          deck.useSuggestion("atm")
        }
      }),
      Screen("review.copy", scenario: "mayaCopy", prepare: { graph in
        startDeck(graph, at: "starbucks-copy") { _ in }
      }),
      Screen("review.samePurchase", scenario: "mayaSamePurchase", prepare: { graph in
        startDeck(graph, at: "amazon-aed") { _ in }
      }),
      Screen("review.empty", scenario: "mayaCaughtUp", prepare: shell(.review)),
      Screen("review.importing", scenario: "maya", prepare: { graph in
        mock(graph)?.importing = MailImport(state: .reading, read: 312, total: 900)
        shell(.review)(graph)
      }),
      Screen("review.cloudSort.importing", scenario: "maya", prepare: { graph in
        (graph.session.services.cloudSort as? MockCloudSort)?.isOffered = true
        mock(graph)?.importing = MailImport(state: .reading, read: 312, total: 900)
        shell(.review)(graph)
      }),
      Screen("review.empty.importing", scenario: "mayaCaughtUp", prepare: { graph in
        mock(graph)?.importing = MailImport(state: .reading, read: 312, total: 900)
        shell(.review)(graph)
      }),
      Screen("review.unread.importing", scenario: "mayaUnreadMail", prepare: { graph in
        mock(graph)?.importing = MailImport(state: .reading, read: 312, total: 900)
        shell(.review)(graph)
      }),
      Screen("review.unread.ask", scenario: "mayaUnreadMail", prepare: { graph in
        (graph.session.services.cloudSort as? MockCloudSort)?.isOffered = true
        shell(.review)(graph)
      }),
      Screen("review.unread.empty", scenario: "mayaUnreadMail", prepare: { graph in
        let waiting = graph.app.store.state.txns.filter(\.needsReview).map(\.id)
        _ = graph.app.perform(waiting.map { .categorize($0, "shopping", learnRule: false, project: nil) })
        graph.app.dismissToast()
        shell(.review)(graph)
      }),
      Screen("review.sort.deck", scenario: "maya", prepare: cloudSort(.running) { graph in
        startDeck(graph, at: "lulu") { _ in }
      }),
      Screen("review.backlog", scenario: "mayaBacklog", prepare: shell(.review)),
      Screen("review.undoLine", scenario: "mayaBacklog", prepare: { graph in
        _ = graph.app.perform(.categorize("bl-qasr-4", "groceries", learnRule: true, project: nil))
        shell(.review)(graph)
      }),
      Screen("search", scenario: "maya", prepare: shell(.home, sheet: .search)),
      Screen("search.results", scenario: "maya", prepare: { graph in
        SearchHistory.launchQuery = "carre"
        shell(.home, sheet: .search)(graph)
      }),
      Screen("search.ask", scenario: "maya", prepare: { graph in
        AskSearch.launchParser = SearchQueryParser(model: ScriptedSearchModel())
        SearchHistory.launchQuery = "How much did I spend at Carrefour in September?"
        shell(.home, sheet: .search)(graph)
      }),
      Screen("search.ask.coffee", scenario: "maya", prepare: { graph in
        AskSearch.launchParser = SearchQueryParser(model: ScriptedSearchModel())
        SearchHistory.launchQuery = "coffee this month"
        shell(.home, sheet: .search)(graph)
      }),
      Screen("search.ask.ready", scenario: "maya", prepare: { graph in
        AskSearch.launchParser = SearchQueryParser(model: ScriptedSearchModel())
        shell(.home, sheet: .search)(graph)
      }),
      Screen("search.ask.arabic", scenario: "maya", prepare: { graph in
        AskSearch.launchParser = SearchQueryParser(model: ScriptedSearchModel())
        SearchHistory.launchQuery = "كارفور"
        shell(.home, sheet: .search)(graph)
      }),
    ]

    private static func startDeck(
      _ graph: MockGraph, at card: TxnID, keepsToast: Bool = false, _ steps: @escaping (ReviewViewModel) -> Void
    ) {
      shell(.review, cover: .review)(graph)
      ReviewEntry.request(graph.app, at: card)
      let app = graph.app
      ReviewEntry.onNextSession(of: app) { deck in
        steps(deck)
        if !keepsToast { app.dismissToast() }
      }
    }
  }
#endif
