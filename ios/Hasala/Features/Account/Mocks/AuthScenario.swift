#if HASALA_MOCKS
  import Foundation
  import HasalaMocks
  import HasalaModels

  enum AuthScenario: String, CaseIterable {
    case newUser
    case passkeyUser
    case passwordOnly
    case signInPassword
    case unlockPasswordOnly
    case unlockWithPasskey
    case frozen
    case frozenOperator
    case frozenNeedsUs
    case frozenPasskeyOnly
    case setupBank
    case reviewAccount
    case noPasscode
    case resetApproval
    case relaunchInterrupted
    case relaunchSignedIn
    case mayaSample
    case gmailSkipped
    case gmailReconnect
    case setupEmail
    case mailboxes2
    case outlookSignIn
    case outlookAdmin
    case outlookCancelled
    case noMailbox
    case outlookReconnect
    case gmailLinked
    case noBanks
    case finishSetup
    case noAlerts
    case setupTexts
    case textsWorking
    case textsWaiting
    case gmailTexts
    case mayaTexts
    case mayaWorst
    case mayaWorstTexts
    case mayaEmpty
    case mayaOne
    case mayaHuge

    static func fromLaunchArguments(_ arguments: [String]) -> AuthScenario? {
      guard let i = arguments.firstIndex(of: "-HasalaScenario"), i + 1 < arguments.count else { return nil }
      return AuthScenario(rawValue: arguments[i + 1])
    }

    @MainActor
    static func session(
      for scenario: AuthScenario?, releaseSurface: Bool = !BuildSurface.showsUnfinished
    ) -> AccountSession {
      let session = makeSession(for: scenario, releaseSurface: releaseSurface)
      if releaseSurface {
        if let mock = session.account as? MockAccountService { mock.capabilities = .beta }
        if let mailbox = session.services.mailbox as? MockMailbox { mailbox.holdOneLink() }
      }
      return session
    }

    static func setupFacts(for scenario: AuthScenario?, texts: (any BankTextsConnecting)? = nil) -> OnboardingStep.Facts {
      var facts = OnboardingStep.Facts(hasSession: true, keysReady: true)
      facts.textsChosen = BankTexts.setUpHere(texts)
      switch scenario {
      case .setupEmail, .outlookAdmin, .outlookCancelled: facts.banksChosen = true
      default: break
      }
      return facts
    }

    static func mailboxes(for scenario: AuthScenario?) -> [MailboxSnapshot] {
      switch scenario {
      case nil, .passkeyUser, .passwordOnly, .mayaSample, .resetApproval, .frozen, .frozenOperator, .frozenNeedsUs,
        .frozenPasskeyOnly,
        .unlockPasswordOnly, .unlockWithPasskey, .relaunchSignedIn, .gmailLinked:
        [MockMailbox.gmail]
      case .outlookReconnect: [MockMailbox.needingSignIn(MockMailbox.outlook)]
      case .gmailReconnect: [MockMailbox.needingSignIn(MockMailbox.gmail)]
      case .mailboxes2, .mayaWorst, .mayaHuge: [MockMailbox.gmail, MockMailbox.outlook]
      case .mayaOne, .mayaEmpty: [MockMailbox.gmail]
      case .outlookSignIn: [MockMailbox.gmail, MockMailbox.needingSignIn(MockMailbox.outlook)]
      case .finishSetup, .noAlerts, .gmailTexts: [MockMailbox.gmail]
      case .gmailSkipped, .noMailbox, .noBanks, .newUser, .noPasscode, .signInPassword, .setupBank, .reviewAccount,
        .setupEmail, .outlookAdmin, .outlookCancelled, .relaunchInterrupted, .setupTexts, .textsWorking, .textsWaiting,
        .mayaTexts, .mayaWorstTexts:
        []
      }
    }

    static func startsWithoutPlan(_ scenario: AuthScenario?) -> Bool {
      switch scenario {
      case .newUser, .noPasscode, .setupBank, .reviewAccount, .setupEmail, .outlookAdmin, .outlookCancelled,
        .relaunchInterrupted, .finishSetup, .noAlerts, .setupTexts:
        true
      default:
        false
      }
    }

    @MainActor
    static func bankTexts(for scenario: AuthScenario?, mailbox: MockMailbox? = nil) -> MockBankTexts? {
      let lane: MockBankTexts? =
        switch scenario {
        case .setupTexts, .gmailTexts: MockBankTexts(mailbox: mailbox)
        case .textsWorking, .mayaTexts: MockBankTexts.working(mailbox: mailbox)
        case .textsWaiting: MockBankTexts.waiting(mailbox: mailbox)
        case .mayaWorstTexts: MockBankTexts.worst(mailbox: mailbox)
        default: nil
        }
      let arguments = ProcessInfo.processInfo.arguments
      if let i = arguments.firstIndex(of: "-HasalaLockedTexts"), i + 1 < arguments.count, let n = Int(arguments[i + 1]) {
        lane?.lockedNotice = n
      }
      return lane
    }

    @MainActor
    private static func makeSession(for scenario: AuthScenario?, releaseSurface: Bool) -> AccountSession {
      let launch = ProcessInfo.processInfo.arguments
      MockAccountService.identity = ScreenLaunch.isMockLaunch(launch) ? MockIdentity.resolve(scenario, launch) : .maya
      let mailbox = MockMailbox(offersSampleData: scenario == .reviewAccount, mailboxes: mailboxes(for: scenario))
      mailbox.sortsWithModel = !releaseSurface
      mailbox.outlookAdmin = scenario == .outlookAdmin
      mailbox.outlookCancelled = scenario == .outlookCancelled
      if scenario == .noBanks { mailbox.banks = [] }
      if scenario == .noAlerts { mailbox.total = 0 }
      let fresh = startsWithoutPlan(scenario)
      let setup = MockSetupAuthoring(
        saved: fresh ? SetupReadBack() : SetupReadBack(incomeMinor: 25_000_00, payday: 28, split: StartingPlan()))
      setup.choseBanks = { [weak mailbox] in mailbox?.banks = $0 }
      if MockAccountService.identity.person == .worst { setup.requests = MockSetupAuthoring.worstRequests }
      let cloudSort = MockCloudSort()
      let arguments = ProcessInfo.processInfo.arguments
      let unseenPhrase = InMemoryUnseenPhrase()
      if arguments.contains("-HasalaPhraseUnseen") { unseenPhrase.noteUnseen(at: .now) }
      let manualEntry = ManualEntryChoice()
      let bankTexts = bankTexts(for: scenario, mailbox: mailbox)
      func services(_ account: MockAccountService) -> AccountServices {
        account.passkeyPRF = !arguments.contains("-HasalaPasskeyNoPRF")
        account.passkeySynced = !arguments.contains("-HasalaPasskeyNotSynced")
        return AccountServices(
          account: account, mailbox: mailbox, setup: setup,
          notifications: MockNotificationPermission(answered: !fresh), hasPasscode: { scenario != .noPasscode },
          cloudSort: cloudSort, unseenPhrase: unseenPhrase, manualEntry: manualEntry, bankTexts: bankTexts)
      }
      switch scenario {
      case nil, .passkeyUser, .gmailSkipped, .gmailReconnect, .mailboxes2, .outlookSignIn, .noMailbox, .noBanks,
        .outlookReconnect, .gmailLinked, .finishSetup, .noAlerts, .textsWorking, .textsWaiting, .gmailTexts, .mayaTexts,
        .mayaWorst, .mayaWorstTexts, .mayaEmpty, .mayaOne, .mayaHuge:
        return AccountSession(services: services(MockAccountService(existing: .passkey, signedIn: true)), phase: .ready)
      case .mayaSample:
        let session = AccountSession(services: services(MockAccountService(existing: .passkey, signedIn: true)),
                                     phase: .ready)
        session.reviewAccount = true
        return session
      case .resetApproval:
        let account = MockAccountService(existing: .passkey, signedIn: true)
        account.pendingReset = PendingReset(
          id: "reset-1", askedAgo: MockAccountService.identity.resetAskedAgo, email: MockAccountService.existingEmail)
        return AccountSession(services: services(account), phase: .ready)
      case .passwordOnly:
        return AccountSession(services: services(MockAccountService(existing: .passwordOnly, signedIn: true)),
                              phase: .ready)
      case .newUser, .noPasscode:
        return AccountSession(services: services(MockAccountService(existing: .none)), phase: .signedOut)
      case .signInPassword:
        return AccountSession(services: services(MockAccountService(existing: .passwordOnly)), phase: .signedOut)
      case .unlockPasswordOnly:
        return AccountSession(services: services(MockAccountService(existing: .passwordOnly, signedIn: true)),
                              phase: .needsUnlock(passkeyCanUnlock: false))
      case .unlockWithPasskey:
        return AccountSession(services: services(MockAccountService(existing: .passkey, signedIn: true)),
                              phase: .needsUnlock(passkeyCanUnlock: true))
      case .frozen, .frozenOperator, .frozenNeedsUs, .frozenPasskeyOnly:
        let account = MockAccountService(existing: .passkey, signedIn: true)
        let info = FreezeInfo(
          by: scenario == .frozenOperator ? .operator : .holder, when: MockAccountService.identity.freezeWhen,
          holderCanLift: scenario != .frozenNeedsUs, hasPassword: scenario == .frozenPasskeyOnly ? false : nil)
        account.freezeForScenario(info)
        return AccountSession(services: services(account), phase: .frozen(info))
      case .relaunchInterrupted, .relaunchSignedIn:
        let account = MockAccountService(existing: .passkey, signedIn: true)
        account.resumeOutcome = scenario == .relaunchInterrupted ? .needsKeys : .needsUnlock(passkeyCanUnlock: true)
        return AccountSession(services: services(account), phase: .checking)
      case .setupBank, .reviewAccount, .setupTexts:
        return AccountSession(services: services(MockAccountService(existing: .passkey, signedIn: true)),
                              phase: .onboarding)
      case .setupEmail, .outlookAdmin, .outlookCancelled:
        return AccountSession(services: services(MockAccountService(existing: .passkey, signedIn: true)),
                              phase: .onboarding)
      }
    }
  }

  @MainActor
  struct MockIdentity {
    var person: MockPerson
    var passkeys: [PasskeyRow]
    var devices: [DeviceRow]
    var lastSignIn: String
    var phraseConfirmed: String
    var passwordChanged: String?
    var freezeWhen: String
    var resetAskedAgo: String
    var gmailMeta: String
    var outlookMeta: String
    var outlookKind: String?
    var outlookNote: String?
    var outlookConnectedOn: String?
    var gmailLastChecked: String?
    var lastEmails: [SupportedBank: String]
    var monthRead: MonthRead
    var unreadable: [UnreadableMail]
    var impacts: [String: MailboxDisconnectImpact]
    var unlistedSenders: [String] = []
    var signInAgainReads: String?

    static let argument = "-HasalaIdentity"

    static let thisPhone = DeviceRow(
      id: "ios-this", title: "This iPhone", detail: "iPhone 16 Pro · Dubai · Active now", isThisDevice: true)

    static let mayaPasskey = PasskeyRow(
      id: "pk-1", provider: "iCloud Keychain", detail: "Added 11 Sep · Used today", isThisCredential: true)

    static let maya = MockIdentity(
      person: .maya,
      passkeys: [
        mayaPasskey,
        PasskeyRow(id: "pk-2", provider: "Work iPad", detail: "Other Apple Account · 2 Oct", isThisCredential: false),
      ],
      devices: [
        thisPhone,
        DeviceRow(id: "ios-other", title: "Maya\u{2019}s iPad", detail: "iPad Air · Dubai · 2 days ago",
                  isThisDevice: false, isTablet: true),
      ],
      lastSignIn: "today at 09:12, here", phraseConfirmed: "Shown 11 Sep", passwordChanged: "Changed 3 Oct",
      freezeWhen: "on Sun 11 Oct at 21:20", resetAskedAgo: "1 minute ago", gmailMeta: "Checked 4 min ago",
      outlookMeta: "Checked 1 h ago", outlookKind: "Personal Microsoft", outlookNote: nil, outlookConnectedOn: "2 Oct",
      gmailLastChecked: "Sat 10 Oct, 13:36", lastEmails: [.enbd: "4 min ago", .dib: "2 h ago"],
      monthRead: MonthRead(count: 214, month: "October"),
      unreadable: [UnreadableMail(kind: "Debit card alert", provider: .gmail, day: "Thu 8 Oct")],
      impacts: [
        "gmail-1": MailboxDisconnectImpact(transactions: 42, edited: 3),
        "outlook-1": MailboxDisconnectImpact(transactions: 12, edited: 0),
      ])

    static var worst: MockIdentity {
      var id = maya
      id.person = .worst
      id.passkeys = [
        mayaPasskey,
        PasskeyRow(id: "pk-2", provider: "Microsoft Password Manager",
                   detail: "Other Apple Account · Edge on Windows · 2 Oct", isThisCredential: false),
        PasskeyRow(id: "pk-3", provider: "1Password", detail: "Added 2 Oct", isThisCredential: false),
      ]
      id.devices = [
        thisPhone,
        DeviceRow(id: "ios-ar", title: "عبد الرحمن\u{2019}s iPad Pro",
                  detail: "iPad Pro 13-inch (M4) · Ras Al Khaimah · 3 weeks ago", isThisDevice: false, isTablet: true),
        DeviceRow(id: "ios-se", title: "Konstantin\u{2019}s iPhone SE", detail: "iPhone SE · Abu Dhabi · 11 months ago",
                  isThisDevice: false),
      ]
      id.lastSignIn = "yesterday at 23:47 in Ras Al Khaimah"
      id.phraseConfirmed = "Shown 11 Sep 2025"
      id.passwordChanged = "Changed 3 Oct 2025"
      id.freezeWhen = "on Thu 12 Dec at 08:05"
      id.resetAskedAgo = "14 minutes ago"
      id.gmailMeta = "Checked on 12 Sep 2025"
      id.outlookMeta = "Checked on 12 Sep 2025"
      id.outlookKind = "Work or school"
      id.outlookNote = "Microsoft says this account has no mailbox Hasala can read. Sign in with another account."
      id.outlookConnectedOn = nil
      id.gmailLastChecked = nil
      id.lastEmails = [.enbd: "on 12 Sep 2025", .dib: "just now"]
      id.monthRead = MonthRead(count: 1_284, month: "September")
      id.unreadable = Array(
        repeating: UnreadableMail(kind: "Credit card statement ready", provider: .outlook, day: "Wed 30 Sep"), count: 12)
      id.impacts = [
        "gmail-1": MailboxDisconnectImpact(transactions: 1_284, edited: 37),
        "outlook-1": MailboxDisconnectImpact(transactions: 12_840, edited: 0),
      ]
      id.unlistedSenders = ["alerts.notifications.emiratesnbd-mail.example.com", "e.example.ae"]
      id.signInAgainReads = MockPerson.huge.email
      return id
    }

    static var one: MockIdentity {
      var id = maya
      id.person = .one
      id.passkeys = [mayaPasskey]
      id.devices = [thisPhone]
      id.lastEmails = [.dib: "1 min ago"]
      id.monthRead = MonthRead(count: 1, month: "May")
      id.unreadable = [UnreadableMail(kind: "Debit card alert", provider: .gmail, day: "Fri 9 Oct")]
      id.impacts = [
        "gmail-1": MailboxDisconnectImpact(transactions: 1, edited: 1),
        "outlook-1": MailboxDisconnectImpact(transactions: 1, edited: 0),
      ]
      id.unlistedSenders = ["e.example.ae"]
      return id
    }

    static var empty: MockIdentity {
      var id = maya
      id.passkeys = [mayaPasskey]
      id.devices = [thisPhone]
      id.lastEmails = [:]
      id.monthRead = MonthRead(count: 0, month: "October")
      id.unreadable = []
      id.impacts = [
        "gmail-1": MailboxDisconnectImpact(transactions: 0, edited: 0),
        "outlook-1": MailboxDisconnectImpact(transactions: 0, edited: 0),
      ]
      return id
    }

    static var huge: MockIdentity {
      var id = worst
      id.person = .huge
      let providers = [
        "iCloud Keychain", "1Password", "Google Password Manager", "Microsoft Password Manager", "Bitwarden", "Dashlane",
        "YubiKey 5C NFC", "Proton Pass", "Keeper", "NordPass",
      ]
      id.passkeys = providers.enumerated().map { i, p in
        PasskeyRow(id: "pk-\(i + 1)", provider: p, detail: "Added \(i + 1) Sep · Used \(i) days ago", isThisCredential: i == 0)
      }
      let places = [
        "Dubai", "Abu Dhabi", "Sharjah", "Ajman", "Ras Al Khaimah", "Fujairah", "Umm Al Quwain", "Al Ain", "Muscat", "Doha",
        "Riyadh",
      ]
      id.devices =
        [thisPhone]
        + places.enumerated().map { i, place in
          DeviceRow(
            id: "ios-\(i)", title: i % 2 == 0 ? "iPad Pro 13-inch (M4)" : "iPhone 17 Pro Max",
            detail: "\(i % 2 == 0 ? "iPad" : "iPhone") · \(place) · \(i + 1) weeks ago", isThisDevice: false,
            isTablet: i % 2 == 0)
        }
      id.monthRead = MonthRead(count: 12_840, month: "September")
      id.unreadable = Array(
        repeating: UnreadableMail(kind: "Credit card statement ready", provider: .outlook, day: "Wed 30 Sep"), count: 1_284)
      return id
    }

    static func resolve(_ scenario: AuthScenario?, _ arguments: [String]) -> MockIdentity {
      var id: MockIdentity =
        switch arguments.launchValue(after: argument) ?? scenario?.rawValue {
        case "worst", "mayaWorst", "mayaWorstTexts": .worst
        case "one", "mayaOne": .one
        case "empty", "mayaEmpty": .empty
        case "huge", "mayaHuge": .huge
        default: .maya
        }
      if let name = arguments.launchValue(after: "-HasalaDisplayName") { id.person.displayName = name }
      if let email = arguments.launchValue(after: "-HasalaEmail") { id.person = id.person.withEmail(email) }
      return id
    }

    static func overridesLedger(_ arguments: [String]) -> Bool {
      [argument, "-HasalaDisplayName", "-HasalaEmail"].contains { arguments.contains($0) }
    }
  }
#endif
