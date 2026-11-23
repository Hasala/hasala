import CoreMailbox
import CoreTime
import Foundation
import HasalaModels
import Observation

@MainActor
@Observable
final class LiveMailboxConnecting: MailboxConnecting, BankAlertsReporting, OtherBankProbing, SenderAddressAdding {
  @ObservationIgnored private let runtime: @MainActor () -> AccountRuntime?
  @ObservationIgnored private let buildProviders: [MailProviderKind]

  init(runtime: @escaping @MainActor () -> AccountRuntime?, buildProviders: [MailProviderKind] = []) {
    self.runtime = runtime
    self.buildProviders = buildProviders
  }

  static func providers(build: BuildInfo) -> [MailProviderKind] {
    MailProviderKind.allCases.filter { provider in
      switch provider {
      case .gmail:
        GmailOAuthConfig(clientID: build.googleClientID, redirectScheme: build.googleRedirectScheme).isConfigured
      case .outlook:
        MicrosoftOAuthConfig(clientID: build.outlookClientID, redirectScheme: build.outlookRedirectScheme).isConfigured
      }
    }
  }

  static func mailboxID(_ provider: MailProviderKind) -> String { provider.rawValue }

  var connectable: [MailProviderKind] { runtime()?.providers ?? buildProviders }

  var capabilities: MailboxCapabilities { [.connect, .signInAgain, .disconnect, .replace, .tryAgain] }

  var linkedProvider: MailProviderKind? {
    guard let rt = runtime(), rt.store.mailboxPhase != .unlinked else { return nil }
    return rt.activeProvider
  }

  var mailboxes: [MailboxSnapshot] {
    guard let rt = runtime(), let status = rt.store.readMailboxStatus else { return [] }
    return Self.mailboxes(status, provider: rt.lane?.provider ?? .gmail, nowMs: rt.context.clock.nowMs())
  }

  var heldElsewhere: MailProviderKind? {
    guard let rt = runtime(), let lane = rt.lane, let phase = rt.store.readMailboxStatus?.phase else { return nil }
    return Self.heldElsewhere(phase: phase, link: rt.serverLink, provider: lane.provider)
  }

  static func heldElsewhere(phase: MailboxPhase, link: MailboxLinkStatus?, provider: MailProviderKind)
    -> MailProviderKind?
  {
    guard asksBeforeConnect(phase), case .holder(false, _)? = link else { return nil }
    return provider
  }

  static func asksBeforeConnect(_ phase: MailboxPhase) -> Bool {
    phase == .unlinked || phase == .otherDevice
  }

  func reading(
    textsChosen: Bool, textsLastRunMs: Int64?, backgroundRefreshOff: Bool = LiveReading.backgroundRefreshOff
  ) -> ReadingState {
    guard let rt = runtime() else {
      return ReadingState.derive(ReadingFacts(nowMs: Int64(Date().timeIntervalSince1970 * 1000), known: false))
    }
    return rt.reading(textsChosen: textsChosen, textsLastRunMs: textsLastRunMs, backgroundRefreshOff: backgroundRefreshOff)
  }

  var mailboxesKnown: Bool {
    guard let rt = runtime() else { return false }
    return rt.lane == nil || rt.store.readMailboxStatus != nil
  }

  var offersSampleData: Bool { runtime()?.offersSampleData ?? false }

  var connectRefusal: MailConnectRefusal? {
    guard let rt = runtime() else { return nil }
    return Self.refusal(reviewAccount: rt.reviewAccount, holdsSample: rt.store.holdsSample)
  }

  static func refusal(reviewAccount: Bool, holdsSample: Bool) -> MailConnectRefusal? {
    if holdsSample { return .sampleData }
    return reviewAccount ? .reviewAccount : nil
  }

  var offer: MailOffer? { runtime()?.mailOffer }

  var offerKnown: Bool { runtime()?.mailOfferKnown ?? false }

  var importing: MailImport? {
    guard let rt = runtime(), !rt.store.holdsSample else { return nil }
    return Self.importing(phase: rt.store.mailboxPhase, seen: rt.store.importSeen, progress: rt.store.importProgress)
  }

  var firstScanFinished: Bool {
    guard let rt = runtime(), !rt.store.holdsSample else { return false }
    return rt.store.mailboxPhase == .active && rt.store.readMailboxStatus?.readFromMs == nil
  }

  var pastMailDays: Int {
    guard let rt = runtime() else { return 90 }
    if let status = rt.store.readMailboxStatus, status.readFromMs != nil, let days = status.backfillDays { return days }
    return MailboxEngine.backfillDays(
      newestImportMs: (try? rt.projection.reader.newestMailboxPostedMs()) ?? nil, nowMs: rt.context.clock.nowMs())
  }

  func importPastMail(_ mailboxID: String) async -> MailPastImport {
    guard let rt = runtime(), let lane = rt.lane else { return .notStarted }
    let report = await lane.importPastMail()
    await rt.refreshMailbox()
    return Self.pastImport(report)
  }

  static func pastImport(_ report: CycleReport) -> MailPastImport {
    guard report.pastImportStarted else { return .notStarted }
    return report.completed && report.haltedOn == nil ? .finished(report.ops) : .later
  }

  static func importing(phase: MailboxPhase?, seen: Bool, progress: MailboxProgress?) -> MailImport? {
    let read = progress?.done ?? 0
    let total = progress?.total ?? 0
    switch phase {
    case .scanning?, .awaitingCards?, .authoringBackfill?:
      switch progress?.stage {
      case .done?: return nil
      case .failed(.offline)?: return MailImport(state: .offline, read: read, total: total)
      case .failed?: return MailImport(state: .paused, read: read, total: total)
      case .listing?, .downloading?, .authoring?, nil: return MailImport(state: .reading, read: read, total: total)
      }
    case .halted?:
      guard seen else { return nil }
      return MailImport(state: .stopped("Reading stopped"), read: read, total: total)
    case .reconnectRequired?:
      guard seen else { return nil }
      return MailImport(state: .stopped("Sign in again"), read: read, total: total)
    case .active?, .unlinked?, .otherDevice?, nil:
      return nil
    }
  }

  func chosenBanks() -> [SupportedBank] {
    guard let rt = runtime() else { return [] }
    return Self.banks(trusted: BankDomains.effectiveTrusted((try? rt.projection.reader.senderTrust()) ?? [:]))
  }

  func probeOtherBanks(_ candidates: [BankCandidate]) async -> OtherBankProbe {
    guard let lane = runtime()?.lane else { return .notReading }
    switch await lane.probeSenders(candidates.flatMap(\.domains)) {
    case .found(let domains): return .found(OtherBankProbe.hints(found: domains, in: candidates))
    case .notReading: return .notReading
    case .reconnectRequired: return .signInAgain
    case .offline: return .offline
    }
  }

  var unlistedSenders: [String] { runtime()?.store.readMailboxStatus?.unlisted ?? [] }

  func addSenderAddress(_ typed: String, for domain: String) async -> SenderAddressOutcome {
    guard let rt = runtime(), let lane = rt.lane else { return .offline }
    let address: String
    do { address = try BankDomains.normalizeTypedAddress(typed) } catch { return .refused(Self.senderLine(error, domain)) }
    guard BankDomains.isMember(BankDomains.domainOf(address), of: [domain]) else {
      return .refused(Self.senderLine(.notQuerySafe, domain, other: true))
    }
    switch await lane.addSender(address) {
    case .failure(let e): return .refused(Self.senderLine(e, domain))
    case .success:
      await rt.refreshMailbox()
      return unlistedSenders.contains(domain) ? .offline : .added(address)
    }
  }

  static func senderLine(_ e: BankDomains.TypedDomainError, _ domain: String, other: Bool = false) -> String {
    if other { return "Type an address that ends in @\(domain)." }
    switch e {
    case .empty, .addressRequired: return "Type the full address, such as alerts@\(domain)."
    case .forwarder: return "That's a personal email service. Type the address your bank sends from."
    case .sharedSuffix, .notQuerySafe: return "Hasala can't read that address. Check it and try again."
    case .nonASCII: return "Type it in English letters, as on the alert."
    }
  }

  func linkState() async -> OnboardingStep.Facts.Mailbox {
    guard let lane = runtime()?.lane else { return .unlinked }
    return BootController.mailboxFact(await lane.status().phase)
  }

  func lastEmail(_ bank: SupportedBank) -> String? {
    guard let rt = runtime(), let status = rt.store.readMailboxStatus else { return nil }
    return Self.lastEmail(bank, health: status.health, nowMs: rt.context.clock.nowMs())
  }

  var readThisMonth: MonthRead? {
    guard let rt = runtime(), let status = rt.store.readMailboxStatus else { return nil }
    return Self.readThisMonth(status.health, nowMs: rt.context.clock.nowMs())
  }

  static func lastEmail(_ bank: SupportedBank, health: [BankHealthRow], nowMs: Int64) -> String? {
    let domains = MailboxLane.senderDomains(bank: bank.rawValue)
    let newest = health.filter { BankDomains.isMember($0.domain, of: domains) }.compactMap(\.lastEmailAtMs).max()
    return newest.map { RelativeTime.ago(ms: nowMs - $0, nowMs: nowMs) }
  }

  static func readThisMonth(_ health: [BankHealthRow], nowMs: Int64) -> MonthRead? {
    guard let month = LocalClock.localMonth(nowMs) else { return nil }
    let count = health.filter { $0.month == month.description }.reduce(0) { $0 + $1.readThisMonth }
    guard count > 0 else { return nil }
    return MonthRead(count: count, month: YearMonth(month.year, month.month).name)
  }

  static func mailboxes(_ s: MailboxStatus, provider: MailProviderKind = .gmail, nowMs: Int64) -> [MailboxSnapshot] {
    mailboxes(phase: s.phase, halt: s.haltedOn, address: s.address, lastSuccessAtMs: s.lastSuccessAtMs,
              bankDomains: s.health.map(\.domain), provider: provider, nowMs: nowMs,
              pastMailSkipped: s.readFromMs != nil)
  }

  static func mailboxes(
    phase: MailboxPhase, halt: MailboxHaltCode?, address: String?, lastSuccessAtMs: Int64?, bankDomains: [String],
    provider: MailProviderKind = .gmail, nowMs: Int64, timeZone: TimeZone = localTimeZone,
    pastMailSkipped: Bool = false
  ) -> [MailboxSnapshot] {
    let checked = lastSuccessAtMs.map { "Checked \(RelativeTime.ago(ms: nowMs - $0, nowMs: nowMs))" } ?? "Not checked yet"
    var row = MailboxSnapshot(
      id: mailboxID(provider), provider: provider, address: address ?? provider.appName, state: .connected, meta: checked,
      accountKind: provider == .outlook ? "Personal Microsoft" : nil,
      banks: Set(bankDomains.compactMap { LedgerStateMapper.bankName(domain: $0) }).sorted(),
      lastChecked: lastSuccessAtMs.map { checkedAt($0, timeZone: timeZone) },
      pastMailSkipped: pastMailSkipped && phase == .active)
    switch phase {
    case .unlinked:
      return []
    case .scanning, .awaitingCards:
      row.state = .syncing
      row.meta = "Checking now"
    case .authoringBackfill, .active:
      break
    case .reconnectRequired:
      row.state = .needsSignIn
    case .halted:
      if offer(phase: .halted, halt: halt, sampleLoaded: false, serverLink: .noLink, provider: provider) != nil {
        row.state = .needsSignIn
        if halt == .noMailbox { row.note = message(.noMailbox, provider: provider) }
      } else {
        row.state = .readingStopped
      }
    case .otherDevice:
      row.note = otherIPhone
      row.readElsewhere = true
    }
    return [row]
  }

  static let otherIPhone = "Read on your other iPhone"

  static let localTimeZone = TimeZone(secondsFromGMT: Int(LocalClock.offsetMinutes) * 60) ?? .gmt

  static func checkedAt(_ ms: Int64, timeZone: TimeZone = localTimeZone) -> String {
    let format = Date.FormatStyle(date: .omitted, time: .omitted, locale: Locale(identifier: "en_GB"),
                                  calendar: Calendar(identifier: .gregorian), timeZone: timeZone)
    let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
    let day = date.formatted(format.weekday(.abbreviated).day(.defaultDigits).month(.abbreviated))
    let time = date.formatted(format.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    return "\(day), \(time)"
  }

  static func offerKnown(phase: MailboxPhase, sampleLoaded: Bool, serverLink: MailboxLinkStatus?) -> Bool {
    sampleLoaded || phase != .unlinked || serverLink != nil
  }

  static func offer(
    phase: MailboxPhase, halt: MailboxHaltCode? = nil, sampleLoaded: Bool, serverLink: MailboxLinkStatus?,
    provider: MailProviderKind = .gmail
  ) -> MailOffer? {
    guard !sampleLoaded else { return nil }
    let signInAgain = MailOffer.signInAgain(mailboxID: mailboxID(provider), provider: provider)
    switch phase {
    case .unlinked:
      switch serverLink {
      case .noLink?, .holder?: return .connect
      case nil: return nil
      }
    case .reconnectRequired: return signInAgain
    case .halted:
      switch halt {
      case .reconnectRequired?, .noMailbox?: return signInAgain
      default: return nil
      }
    case .scanning, .awaitingCards, .authoringBackfill, .active, .otherDevice: return nil
    }
  }

  static func checkTakeover(_ link: MailboxLinkStatus?, confirmed: Bool = false) throws(MailConnectFailure) {
    switch link {
    case .noLink?, .holder(true, _)?: return
    case .holder(false, _)?: if !confirmed { throw .takenByOtherIPhone }
    case nil: throw .offline
    }
  }

  static func banks(trusted: [String]) -> [SupportedBank] {
    SupportedBank.allCases.filter { bank in
      MailboxLane.senderDomains(bank: bank.rawValue).contains { trusted.contains($0) }
    }
  }

  private func lane() throws(MailConnectFailure) -> MailboxLane {
    guard let rt = runtime() else { throw .failed("Still opening your account. Try again in a moment.") }
    guard let lane = rt.lane else { throw .failed("Email isn't available in this build.") }
    return lane
  }

  static func admit(
    _ requested: MailProviderKind, current: MailProviderKind?, phase: MailboxPhase, address: String?,
    replacing: Bool
  ) throws(MailConnectFailure) -> Bool {
    switch phase {
    case .unlinked, .otherDevice:
      return false
    case .reconnectRequired, .halted:
      if requested == current { return false }
    case .scanning, .awaitingCards, .authoringBackfill, .active:
      if requested == current { throw .alreadyConnected(address: address ?? requested.appName) }
    }
    guard replacing else {
      throw .failed("Disconnect \(current?.appName ?? "your email") first, then connect \(requested.appName).")
    }
    return true
  }

  func connect(
    _ provider: MailProviderKind, replacing: Bool, removingOld: Bool, pastMail: MailPastChoice,
    ask: @escaping MailSwitchAsk
  ) async throws(MailConnectFailure) -> MailLinked {
    guard let rt = runtime() else { throw .failed("Still opening your account. Try again in a moment.") }
    guard let lane = rt.lanes[provider] else { throw .failed("\(provider.appName) isn't available in this build.") }
    if let refusal = Self.refusal(reviewAccount: rt.reviewAccount, holdsSample: rt.store.holdsSample) {
      throw .failed(refusal.message)
    }
    rt.connectStarted()
    defer { rt.connectEnded() }
    let current = rt.lane
    let status = await (current ?? lane).status()
    let replaces = try Self.admit(
      provider, current: current?.provider, phase: status.phase, address: status.address, replacing: replacing)
    var takesOver = false
    if Self.asksBeforeConnect(status.phase) {
      let link = await rt.askServerLink()
      try Self.checkTakeover(link, confirmed: replacing)
      if case .holder(false, _)? = link { takesOver = true }
    }
    let switching = current.map { $0.provider != provider } ?? false
    let days = MailboxEngine.backfillDays(
      newestImportMs: (try? rt.projection.reader.newestMailboxPostedMs()) ?? nil, nowMs: rt.context.clock.nowMs())
    let oldPlan = switching && replaces && removingOld ? await current?.retirePlan() : nil
    let retiring = oldPlan.flatMap { $0.total > 0 || !$0.countKnown ? $0 : nil }
    let oldName = status.address ?? current?.provider.appName ?? provider.appName
    let old = switching ? current : nil
    await old?.stop()
    let newest = (try? rt.projection.reader.newestMailboxPostedMs()) ?? nil
    let result = await lane.connect(
      backfillDays: days, pastMail: Self.connectPastMail(pastMail, takesOver: takesOver, newestImportMs: newest),
      replacing: replaces, retiring: retiring, confirm: Self.confirm(ask, provider: provider))
    let nowReading: String?
    do { nowReading = try Self.linked(result, provider: provider) } catch {
      await old?.resume(restartingCut: old === rt.lane)
      throw error
    }
    rt.linkedHere(provider)
    if switching, let old = current { await old.endGrant() }
    var retired = Self.retired(result)
    if let retiring { retired = await lane.retire(retiring) }
    await rt.refreshMailbox()
    let reads = await lane.status()
    if reads.phase == .active, reads.readFromMs != nil, reads.lastSuccessAtMs == nil {
      let scan = firstScan()
      Task { for await _ in scan {} }
    }
    return MailLinked(
      mailboxID: Self.mailboxID(provider), nowReading: nowReading, removal: Self.removal(retired, old: oldName))
  }

  static func connectPastMail(_ answer: MailPastChoice, takesOver: Bool, newestImportMs: Int64?) -> MailboxPastMail {
    pastMail(takesOver ? .newOnly : answer, takesOver: takesOver, newestImportMs: newestImportMs)
  }

  static func pastMail(_ choice: MailPastChoice, takesOver: Bool, newestImportMs: Int64?) -> MailboxPastMail {
    switch choice {
    case .importPast: .read
    case .newOnly: .skip(catchUpFromMs: takesOver ? newestImportMs : nil)
    }
  }

  static func confirm(_ ask: @escaping MailSwitchAsk, provider: MailProviderKind) -> MailboxSwitchConfirm {
    { question in await Self.asked(ask, question, provider: provider) }
  }

  static func asked(_ ask: MailSwitchAsk, _ q: MailboxSwitchQuestion, provider: MailProviderKind) async
    -> MailboxSwitchChoice
  {
    switch await ask(question(q, provider: provider)) {
    case .keep: .keep
    case .remove: .remove
    case .cancel: .cancel
    }
  }

  static func question(_ q: MailboxSwitchQuestion, provider: MailProviderKind) -> MailSwitchQuestion {
    MailSwitchQuestion(
      provider: provider, oldAddress: q.oldAddress, newAddress: q.newAddress,
      impact: q.transactions.flatMap { $0 > 0 ? MailboxDisconnectImpact(transactions: $0, edited: q.edited) : nil },
      oldHasNoMailbox: q.oldHasNoMailbox, countUnknown: q.transactions == nil)
  }

  static func retired(_ result: ConnectResult) -> MailboxRetireOutcome? {
    if case .connected(_, _, let retired) = result { return retired }
    return nil
  }

  static func removal(_ retired: MailboxRetireOutcome?, old: String) -> MailSwitchRemoval? {
    switch retired {
    case nil: nil
    case .removed(let n)?: .removed(n)
    case .failed?: .failed(from: old)
    }
  }

  func signInAgain(_ mailboxID: String, ask: @escaping MailSwitchAsk) async throws(MailConnectFailure) -> MailLinked {
    let fallback = try lane().provider
    let provider = MailProviderKind(rawValue: mailboxID) ?? fallback
    let linked = try await connect(provider, replacing: false, removingOld: false, pastMail: .importPast, ask: ask)
    guard await linkState() == .scanning else { return linked }
    Task { for await _ in firstScan() {} }
    return linked
  }

  func tryAgain(_ mailboxID: String) async {
    await runtime()?.retryMailbox()
  }

  func disconnect(_ mailboxID: String, removeTransactions: Bool) async throws(MailConnectFailure) {
    let lane = try lane()
    try Self.checkDisconnect(await lane.status().phase)
    let plan = removeTransactions ? await lane.retirePlan() : nil
    let outcome = await lane.disconnect(removing: plan)
    let rt = runtime()
    await rt?.refreshMailbox()
    if let rt {
      rt.unlinkedHere(outcome)
    } else {
      BankTextsLinkKeeper(nowMs: { SystemClock().nowMs() }).disconnected(outcome)
    }
    try Self.disconnected(outcome, provider: lane.provider)
  }

  var heldRemoval: MailHeldRemoval? {
    guard let plan = runtime()?.store.readMailboxStatus?.heldRetires.first else { return nil }
    return Self.heldRemoval(plan)
  }

  static func heldRemoval(_ plan: MailboxRetirePlan) -> MailHeldRemoval {
    MailHeldRemoval(
      address: plan.address ?? MailProviderKind(rawValue: plan.provider)?.appName ?? plan.provider,
      transactions: plan.countKnown ? plan.total : nil)
  }

  func removeHeld() async -> MailHeldRemovalOutcome {
    guard let rt = runtime(), let lane = rt.lane, let plan = rt.store.readMailboxStatus?.heldRetires.first else {
      return .failed
    }
    let outcome = await lane.retryHeld(plan)
    await rt.refreshMailbox()
    return Self.heldOutcome(outcome)
  }

  static func heldOutcome(_ outcome: MailboxHeldRetryOutcome) -> MailHeldRemovalOutcome {
    switch outcome {
    case .removed(let n): .removed(n)
    case .failed: .failed
    case .readElsewhere: .readElsewhere
    case .ended: .ended
    }
  }

  func keepHeld() async {
    guard let rt = runtime(), let lane = rt.lane, let plan = rt.store.readMailboxStatus?.heldRetires.first else { return }
    await lane.dropHeld(plan)
    await rt.refreshMailbox()
  }

  func disconnectImpact(_ mailboxID: String) async -> MailboxDisconnectImpact? {
    guard let lane = try? lane(), let plan = await lane.retirePlan(), plan.total > 0 else { return nil }
    return MailboxDisconnectImpact(transactions: plan.total, edited: plan.edited)
  }

  static func disconnected(_ outcome: MailboxDisconnectOutcome, provider: MailProviderKind) throws(MailConnectFailure) {
    switch outcome {
    case .disconnected, .removed: return
    case .otherDevice: throw .takenByOtherIPhone
    case .failed: throw .failed("Couldn't disconnect \(provider.appName). Try again.")
    case .disconnectedRemoveFailed:
      throw .failed("\(provider.appName) is disconnected, but its transactions couldn't be removed.")
    }
  }

  static func checkDisconnect(_ phase: MailboxPhase) throws(MailConnectFailure) {
    if phase == .otherDevice { throw .takenByOtherIPhone }
  }

  @discardableResult
  static func linked(_ result: ConnectResult, provider: MailProviderKind) throws(MailConnectFailure) -> String? {
    switch result {
    case .connected(let address, let another, _): return another ? address : nil
    case .cancelled: throw .cancelled
    case .declined: throw .switchDeclined
    case .failed(.offline): throw .offline
    case .failed(.noMailbox): throw .noMailbox(provider)
    case .failed(.permissionMissing): throw .permissionMissing(provider)
    case .failed(let f): throw .failed(message(f, provider: provider))
    }
  }

  func firstScan() -> AsyncStream<ScanProgress> {
    guard let lane = try? lane() else {
      return AsyncStream { c in
        c.yield(ScanProgress(phase: .failed("Your email isn't connected."), read: 0, total: 0))
        c.finish()
      }
    }
    let rt = runtime()
    return AsyncStream { continuation in
      Task {
        var last = ScanProgress(phase: .downloading, read: 0, total: 0)
        for await event in lane.firstScan() {
          switch event {
          case .progress(let p):
            last = Self.progress(p, provider: lane.provider)
            continuation.yield(last)
          case .ended(let t):
            continuation.yield(Self.ended(t, last: last, provider: lane.provider))
          }
        }
        await rt?.refreshMailbox()
        continuation.finish()
      }
    }
  }

  static func ended(_ t: MailboxLane.FirstScanTotals, last: ScanProgress, provider: MailProviderKind) -> ScanProgress {
    let summary = SortSummary(
      total: t.ops, byRules: t.byRules, byDictionary: t.byDictionary, byModel: t.byModel, toReview: t.toReview)
    switch t.phase {
    case .active:
      return ScanProgress(phase: .finished, read: last.total, total: last.total, summary: summary)
    case .halted, .reconnectRequired, .otherDevice:
      return ScanProgress(
        phase: .failed(stopped(t.haltedOn, provider: provider)), read: last.read, total: last.total, summary: summary)
    case .unlinked, .scanning, .awaitingCards, .authoringBackfill:
      return ScanProgress(phase: .background, read: last.read, total: last.total, summary: summary)
    }
  }

  func loadSampleData() async throws(SetupFailure) {
    guard let rt = runtime() else { throw .failed("Still opening your account. Try again in a moment.") }
    try await rt.loadSample()
  }

  static func progress(_ p: MailboxProgress, provider: MailProviderKind) -> ScanProgress {
    switch p.stage {
    case .listing, .downloading: ScanProgress(phase: .downloading, read: p.done, total: p.total)
    case .authoring: ScanProgress(phase: .sorting, read: p.done, total: p.total)
    case .done: ScanProgress(phase: .finished, read: p.total, total: p.total)
    case .failed(let code): ScanProgress(phase: .failed(stopped(code, provider: provider)), read: p.done, total: p.total)
    }
  }

  static func stopped(_ code: MailboxHaltCode?, provider: MailProviderKind) -> String {
    code == .noMailbox ? message(.noMailbox, provider: provider) : "Reading your bank alerts stopped. Try again."
  }

  static func message(_ f: ConnectFailure, provider: MailProviderKind = .gmail) -> String {
    switch f {
    case .offline: "You're offline. Connect \(provider.appName) when you're back online."
    case .permissionMissing: MailConnectFailure.permissionMissingLine(provider)
    case .noMailbox: MailConnectFailure.noMailboxLine(provider)
    case .stepUpFailed: "We couldn't confirm it's you. Try again."
    case .mailboxInUse:
      "This \(provider.appName) address is connected to another Hasala account. Disconnect it there, or use another address."
    case .notConfigured: "\(provider.appName) isn't available in this build."
    case .stateMismatch, .nonceMismatch, .serverRefused, .keychain, .google:
      provider == .outlook
        ? "Couldn't connect Outlook. Only personal Microsoft accounts work. Try again."
        : "Couldn't connect Gmail. Try again."
    }
  }

  #if DEBUG
    struct OutlookTrustSource: Sendable {
      let graph: GraphClient
      let groups: [[String]]
    }

    func outlookTrustSource() async -> OutlookTrustSource? {
      guard let rt = runtime(), let lane = rt.lanes[.outlook] else { return nil }
      let trusted = BankDomains.effectiveTrusted((try? rt.projection.reader.senderTrust()) ?? [:])
      let groups = BankDomains.groups(trusted, size: GraphClient.maxDomainsPerList).filter { !$0.isEmpty }
      guard !groups.isEmpty, let token = try? await lane.tokens.accessToken(forceRefresh: false)
      else { return nil }
      let graph = GraphClient(
        http: URLSessionHTTPExchange.ephemeral(maxResponseBytes: MailboxLimits.maxResponseBytes), accessToken: token.value,
        link: MemoryOutlookLinkStore(),
        knownSenders: OutlookSenders.known + (await lane.engine.senderAddresses()), nowMs: { SystemClock().nowMs() })
      return OutlookTrustSource(graph: graph, groups: groups)
    }
  #endif
}
