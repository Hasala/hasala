import CoreMailbox
import CoreTemplate
import Foundation
import HasalaModels
import Synchronization
import Testing

@testable import Hasala

@MainActor
@Suite("Live mailbox")
struct LiveMailboxTests {
  static let signInAgain = MailOffer.signInAgain(mailboxID: "gmail", provider: .gmail)

  @Test func theMailboxOfferFollowsTheLane() {
    func offer(
      _ phase: MailboxPhase, halt: MailboxHaltCode? = nil, sample: Bool = false, link: MailboxLinkStatus? = .noLink
    ) -> MailOffer? {
      LiveMailboxConnecting.offer(phase: phase, halt: halt, sampleLoaded: sample, serverLink: link)
    }
    #expect(offer(.unlinked) == .connect)
    #expect(offer(.reconnectRequired) == Self.signInAgain)
    #expect(offer(.halted) == nil)
    for phase in [MailboxPhase.scanning, .awaitingCards, .authoringBackfill, .active, .otherDevice] {
      #expect(offer(phase) == nil)
    }
    for phase in MailboxPhase.allCases {
      #expect(offer(phase, sample: true) == nil)
    }
    #expect(offer(.unlinked, link: nil) == nil)
    #expect(offer(.unlinked, link: .holder(isThisDevice: false, watchExpiresAtMs: nil)) == .connect)
    #expect(offer(.unlinked, link: .holder(isThisDevice: true, watchExpiresAtMs: nil)) == .connect)
    #expect(offer(.reconnectRequired, link: nil) == Self.signInAgain)
    #expect(offer(.halted, halt: .gmail) == nil)
    #expect(offer(.halted, halt: nil) == nil)
    #expect(offer(.halted, halt: .reconnectRequired) == Self.signInAgain)
    #expect(offer(.halted, halt: .accountFull) == nil)
    #expect(offer(.halted, halt: .templatesUnavailable) == nil)
    #expect(offer(.halted, halt: .noMailbox) == Self.signInAgain)
  }

  @Test func theOfferIsUnknownOnlyWhileAnUnlinkedIPhoneWaitsForTheServer() {
    func known(_ phase: MailboxPhase, sample: Bool = false, link: MailboxLinkStatus? = nil) -> Bool {
      LiveMailboxConnecting.offerKnown(phase: phase, sampleLoaded: sample, serverLink: link)
    }
    #expect(!known(.unlinked))
    #expect(known(.unlinked, link: .noLink))
    #expect(known(.unlinked, link: .holder(isThisDevice: false, watchExpiresAtMs: nil)))
    #expect(known(.unlinked, sample: true))
    for phase in MailboxPhase.allCases where phase != .unlinked {
      #expect(known(phase))
    }
  }

  @Test func theOfferNamesTheLanesProvider() {
    func offer(_ phase: MailboxPhase, halt: MailboxHaltCode? = nil) -> MailOffer? {
      LiveMailboxConnecting.offer(phase: phase, halt: halt, sampleLoaded: false, serverLink: .noLink, provider: .outlook)
    }
    let outlook = MailOffer.signInAgain(mailboxID: "outlook", provider: .outlook)
    #expect(offer(.reconnectRequired) == outlook)
    #expect(offer(.halted, halt: .noMailbox) == outlook)
    #expect(offer(.active) == nil)
    #expect(offer(.scanning) == nil)
  }

  @Test func noMailboxIsSaidInWords() {
    let outlook = "This Microsoft account has no Outlook mailbox. Use the one your alerts go to, like you@outlook.com or you@hotmail.com."
    let gmail = "This Google account has no Gmail. Use the one your alerts go to."
    #expect(LiveMailboxConnecting.message(.noMailbox, provider: .outlook) == outlook)
    #expect(LiveMailboxConnecting.message(.noMailbox, provider: .gmail) == gmail)
    #expect(LiveMailboxConnecting.stopped(.noMailbox, provider: .outlook) == outlook)
    #expect(LiveMailboxConnecting.stopped(.noMailbox, provider: .gmail) == gmail)
    #expect(MailConnectFailure.noMailbox(.gmail).message(for: .gmail) == gmail)
    #expect(LiveMailboxConnecting.stopped(.gmail, provider: .gmail) == "Reading your bank alerts stopped. Try again.")
    #expect(LiveMailboxConnecting.message(.google, provider: .outlook).contains("personal Microsoft accounts"))
    #expect(LiveMailboxConnecting.message(.offline, provider: .outlook).contains("Connect Outlook when"))
  }

  @Test func aConnectWithNoMailboxIsItsOwnFailure() throws {
    #expect(throws: MailConnectFailure.noMailbox(.outlook)) {
      try LiveMailboxConnecting.linked(.failed(.noMailbox), provider: .outlook)
    }
    #expect(throws: MailConnectFailure.offline) { try LiveMailboxConnecting.linked(.failed(.offline), provider: .outlook) }
    #expect(throws: MailConnectFailure.cancelled) { try LiveMailboxConnecting.linked(.cancelled, provider: .outlook) }
    #expect(throws: MailConnectFailure.permissionMissing(.outlook)) {
      try LiveMailboxConnecting.linked(.failed(.permissionMissing), provider: .outlook)
    }
    #expect(throws: MailConnectFailure.permissionMissing(.gmail)) {
      try LiveMailboxConnecting.linked(.failed(.permissionMissing), provider: .gmail)
    }
    #expect(MailConnectFailure.permissionMissing(.gmail).message(for: .gmail)
      == "\u{201C}View your email messages and settings\u{201D} wasn't ticked. Try again and tick it.")
    #expect(LiveMailboxConnecting.message(.permissionMissing, provider: .gmail)
      == MailConnectFailure.permissionMissingLine(.gmail))
    #expect(try LiveMailboxConnecting.linked(.connected(address: nil), provider: .outlook) == nil)
    #expect(try LiveMailboxConnecting.linked(.connected(address: "maya.k@example.com"), provider: .outlook) == nil)
    #expect(
      try LiveMailboxConnecting.linked(.connected(address: "maya.other@example.com", anotherAddress: true), provider: .outlook)
        == "maya.other@example.com")
    #expect(MailConnectFailure.noMailbox(.outlook).message(for: .outlook)
      == "This Microsoft account has no Outlook mailbox. Use the one your alerts go to, like you@outlook.com or you@hotmail.com.")
  }

  @Test func theSwitchQuestionAndItsAnswerCrossTheLane() async throws {
    #expect(throws: MailConnectFailure.switchDeclined) { try LiveMailboxConnecting.linked(.declined, provider: .gmail) }
    let removed = ConnectResult.connected(address: "maya.home@example.com", anotherAddress: true, retired: .removed(3))
    #expect(try LiveMailboxConnecting.linked(removed, provider: .gmail) == "maya.home@example.com")
    #expect(LiveMailboxConnecting.retired(removed) == .removed(3))
    #expect(LiveMailboxConnecting.retired(.declined) == nil)
    #expect(LiveMailboxConnecting.removal(.removed(3), old: "maya@example.com") == .removed(3))
    #expect(LiveMailboxConnecting.removal(.failed, old: "maya@example.com") == .failed(from: "maya@example.com"))
    #expect(LiveMailboxConnecting.removal(nil, old: "maya@example.com") == nil)

    let core = MailboxSwitchQuestion(
      oldAddress: "maya@example.com", newAddress: "maya.home@example.com", transactions: 4, edited: 1,
      oldHasNoMailbox: false)
    #expect(LiveMailboxConnecting.question(core, provider: .gmail) == MailSwitchQuestion(
      provider: .gmail, oldAddress: "maya@example.com", newAddress: "maya.home@example.com",
      impact: MailboxDisconnectImpact(transactions: 4, edited: 1)))
    var none = core
    none.transactions = 0
    none.oldHasNoMailbox = true
    #expect(LiveMailboxConnecting.question(none, provider: .outlook).impact == nil)
    #expect(LiveMailboxConnecting.question(none, provider: .outlook).oldHasNoMailbox)
    #expect(!LiveMailboxConnecting.question(none, provider: .outlook).countUnknown)
    var unknown = core
    unknown.transactions = nil
    let mapped = LiveMailboxConnecting.question(unknown, provider: .gmail)
    #expect(mapped.impact == nil && mapped.countUnknown && mapped.offersRemove)
    #expect(LiveMailboxConnecting.removal(.removed(nil), old: "maya@example.com") == .removed(nil))

    let seen = Mutex<[MailSwitchQuestion]>([])
    for (answer, expected) in [(MailSwitchChoice.keep, MailboxSwitchChoice.keep), (.remove, .remove), (.cancel, .cancel)] {
      let confirm = LiveMailboxConnecting.confirm({ q in
        seen.withLock { $0.append(q) }
        return answer
      }, provider: .gmail)
      #expect(await confirm(core) == expected)
    }
    #expect(seen.withLock { $0.map(\.newAddress) } == Array(repeating: "maya.home@example.com", count: 3))
  }

  @Test func aRefusedConnectSaysItsOwnReason() {
    #expect(!MailConnectRefusal.reviewAccount.message.contains("sample"))
    #expect(MailConnectRefusal.sampleData.message.contains("sample data"))
  }

  @Test func aMailboxOnAnotherAccountIsSaidInWords() {
    let gmail = LiveMailboxConnecting.message(.mailboxInUse)
    #expect(gmail.contains("This Gmail address is connected to another Hasala account"))
    #expect(gmail.contains("use another address"))
    #expect(LiveMailboxConnecting.message(.mailboxInUse, provider: .outlook).hasPrefix("This Outlook address"))
    #expect(gmail != LiveMailboxConnecting.message(.serverRefused))
  }

  @Test func aWorkingLinkIsNeverReplacedUnconfirmed() throws {
    func admit(_ requested: MailProviderKind, _ phase: MailboxPhase, replacing: Bool = false) throws(MailConnectFailure)
      -> Bool
    {
      try LiveMailboxConnecting.admit(
        requested, current: .gmail, phase: phase, address: "maya@example.com", replacing: replacing)
    }
    for provider in MailProviderKind.allCases {
      #expect(try admit(provider, .unlinked) == false)
      #expect(try admit(provider, .unlinked, replacing: true) == false)
      #expect(try admit(provider, .otherDevice) == false)
      #expect(try admit(provider, .otherDevice, replacing: true) == false)
    }
    for phase in [MailboxPhase.reconnectRequired, .halted] {
      #expect(try admit(.gmail, phase) == false)
      #expect(throws: MailConnectFailure.failed("Disconnect Gmail first, then connect Outlook.")) {
        try admit(.outlook, phase)
      }
      #expect(try admit(.outlook, phase, replacing: true) == true)
    }
    for phase in [MailboxPhase.scanning, .awaitingCards, .authoringBackfill, .active] {
      #expect(throws: MailConnectFailure.alreadyConnected(address: "maya@example.com")) { try admit(.gmail, phase) }
      #expect(throws: MailConnectFailure.failed("Disconnect Gmail first, then connect Outlook.")) {
        try admit(.outlook, phase)
      }
      #expect(try admit(.outlook, phase, replacing: true) == true)
    }
  }

  @Test func aLinkTakenElsewhereRefusesTheDisconnect() throws {
    #expect(throws: MailConnectFailure.takenByOtherIPhone) { try LiveMailboxConnecting.checkDisconnect(.otherDevice) }
    for phase in [MailboxPhase.unlinked, .scanning, .awaitingCards, .authoringBackfill, .active, .reconnectRequired,
                  .halted] {
      try LiveMailboxConnecting.checkDisconnect(phase)
    }
  }

  @Test func anIPhoneThatLostTheLinkCanTakeItBack() throws {
    let other = MailboxLinkStatus.holder(isThisDevice: false, watchExpiresAtMs: nil)
    let mine = MailboxLinkStatus.holder(isThisDevice: true, watchExpiresAtMs: nil)
    #expect(LiveMailboxConnecting.heldElsewhere(phase: .otherDevice, link: other, provider: .outlook) == .outlook)
    #expect(LiveMailboxConnecting.heldElsewhere(phase: .unlinked, link: other, provider: .gmail) == .gmail)
    #expect(LiveMailboxConnecting.heldElsewhere(phase: .otherDevice, link: mine, provider: .gmail) == nil)
    #expect(LiveMailboxConnecting.heldElsewhere(phase: .otherDevice, link: .noLink, provider: .gmail) == nil)
    #expect(LiveMailboxConnecting.heldElsewhere(phase: .otherDevice, link: nil, provider: .gmail) == nil)
    for phase in [MailboxPhase.scanning, .awaitingCards, .authoringBackfill, .active, .reconnectRequired, .halted] {
      #expect(LiveMailboxConnecting.heldElsewhere(phase: phase, link: other, provider: .gmail) == nil)
    }
    #expect(LiveMailboxConnecting.asksBeforeConnect(.otherDevice))
    #expect(LiveMailboxConnecting.asksBeforeConnect(.unlinked))
    for phase in [MailboxPhase.scanning, .awaitingCards, .authoringBackfill, .active, .reconnectRequired, .halted] {
      #expect(!LiveMailboxConnecting.asksBeforeConnect(phase))
    }
    #expect(throws: MailConnectFailure.takenByOtherIPhone) { try LiveMailboxConnecting.checkTakeover(other) }
    try LiveMailboxConnecting.checkTakeover(other, confirmed: true)
    try LiveMailboxConnecting.checkTakeover(.noLink)
  }

  @Test func theStepUpNamesNoProvider() {
    #expect(LiveStepUp.reason("mailbox.link") == "Confirm it's you to connect this mailbox")
    #expect(LiveStepUp.reason("mailbox.unlink") == "Confirm it's you to disconnect this mailbox")
  }

  @Test func aLinkHeldElsewhereIsTakenOverOnlyOnceConfirmed() throws {
    let other = MailboxLinkStatus.holder(isThisDevice: false, watchExpiresAtMs: nil)
    #expect(LiveMailboxConnecting.offer(phase: .unlinked, sampleLoaded: false, serverLink: .noLink) == .connect)
    try LiveMailboxConnecting.checkTakeover(.noLink)
    #expect(LiveMailboxConnecting.offer(phase: .unlinked, sampleLoaded: false, serverLink: other) == .connect)
    #expect(LiveMailboxConnecting.offer(phase: .unlinked, sampleLoaded: false, serverLink: nil) == nil)
    #expect(throws: MailConnectFailure.takenByOtherIPhone) {
      try LiveMailboxConnecting.checkTakeover(other)
    }
    try LiveMailboxConnecting.checkTakeover(other, confirmed: true)
    #expect(MailConnectFailure.takenByOtherIPhone.message(for: .gmail) == "Your email is read on your other iPhone.")
    #expect(MailConnectFailure.takenByOtherIPhone.message(for: .outlook) == "Your email is read on your other iPhone.")
    for confirmed in [false, true] {
      #expect(throws: MailConnectFailure.offline) {
        try LiveMailboxConnecting.checkTakeover(nil, confirmed: confirmed)
      }
    }
    #expect(MailConnectFailure.offline.message(for: .gmail) == LiveMailboxConnecting.message(.offline))
    #expect(MailCopy.takeoverTitle == "Read your email on this iPhone?")
    #expect(MailCopy.takeoverMessage(from: .gmail, to: .gmail)
      == "Another iPhone reads your Gmail, maybe one you no longer have. It stops. Past transactions stay.")
    #expect(MailCopy.takeoverMessage(from: .outlook, to: .gmail)
      == "Another iPhone reads your Outlook, maybe one you no longer have. It stops, and this iPhone reads Gmail. Past transactions stay.")
  }

  @Test func theBanksComeFromTheTrustedSenders() {
    #expect(LiveMailboxConnecting.banks(trusted: []) == [])
    #expect(LiveMailboxConnecting.banks(trusted: ["dib.ae"]) == [.dib])
    #expect(LiveMailboxConnecting.banks(trusted: MailboxLane.senderDomains(bank: "enbd") + ["dib.ae"]) == [.enbd, .dib])
  }

  @Test func theLaneSharesTheBundledMailTemplates() {
    let loaded = BundledTemplates.load(channel: .mail).templates.map(\.definition.id)
    #expect(!loaded.isEmpty)
    #expect(MailboxLane.mailTemplates.map(\.definition.id) == loaded)
    #expect(MailboxLane.mailDefinitions.map(\.id) == loaded)
    #expect(MailboxLane.mailDefinitions.allSatisfy { !$0.isSMS })
    #expect(MailboxLane.senderDomains(bank: "dib") == ["dib.ae"])
    #expect(MailboxLane.senderDomains(bank: "enbd") == ["emiratesnbd.com"])
    #expect(MailboxLane.senderDomains(bank: "none").isEmpty)
  }

  @Test func bankAlertsNameTheirBank() {
    #expect(LedgerStateMapper.bankName(domain: "emiratesnbd.com") == "Emirates NBD")
    #expect(LedgerStateMapper.bankName(domain: "dib.ae") == "DIB")
    #expect(LedgerStateMapper.bankName(domain: "alerts.dib.ae") == "DIB")
    #expect(LedgerStateMapper.bankName(domain: "notdib.ae") == nil)
  }

  @Test func liveConnectsWhatTheBuildHasAClientFor() throws {
    func build(google: String, outlook: String) throws -> BuildInfo {
      try BuildInfo(infoDictionary: [
        "CFBundleShortVersionString": "0.2.0", "CFBundleVersion": "1", "HasalaGitCommit": "unset",
        "HasalaEnvironment": "qa", "HasalaAPIBaseURL": "https://api.example.com", "HasalaGoogleClientID": google,
        "HasalaGoogleRedirectScheme": google == "unset" ? "unset" : "com.googleusercontent.apps.test",
        "HasalaGmailPubSubTopic": "unset", "HasalaOutlookClientID": outlook,
        "HasalaOutlookRedirectScheme": "msauth.app.hasala.ios",
      ])
    }
    let google = "test.apps.googleusercontent.com"
    let microsoft = "00000000-0000-4000-8000-000000000000"
    #expect(LiveMailboxConnecting.providers(build: try build(google: google, outlook: microsoft)) == [.gmail, .outlook])
    #expect(LiveMailboxConnecting.providers(build: try build(google: google, outlook: "unset")) == [.gmail])
    #expect(LiveMailboxConnecting.providers(build: try build(google: "unset", outlook: "unset")).isEmpty)
    let lane = LiveMailboxConnecting(runtime: { nil }, buildProviders: [.gmail, .outlook])
    #expect(lane.connectable == [.gmail, .outlook])
    #expect(LiveMailboxConnecting(runtime: { nil }).connectable.isEmpty)
    #expect(lane.capabilities == [.connect, .signInAgain, .disconnect, .replace, .tryAgain])
    #expect(!lane.capabilities.contains(.addSecond) && lane.holdsOneLink)
    #expect(lane.mailboxes.isEmpty && lane.offer == nil && lane.linkedProvider == nil)
  }

  @Test func theLinksOwnStateBeatsTheRememberedProviderAfterAnInterruptedSwitch() {
    #expect(AccountRuntime.interruptedSwitch(held: .outlook, remembered: .gmail) == .gmail)
    #expect(AccountRuntime.interruptedSwitch(held: .gmail, remembered: .gmail) == nil)
    #expect(AccountRuntime.interruptedSwitch(held: nil, remembered: .gmail) == nil)
    #expect(AccountRuntime.interruptedSwitch(held: .outlook, remembered: nil) == nil)
  }

  @Test func theLiveMailboxSaysWhenItLastChecked() async {
    let dubai = TimeZone(identifier: "Asia/Dubai")!
    let ms: Int64 = 1_791_350_040_000
    #expect(LiveMailboxConnecting.checkedAt(ms, timeZone: dubai) == "Wed 7 Oct, 09:14")
    let row = LiveMailboxConnecting.mailboxes(
      phase: .active, halt: nil, address: "maya@example.com", lastSuccessAtMs: ms, bankDomains: [],
      nowMs: ms + 60_000, timeZone: dubai
    ).first
    #expect(row?.lastChecked == "Wed 7 Oct, 09:14" && row?.meta == "Checked 1 min ago")
    let lane = LiveMailboxConnecting(runtime: { nil })
    await #expect(throws: MailConnectFailure.failed("Still opening your account. Try again in a moment.")) {
      try await lane.connect(.outlook)
    }
  }

  @Test func bankAlertsReadTheLaneHealth() throws {
    let now: Int64 = 1_792_051_200_000
    let json = """
      [{"domain": "emiratesnbd.com", "lastEmailAtMs": \(now - 4 * 60_000), "month": "2026-10", "readThisMonth": 150},
       {"domain": "alerts.dib.ae", "lastEmailAtMs": \(now - 2 * 3_600_000), "month": "2026-10", "readThisMonth": 64},
       {"domain": "dib.ae", "lastEmailAtMs": \(now - 30 * 86_400_000), "month": "2026-09", "readThisMonth": 9}]
      """
    let health = try JSONDecoder().decode([BankHealthRow].self, from: Data(json.utf8))
    #expect(LiveMailboxConnecting.lastEmail(.enbd, health: health, nowMs: now) == "4 min ago")
    #expect(LiveMailboxConnecting.lastEmail(.dib, health: health, nowMs: now) == "2 h ago")
    #expect(LiveMailboxConnecting.lastEmail(.dib, health: [], nowMs: now) == nil)
    #expect(LiveMailboxConnecting.readThisMonth(health, nowMs: now) == MonthRead(count: 214, month: "October"))
    #expect(LiveMailboxConnecting.readThisMonth([], nowMs: now) == nil)
    #expect(LiveMailboxConnecting.readThisMonth(health, nowMs: now + 20 * 86_400_000) == nil)
  }

  @Test func theLanePhaseIsTheRow() {
    let now: Int64 = 10_000_000_000
    func row(_ phase: MailboxPhase, halt: MailboxHaltCode? = nil) -> MailboxSnapshot? {
      LiveMailboxConnecting.mailboxes(
        phase: phase, halt: halt, address: "maya@example.com", lastSuccessAtMs: now - 4 * 60_000,
        bankDomains: ["dib.ae"], nowMs: now
      ).first
    }
    #expect(row(.unlinked) == nil)
    #expect(row(.scanning)?.state == .syncing && row(.scanning)?.meta == "Checking now")
    #expect(row(.awaitingCards)?.state == .syncing)
    #expect(row(.active)?.state == .connected && row(.active)?.meta == "Checked 4 min ago")
    #expect(row(.active)?.banks == ["DIB"] && row(.active)?.id == "gmail")
    #expect(row(.reconnectRequired)?.state == .needsSignIn)
    #expect(row(.halted, halt: .gmail)?.state == .readingStopped)
    #expect(row(.halted, halt: nil)?.state == .readingStopped)
    #expect(row(.halted, halt: .accountFull)?.state == .readingStopped && row(.halted, halt: .accountFull)?.note == nil)
    #expect(row(.otherDevice)?.note == "Read on your other iPhone")
    #expect(row(.otherDevice)?.readElsewhere == true && row(.otherDevice)?.state == .connected)
    #expect(row(.active)?.readElsewhere == false && row(.halted, halt: .noMailbox)?.readElsewhere == false)
    #expect(row(.halted, halt: .noMailbox)?.state == .needsSignIn)
    #expect(row(.halted, halt: .noMailbox)?.note == MailConnectFailure.noMailboxLine(.gmail))
    let haltedOutlook = LiveMailboxConnecting.mailboxes(
      phase: .halted, halt: .noMailbox, address: "maya.k@example.com", lastSuccessAtMs: nil, bankDomains: [],
      provider: .outlook, nowMs: now
    ).first
    #expect(haltedOutlook?.note == MailConnectFailure.noMailboxLine(.outlook))
    #expect(row(.halted, halt: .gmail)?.note == nil)
    let outlook = LiveMailboxConnecting.mailboxes(
      phase: .active, halt: nil, address: "maya.k@example.com", lastSuccessAtMs: nil, bankDomains: [],
      provider: .outlook, nowMs: now
    ).first
    #expect(outlook?.id == "outlook" && outlook?.provider == .outlook && outlook?.accountKind == "Personal Microsoft")
    #expect(row(.active)?.accountKind == nil)
  }

  @Test func aLinkHeldByAnotherIPhoneIsNotShownAsWorkingHere() {
    let rows = LiveMailboxConnecting.mailboxes(
      phase: .unlinked, halt: nil, address: nil, lastSuccessAtMs: nil, bankDomains: [], nowMs: 10_000_000_000)
    #expect(rows.isEmpty)
    let offer = LiveMailboxConnecting.offer(
      phase: .unlinked, sampleLoaded: false, serverLink: .holder(isThisDevice: false, watchExpiresAtMs: nil))
    let summary = MailboxesSummary(
      rows, health: MailboxHealth(status: .notConnected, lastEmail: "", banks: ""), offer: offer)
    #expect(summary.title == "Your email isn't connected" && summary.needsYou)
    #expect(summary.detail == "Connect it to read your bank alerts.")
    #expect(ProfileSheet.mailboxesValue(rows, known: true) == ("Not connected", nil))
    #expect(LiveMailboxConnecting(runtime: { nil }).heldElsewhere == nil)
  }

  @Test func noRuntimeMeansNotKnownYet() {
    let lane = LiveMailboxConnecting(runtime: { nil })
    #expect(!lane.mailboxesKnown && lane.mailboxes.isEmpty)
  }

  @Test func aHaltedLaneIsNotWorking() {
    let now: Int64 = 10_000_000_000
    func summary(
      _ phase: MailboxPhase, halt: MailboxHaltCode?, health: MailboxHealth.Status, provider: MailProviderKind = .gmail
    ) -> MailboxesSummary {
      let rows = LiveMailboxConnecting.mailboxes(
        phase: phase, halt: halt, address: "maya@example.com", lastSuccessAtMs: now - 4 * 60_000,
        bankDomains: ["dib.ae"], provider: provider, nowMs: now)
      return MailboxesSummary(
        rows, health: MailboxHealth(status: health, lastEmail: "4 min ago", banks: "DIB"),
        offer: LiveMailboxConnecting.offer(
          phase: phase, halt: halt, sampleLoaded: false, serverLink: .noLink, provider: provider))
    }
    for provider in [MailProviderKind.gmail, .outlook] {
      for halt in [MailboxHaltCode.accountFull, .templatesUnavailable, .gmail, nil] {
        let s = summary(.halted, halt: halt, health: .reconnect, provider: provider)
        #expect(s.title == "Bank alerts stopped" && s.detail == "Hasala stopped reading maya@example.com.")
        #expect(s.hue == .sand && s.needsYou)
        #expect(!s.detail.contains("ended"))
      }
    }
    let reconnect = summary(.reconnectRequired, halt: .reconnectRequired, health: .reconnect, provider: .outlook)
    #expect(reconnect.title == "Sign in again" && reconnect.detail == "Microsoft ended access to maya@example.com.")
    let noMailbox = summary(.halted, halt: .noMailbox, health: .reconnect)
    #expect(noMailbox.title == "Sign in again" && noMailbox.detail == MailConnectFailure.noMailboxLine(.gmail))
    let elsewhere = summary(.otherDevice, halt: nil, health: .working)
    #expect(elsewhere.title == "Bank alerts are working" && !elsewhere.needsYou)
  }

  @Test func anotherIPhoneThatWentQuietIsNotShownAsWorking() throws {
    let now: Int64 = 1_792_483_200_000
    let day: Int64 = 86_400_000
    let rows = LiveMailboxConnecting.mailboxes(
      phase: .otherDevice, halt: nil, address: "maya@example.com", lastSuccessAtMs: now - 4 * 60_000,
      bankDomains: ["dib.ae"], nowMs: now)
    let health = MailboxHealth(status: .working, lastEmail: "9 days ago", banks: "DIB")
    func reading(newestRowDaysAgo days: Int64?) -> ReadingState {
      ReadingState.derive(
        ReadingFacts(
          nowMs: now, mail: ReadingFacts.Mail(provider: .gmail, phase: .otherDevice),
          newestMailRowMs: days.map { now - $0 * day }))
    }
    func summary(_ state: ReadingState) -> MailboxesSummary {
      MailboxesSummary(rows, health: health, offer: nil, reading: state)
    }

    let stale = reading(newestRowDaysAgo: 8)
    let quiet = summary(stale)
    #expect(quiet.title == "Bank alerts went quiet" && quiet.hue == .sand && quiet.needsYou)
    #expect(quiet.detail == "Nothing new from your other iPhone since 12 Oct. Newer payments aren't counted.")
    let hold = try #require(ReadingOnScreen.hold(stale, month: stale.today.yearMonth))
    #expect(quiet.detail == hold.line)

    let hero = BankAlertsPage.Hero(summary: quiet, health: health, mailboxes: rows, offer: nil)
    #expect(hero.kind == .needsYou && hero.title == "Needs you" && hero.hue == .sand)
    #expect(hero.detail == quiet.detail && hero.totalsLine == nil)

    let undated = summary(reading(newestRowDaysAgo: nil))
    #expect(undated.title == "Bank alerts went quiet" && undated.needsYou)
    #expect(undated.detail == "Nothing new from your other iPhone. Newer payments aren't counted.")

    let fresh = summary(reading(newestRowDaysAgo: 6))
    #expect(fresh.title == "Bank alerts are working" && !fresh.needsYou)
    #expect(fresh.detail == "Last email 9 days ago\nDIB")

    let nothingReadHere = MailboxesSummary(
      [], health: MailboxHealth(status: .notConnected, lastEmail: "", banks: ""), offer: .connect, reading: stale)
    #expect(nothingReadHere.title == "Your email isn't connected")
  }

  @Test func homesImportPillFollowsTheFirstScan() {
    func work(_ phase: MailboxPhase?, seen: Bool = true, _ progress: MailboxProgress? = nil) -> MailImport? {
      LiveMailboxConnecting.importing(phase: phase, seen: seen, progress: progress)
    }
    let reading = MailboxProgress(stage: .downloading, done: 214, total: 268)
    for phase in [MailboxPhase.scanning, .awaitingCards, .authoringBackfill] {
      #expect(work(phase, reading) == MailImport(state: .reading, read: 214, total: 268))
    }
    let pill = work(.scanning, reading)
    #expect(pill?.label == "Reading your alerts" && pill?.count == "214 of 268" && pill?.busy == true)
    #expect(pill?.opensBankAlerts == false)
    #expect(work(.scanning)?.count == nil && work(.scanning)?.busy == true)
    let offline = work(.scanning, MailboxProgress(stage: .failed(.offline), done: 214, total: 268))
    #expect(offline?.state == .offline && offline?.label == "Offline" && offline?.count == nil && offline?.busy == false)
    for code in [MailboxHaltCode.gmail, .quota] {
      let paused = work(.scanning, MailboxProgress(stage: .failed(code), done: 214, total: 268))
      #expect(paused?.state == .paused && paused?.label == "Reading paused" && paused?.busy == false)
      #expect(paused?.count == "214 of 268" && paused?.opensBankAlerts == false)
    }
    #expect(work(.scanning, MailboxProgress(stage: .done, done: 268, total: 268)) == nil)
    for phase in [MailboxPhase.active, .unlinked, .otherDevice] {
      #expect(work(phase, reading) == nil)
    }
    #expect(work(nil) == nil)
    let stopped = work(.halted, reading)
    #expect(stopped?.label == "Reading stopped" && stopped?.busy == false && stopped?.count == nil)
    #expect(stopped?.opensBankAlerts == true)
    let signIn = work(.reconnectRequired)
    #expect(signIn?.label == "Sign in again" && signIn?.opensBankAlerts == true)
    #expect(work(.halted, seen: false) == nil)
    #expect(work(.reconnectRequired, seen: false) == nil)
  }

  @Test func aSignInWithAnotherAddressShowsThatAddressReadingFromTheStart() {
    let now: Int64 = 10_000_000_000
    let before = LiveMailboxConnecting.mailboxes(
      phase: .halted, halt: .noMailbox, address: "maya.k@example.com", lastSuccessAtMs: now - 86_400_000,
      bankDomains: ["dib.ae"], provider: .outlook, nowMs: now
    ).first
    #expect(before?.address == "maya.k@example.com" && before?.state == .needsSignIn && before?.note != nil)
    let after = LiveMailboxConnecting.mailboxes(
      phase: .scanning, halt: nil, address: "maya.new@example.com", lastSuccessAtMs: nil, bankDomains: [],
      provider: .outlook, nowMs: now
    ).first
    #expect(after?.id == before?.id && after?.address == "maya.new@example.com")
    #expect(after?.state == .syncing && after?.meta == "Checking now" && after?.note == nil)
    #expect(after?.banks.isEmpty == true && after?.lastChecked == nil)
    let pill = LiveMailboxConnecting.importing(phase: .scanning, seen: true, progress: nil)
    #expect(pill?.state == .reading && pill?.busy == true)
  }

  @Test func aFirstScanThatGivesUpOnAPassingStopPausesThePill() {
    func totals(_ phase: MailboxPhase, _ halt: MailboxHaltCode?) -> MailboxLane.FirstScanTotals {
      var t = MailboxLane.FirstScanTotals()
      t.phase = phase
      t.haltedOn = halt
      return t
    }
    for code in [MailboxHaltCode.offline, .gmail, .quota] {
      #expect(totals(.scanning, code).pause == MailboxProgress(stage: .failed(code), done: 0, total: 0))
      #expect(totals(.authoringBackfill, code).pause?.stage == .failed(code))
    }
    #expect(totals(.scanning, nil).pause == nil)
    #expect(totals(.scanning, .stagingFull).pause == nil)
    #expect(totals(.active, nil).pause == nil)
    #expect(totals(.halted, .accountFull).pause == nil)
    #expect(totals(.reconnectRequired, .reconnectRequired).pause == nil)
  }
}

@Suite("Mail grant endings")
struct MailGrantEndsTests {
  nonisolated final class Log: Sendable {
    let entries = Mutex<[String]>([])
    func add(_ s: String) { entries.withLock { $0.append(s) } }
    var all: [String] { entries.withLock { $0 } }
  }

  @Test func nothingPendingIsSettledAtOnce() async {
    #expect(await MailGrantEnds().settled(within: .milliseconds(1)))
  }

  @Test func endingsRunInOrderAndAConnectWaitsForThem() async {
    let ends = MailGrantEnds()
    let log = Log()
    ends.enqueue {
      try? await Task.sleep(for: .milliseconds(80))
      log.add("deleted account: users.stop, revoke")
    }
    ends.enqueue { log.add("wiped account: revoke") }
    #expect(await ends.settled(within: .seconds(10)))
    log.add("connect")
    #expect(log.all == ["deleted account: users.stop, revoke", "wiped account: revoke", "connect"])
  }

  @Test func aHungEndingHoldsAConnectOnlyForTheLimit() async {
    let ends = MailGrantEnds()
    let release = Mutex<CheckedContinuation<Void, Never>?>(nil)
    ends.enqueue { await withCheckedContinuation { c in release.withLock { $0 = c } } }
    let start = ContinuousClock.now
    #expect(await ends.settled(within: .milliseconds(50)) == false)
    #expect(ContinuousClock.now - start < .seconds(5))
    while release.withLock({ $0 == nil }) { await Task.yield() }
    release.withLock { $0?.resume(); $0 = nil }
    #expect(await ends.settled(within: .seconds(10)))
  }

  @Test func aConnectIsRefusedWhileAnEndingStillRuns() async {
    let ends = MailGrantEnds()
    let release = Mutex<CheckedContinuation<Void, Never>?>(nil)
    ends.enqueue { await withCheckedContinuation { c in release.withLock { $0 = c } } }
    #expect(await ends.connectGate(within: .milliseconds(50)) == .failed(.google))
    while release.withLock({ $0 == nil }) { await Task.yield() }
    release.withLock { $0?.resume(); $0 = nil }
    #expect(await ends.connectGate(within: .seconds(10)) == nil)
    #expect(await MailGrantEnds().connectGate(within: .milliseconds(1)) == nil)
  }

  @Test func aCancelledDepartureStillWaitsForItsEnding() async {
    let ends = MailGrantEnds()
    let log = Log()
    let departure = Task {
      while !Task.isCancelled { await Task.yield() }
      await ends.end {
        try? await Task.sleep(for: .milliseconds(80))
        log.add("ended")
      }
      log.add("left")
    }
    departure.cancel()
    await departure.value
    #expect(log.all == ["ended", "left"])
  }

  @Test func aCancelledDepartureWaitsOnlyForTheLimit() async {
    let ends = MailGrantEnds()
    let release = Mutex<CheckedContinuation<Void, Never>?>(nil)
    let departure = Task {
      while !Task.isCancelled { await Task.yield() }
      await ends.end(within: .milliseconds(50)) {
        await withCheckedContinuation { c in release.withLock { $0 = c } }
      }
    }
    departure.cancel()
    await departure.value
    #expect(await ends.settled(within: .milliseconds(1)) == false)
    while release.withLock({ $0 == nil }) { await Task.yield() }
    release.withLock { $0?.resume(); $0 = nil }
    #expect(await ends.settled(within: .seconds(10)))
  }

  @Test func anEndingIsBoundedInsideTheConnectWait() {
    let worst = Duration.seconds(MailGrantEnds.requestLimit * Double(MailGrantEnds.requestsPerEnding))
    #expect(worst < MailGrantEnds.connectWait)
  }
}
