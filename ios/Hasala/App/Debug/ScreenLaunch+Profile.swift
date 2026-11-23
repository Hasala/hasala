#if HASALA_MOCKS
  import Foundation

  extension ScreenLaunch {
    static let profileScreens: [Screen] = [
      Screen("profile", scenario: "passkeyUser", prepare: profile([])),
      Screen("profile.signInAgain", scenario: "gmailReconnect", prepare: profile([])),
      Screen("profile.passwordOnly", scenario: "passwordOnly", prepare: profile([])),
      Screen("profile.hidden", scenario: "mayaHidden", prepare: profile([])),
      Screen("profile.rules", scenario: "maya", prepare: profile([.rules])),
      Screen("profile.categories", scenario: "maya", prepare: profile([.categories])),
      Screen("profile.rulesLearned", scenario: "maya", drive: { graph in
        graph.app.perform(.categorize("lulu", "groceries", learnRule: true, project: nil))
      }, prepare: profile([.rules])),
      Screen("profile.categoryNew", scenario: "maya", prepare: profile([.rules, .categoryEditor(nil)])),
      Screen("profile.categoryEdit", scenario: "maya", prepare: profile([.rules, .categoryEditor("dining")])),
      Screen("profile.categoryCustom", scenario: "maya", prepare: profile([.rules, .categoryEditor("emergency-fund")])),
      Screen("profile.delete", scenario: "passkeyUser", prepare: profile([.deleteAccount])),
      Screen("profile.help", scenario: "maya", prepare: profile([.help])),
      Screen("profile.bills", scenario: "maya", prepare: profile([.bills])),
      Screen("profile.accounts", scenario: "maya", prepare: profile([.accounts])),
      Screen("profile.cloudSort", scenario: "maya", prepare: cloudSort(.done, then: profile([]))),
      Screen("profile.cloudConsent", scenario: "maya", prepare: profile([])),
      Screen("profile.exchangeRates", scenario: "maya", prepare: profile([.exchangeRates])),
      Screen("profile.editName", scenario: "passkeyUser", prepare: profile([.editName])),
      Screen("bills", scenario: "maya", prepare: shell(.home, home: [.bills])),
      Screen("bills.axa", scenario: "maya", prepare: shell(.home, home: [.bills, .bill("axa")])),
      Screen("bills.du", scenario: "maya", prepare: shell(.home, home: [.bills, .bill("du")])),
      Screen("bills.dewa", scenario: "maya", prepare: shell(.home, home: [.bills, .bill("dewa")])),
      Screen("accounts", scenario: "maya", prepare: shell(.home, home: [.accounts])),
    ]

    @MainActor private static var cloudConsentPending =
      ProcessInfo.processInfo.arguments.launchValue(after: argument) == "profile.cloudConsent"

    @MainActor static func applyCloudConsentLaunch(_ consent: MerchantSuggestionsConsent) async {
      guard cloudConsentPending else { return }
      cloudConsentPending = false
      try? await Task.sleep(for: .milliseconds(700))
      consent.request(true)
    }
  }
#endif
