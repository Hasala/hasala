#if HASALA_MOCKS
  import Foundation
  import HasalaModels

  extension ScreenLaunch {
    static let mailScreens: [Screen] = [
      Screen("mail.connectGmail", scenario: "setupEmail") { _ = setupModel($0) },
      Screen("mail.connectOutlook", scenario: "setupEmail") { graph in
        setupModel(graph).pickProvider(.outlook)
      },
      Screen("mail.permissionMissing", scenario: "setupEmail") { graph in
        mock(graph)?.gmailPermissionMissing = true
        await setupModel(graph).connectMail(.gmail)
      },
      Screen("mail.errorAdmin", scenario: "outlookAdmin") { await setupOutlookFails($0) },
      Screen("mail.errorCancelled", scenario: "outlookCancelled") { await setupOutlookFails($0) },
      Screen("mail.connectGmail.review", scenario: "reviewAccount") { _ = setupModel($0) },
      Screen("bankAlerts", scenario: "mailboxes2", prepare: profile([.bankAlerts])),
      Screen("bankAlerts.oneGmail", scenario: "passkeyUser", prepare: profile([.bankAlerts])),
      Screen("bankAlerts.texts", scenario: "textsWorking", prepare: profile([.bankAlerts])),
      Screen("bankAlerts.texts.waiting", scenario: "textsWaiting", prepare: profile([.bankAlerts])),
      Screen("bankAlerts.texts.paste", scenario: "textsWorking", prepare: { graph in
        BankTextsLaunch.pasted = MockBankTexts.sampleText
        profile([.bankAlerts])(graph)
      }),
      Screen("bankAlerts.emailOrTexts", scenario: "gmailTexts", prepare: profile([.bankAlerts])),
      Screen("bankAlerts.emailIgnored", scenario: "gmailTexts", prepare: { graph in
        bankTexts(graph)?.ignoredLast30Days = 3
        bankTexts(graph)?.lastRan = .now.addingTimeInterval(-3_600)
        profile([.bankAlerts])(graph)
      }),
      Screen("mail.disconnectTexts", scenario: "gmailTexts", prepare: { graph in
        bankTexts(graph)?.ignoredLast30Days = 3
        bankTexts(graph)?.lastRan = .now.addingTimeInterval(-3_600)
        MailLaunch.disconnectAlert = "gmail-1"
        profile([.bankAlerts, .mailbox("gmail-1")])(graph)
      }),
      Screen("bankAlerts.unlisted", scenario: "mailboxes2", prepare: { graph in
        mock(graph)?.unlistedSenders = ["alerts.notifications.emiratesnbd-mail.example.com", "e.example.ae"]
        profile([.bankAlerts])(graph)
      }),
      Screen("bankAlerts.none", scenario: "noMailbox", prepare: profile([.bankAlerts])),
      Screen("bankAlerts.refused", scenario: "noMailbox", prepare: { graph in
        mock(graph)?.connectRefusal = .sampleData
        profile([.bankAlerts])(graph)
      }),
      Screen("bankAlerts.refusedReview", scenario: "noMailbox", prepare: { graph in
        mock(graph)?.connectRefusal = .reviewAccount
        profile([.bankAlerts])(graph)
      }),
      Screen("bankAlerts.syncing", scenario: "passkeyUser", prepare: { graph in
        mock(graph)?.step = .seconds(2)
        MailLaunch.connectOnAppear = .outlook
        profile([.bankAlerts, .addMailbox, .connectMail(.outlook)])(graph)
      }),
      Screen("bankAlerts.signIn", scenario: "outlookSignIn", prepare: profile([.bankAlerts])),
      Screen("bankAlerts.signInNoMailbox", scenario: "outlookSignIn", prepare: { graph in
        mock(graph)?.outlookNoMailbox = true
        profile([.bankAlerts])(graph)
      }),
      Screen("bankAlerts.signInOtherAddress", scenario: "outlookSignIn", prepare: { graph in
        mock(graph)?.signInAgainReads = "maya.other@example.com"
        profile([.bankAlerts])(graph)
      }),
      Screen("mail.detailSignInOtherAddress", scenario: "outlookSignIn", prepare: { graph in
        mock(graph)?.signInAgainReads = "maya.other@example.com"
        profile([.bankAlerts, .mailbox("outlook-1")])(graph)
      }),
      Screen("mail.add", scenario: "passkeyUser", prepare: profile([.bankAlerts, .addMailbox])),
      Screen("mail.add.signIn", scenario: "outlookSignIn", prepare: profile([.bankAlerts, .addMailbox])),
      Screen("mail.add.gmail", scenario: "noMailbox", prepare: profile([.bankAlerts, .addMailbox, .connectMail(.gmail)])),
      Screen("mail.profile.gmail", scenario: "noMailbox", prepare: profile([.connectMail(.gmail)])),
      Screen("mail.add.outlook", scenario: "passkeyUser",
             prepare: profile([.bankAlerts, .addMailbox, .connectMail(.outlook)])),
      Screen("mail.add.errorAdmin", scenario: "passkeyUser", prepare: { graph in
        mock(graph)?.outlookAdmin = true
        MailLaunch.connectOnAppear = .outlook
        profile([.bankAlerts, .addMailbox, .connectMail(.outlook)])(graph)
      }),
      Screen("mail.add.errorCancelled", scenario: "passkeyUser", prepare: { graph in
        mock(graph)?.outlookCancelled = true
        MailLaunch.connectOnAppear = .outlook
        profile([.bankAlerts, .addMailbox, .connectMail(.outlook)])(graph)
      }),
      Screen("mail.add.errorNoMailbox", scenario: "passkeyUser", prepare: { graph in
        mock(graph)?.outlookNoMailbox = true
        MailLaunch.connectOnAppear = .outlook
        profile([.bankAlerts, .addMailbox, .connectMail(.outlook)])(graph)
      }),
      Screen("mail.add.errorNoMailboxGmail", scenario: "noMailbox", prepare: { graph in
        mock(graph)?.gmailNoMailbox = true
        MailLaunch.connectOnAppear = .gmail
        profile([.bankAlerts, .addMailbox, .connectMail(.gmail)])(graph)
      }),
      Screen("mail.detail", scenario: "mailboxes2", prepare: profile([.bankAlerts, .mailbox("outlook-1")])),
      Screen("mail.detailSignIn", scenario: "outlookSignIn", prepare: profile([.bankAlerts, .mailbox("outlook-1")])),
      Screen("mail.disconnect", scenario: "mailboxes2", prepare: { graph in
        MailLaunch.disconnectAlert = "outlook-1"
        profile([.bankAlerts, .mailbox("outlook-1")])(graph)
      }),
      Screen("mail.disconnectGmail", scenario: "passkeyUser", prepare: { graph in
        MailLaunch.disconnectAlert = "gmail-1"
        profile([.bankAlerts, .mailbox("gmail-1")])(graph)
      }),
      Screen("mail.disconnected", scenario: "mailboxes2", drive: { graph in
        try? await mock(graph)?.disconnect("outlook-1")
      }, prepare: profile([.bankAlerts])),
    ]

    static func mock(_ graph: MockGraph) -> MockMailbox? {
      graph.session.services.mailbox as? MockMailbox
    }

    static func setupOutlookFails(_ graph: MockGraph) async {
      let model = setupModel(graph)
      model.pickProvider(.outlook)
      await model.connectMail(.outlook)
    }
  }

  @MainActor
  enum MailLaunch {
    static var connectOnAppear: MailProviderKind?
    static var disconnectAlert: String?

    static func takeConnect(_ provider: MailProviderKind) -> Bool {
      guard connectOnAppear == provider else { return false }
      connectOnAppear = nil
      return true
    }

    static func takeDisconnect(_ mailboxID: String) -> Bool {
      guard disconnectAlert == mailboxID else { return false }
      disconnectAlert = nil
      return true
    }
  }
#endif
