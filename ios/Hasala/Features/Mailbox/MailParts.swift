import HasalaDesign
import HasalaModels
import SwiftUI

enum MailCopy {
  static let sampleDataRefusal = "This account shows sample data and can't read email."
  static let reviewAccountRefusal = "This App Review account can't read your email."

  static func banks(_ banks: [SupportedBank]) -> String {
    banks.map(\.shortName).formatted(.list(type: .and))
  }

  static var readNote: String {
    BuildSurface.showsUnfinished
      ? "Our server is told when new mail arrives, never what it says."
      : "New alerts are checked when you open Hasala, and sometimes in the background."
  }

  static let confirmNote = "You'll confirm it's you before it connects."

  static let readingStopped = "Reading your bank alerts stopped."

  static let pastMailTitle = "Import your past email?"

  static func pastWindow(days: Int) -> String { days >= 365 ? "the last year" : "the last \(days) days" }

  static func pastMailMessage(days: Int) -> String {
    "Hasala can read \(pastWindow(days: days)) of bank alerts, now or later in Bank alerts."
  }

  static func pastMailSkippedDetail(days: Int) -> String {
    "Import reads the \(days >= 365 ? "year" : "\(days) days") before you connected."
  }

  static func pastImported(_ count: Int) -> String {
    count == 1 ? "1 past transaction added." : "\(MoneyFormat.count(count)) past transactions added."
  }

  static let pastImportLater = "Reading your past email in the background."

  static let mailboxesFootnote = "Read-only, on this iPhone."

  static var mailboxesFootnoteDetail: String {
    BuildSurface.showsUnfinished
      ? "Our server keeps only a code for each mailbox, made with a secret key. It sees when mail arrives, never the mail."
      : "Our server keeps only a code for each mailbox, made with a secret key. It never sees your mail."
  }

  static func signedInAgain(
    _ provider: MailProviderKind, nowReading address: String? = nil, removal: MailSwitchRemoval? = nil
  ) -> String {
    guard let address else { return "\(provider.appName) connected again. Catching up." }
    return with("Now reading \(address).", removal)
  }

  static func added(_ provider: MailProviderKind, removal: MailSwitchRemoval? = nil) -> String {
    with("\(provider.appName) connected. Checking for alerts.", removal)
  }

  static func with(_ line: String, _ removal: MailSwitchRemoval?) -> String {
    switch removal {
    case nil: line
    case .removed(let n?)?: "\(line) \(removed(n))"
    case .removed(nil)?: "\(line) The old transactions were removed."
    case .failed(let old)?: "\(line) Transactions from \(old) couldn't be removed."
    }
  }

  static func removed(_ n: Int) -> String {
    n == 1 ? "1 transaction removed." : "\(MoneyFormat.count(n)) transactions removed."
  }

  static func heldRemovalTitle(_ held: MailHeldRemoval) -> String {
    switch held.transactions {
    case 1?: "1 transaction wasn't removed"
    case let n?: "\(MoneyFormat.count(n)) transactions weren't removed"
    case nil: "Transactions weren't removed"
    }
  }

  static func heldRemovalDetail(_ held: MailHeldRemoval) -> String {
    let still = held.transactions == 1 ? "It still counts" : "They still count"
    return "From \(held.address), which you disconnected. \(still) in your totals."
  }

  static func heldRemovalLine(_ outcome: MailHeldRemovalOutcome, _ held: MailHeldRemoval) -> String? {
    switch outcome {
    case .removed(let n?): removed(n)
    case .removed(nil): "The old transactions were removed."
    case .failed: "Transactions from \(held.address) couldn't be removed."
    case .readElsewhere: MailConnectFailure.readOnOtherIPhone
    case .ended: nil
    }
  }

  static func impactLines(_ impact: MailboxDisconnectImpact, from source: String = "It") -> [String] {
    let one = impact.transactions == 1
    let count = one ? "1 transaction" : "\(MoneyFormat.count(impact.transactions)) transactions"
    let choice = one ? "Keep it, or remove it from your totals." : "Keep them, or remove them from your totals."
    var lines = ["\(source) brought in \(count). \(choice)"]
    if impact.edited > 0 {
      lines.append(
        impact.edited == 1
          ? "Removing also takes the 1 you changed." : "Removing also takes the \(MoneyFormat.count(impact.edited)) you changed.")
    }
    return lines
  }

  static func switchAddressTitle(_ q: MailSwitchQuestion) -> String {
    "You signed in as \(q.newAddress)."
  }

  static func switchAddressMessage(_ q: MailSwitchQuestion) -> String {
    let lead = q.oldHasNoMailbox
      ? "\(q.oldAddress) has no mailbox Hasala can read. Switch to \(q.newAddress)?"
      : "Hasala reads \(q.oldAddress). Switch to \(q.newAddress)?"
    var lines = [lead]
    if let impact = q.impact {
      lines += impactLines(impact, from: q.oldAddress)
    } else if q.countUnknown {
      lines.append("Keep the transactions from \(q.oldAddress), or remove them from your totals.")
    }
    return lines.joined(separator: " ")
  }

  static func keepOnSwitch(_ lead: String, _ impact: MailboxDisconnectImpact) -> String {
    impact.transactions == 1
      ? "\(lead), keep the 1 transaction" : "\(lead), keep the \(MoneyFormat.count(impact.transactions)) transactions"
  }

  static func removeTitle(_ impact: MailboxDisconnectImpact?, lead: String? = nil) -> String {
    let them = impact?.transactions == 1 ? "it" : "them"
    return lead.map { "\($0), remove \(them)" } ?? "Remove \(them)"
  }

  static func consentPage(_ provider: MailProviderKind) -> String {
    switch provider {
    case .gmail: "myaccount.google.com/permissions"
    case .outlook: "account.live.com/consent/Manage"
    }
  }

  static let switchTitle = "Change your email?"

  static func switchMessage(
    from old: MailProviderKind, to new: MailProviderKind, impact: MailboxDisconnectImpact? = nil
  ) -> String {
    let lead = "Hasala reads your bank alerts from \(new.appName) instead of \(old.appName)."
    guard let impact else { return "\(lead) Past transactions stay." }
    return ([lead] + impactLines(impact)).joined(separator: " ")
  }

  static let takeoverTitle = "Read your email on this iPhone?"

  static func takeoverMessage(from held: MailProviderKind, to new: MailProviderKind) -> String {
    let reads = held == new ? "" : ", and this iPhone reads \(new.appName)"
    return "Another iPhone reads your \(held.appName), maybe one you no longer have. It stops\(reads). Past transactions stay."
  }

  static func disconnectLead(_ address: String) -> String {
    "Hasala stops reading \(address) and deletes its sign-in from this iPhone."
  }

  static let disconnectPlainMessage = "Hasala stops reading it and deletes its sign-in from this iPhone."

  static func keepTransactions(_ impact: MailboxDisconnectImpact) -> String {
    impact.transactions == 1 ? "Keep the 1 transaction" : "Keep the \(MoneyFormat.count(impact.transactions)) transactions"
  }

  static func removeTransactions(_ impact: MailboxDisconnectImpact) -> String {
    impact.transactions == 1
      ? "Remove the 1 transaction" : "Remove the \(MoneyFormat.count(impact.transactions)) transactions"
  }

  static func removeDetail(_ impact: MailboxDisconnectImpact) -> String {
    let after = "Can't be undone here. An encrypted record stays until you delete your account."
    if impact.transactions == 1 {
      return "Takes it out of your lists and totals. \(after)"
    }
    guard impact.edited > 0 else { return "Takes them out of your lists and totals. \(after)" }
    return "Takes them out of your lists and totals, with the \(MoneyFormat.count(impact.edited)) you changed. \(after)"
  }

  static func permissionsTitle(_ provider: MailProviderKind) -> String {
    switch provider {
    case .gmail: "Check Google's permissions"
    case .outlook: "Remove the permission at Microsoft"
    }
  }

  static func consentURL(_ provider: MailProviderKind) -> URL {
    URL(string: "https://\(consentPage(provider))")!
  }

  static func disconnected(_ provider: MailProviderKind, removed: Int?) -> String {
    guard let removed else { return "\(provider.appName) disconnected. Past transactions stay." }
    return "\(provider.appName) disconnected. \(Self.removed(removed))"
  }
}

enum MailboxMoment: Equatable {
  case added(mailboxID: String)
  case signedInAgain(mailboxID: String)

  private(set) static var pending: MailboxMoment?

  static func hand(_ moment: MailboxMoment) {
    pending = moment
  }

  static func hand(_ moment: MailboxMoment, to router: AppRouter) {
    guard router.sheet == .profile, router.profile.last != .bankAlerts else { return }
    hand(moment)
  }

  static func discard() {
    pending = nil
  }

  static func take() -> MailboxMoment? {
    defer { pending = nil }
    return pending
  }

  static var pendingAddition: String? {
    if case .added(let id)? = pending { return id }
    return nil
  }
}

extension AppRouter {
  func backToBankAlerts() {
    if let i = profile.lastIndex(of: .bankAlerts) {
      profile.removeSubrange((i + 1)...)
    } else {
      profile = [.bankAlerts]
    }
  }
}

extension MailboxSnapshot {
  func reads(_ bank: SupportedBank) -> Bool {
    banks.contains { $0 == bank.name || $0 == bank.shortName }
  }
}

extension MotionPolicy {
  func settleDelay(_ kind: HMotion.Kind) -> Duration {
    .seconds(curve(kind)?.nominalDuration ?? 0)
  }
}

struct PaperGlyph: View {
  struct Part {
    let d: String
    var fill = false
  }

  static let check = [Part(d: "M5.5 12.5l4.2 4.2 8.8-9.2")]
  static let alert = [Part(d: "M12 7.5v5.5"), Part(d: "M13.4 17a1.4 1.4 0 1 1-2.8 0a1.4 1.4 0 1 1 2.8 0Z", fill: true)]
  static let link = [
    Part(d: "M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1.2 1.2"),
    Part(d: "M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1.2-1.2"),
  ]
  static let eyeOff = [
    Part(d: "M3.5 3.5l17 17"),
    Part(d: "M10.4 5.1A9.6 9.6 0 0 1 12 5c5 0 8.4 4.1 9.4 7-.4 1.1-1.2 2.4-2.3 3.6M6.7 6.7C4.7 8 3.2 9.9 2.6 12c1 2.9 4.4 7 9.4 7 1.8 0 3.4-.5 4.8-1.3"),
    Part(d: "M9.9 9.9a3 3 0 0 0 4.2 4.2"),
  ]
  static let plus = [Part(d: "M12 5v14M5 12h14")]
  static let tick = [Part(d: "m5 12.5 4.5 4.5L19 7.5")]
  static let dash = [Part(d: "M6 12h12")]

  let parts: [Part]
  let size: CGFloat
  let color: Color
  let lineWidth: CGFloat

  init(_ parts: [Part], size: CGFloat, color: Color, lineWidth: CGFloat) {
    self.parts = parts
    self.size = size
    self.color = color
    self.lineWidth = lineWidth
  }

  var body: some View {
    let parsed = parts.compactMap { part in (try? SVGPath(parsing: part.d)).map { (svg: $0, fill: part.fill) } }
    Canvas { context, canvas in
      let box = CGRect(origin: .zero, size: canvas)
      let unit = min(canvas.width, canvas.height) / 24
      for part in parsed {
        let path = part.svg.path(in: box)
        if part.fill {
          context.fill(path, with: .color(color))
        } else {
          context.stroke(path, with: .color(color),
                         style: StrokeStyle(lineWidth: lineWidth * unit, lineCap: .round, lineJoin: .round))
        }
      }
    }
    .frame(width: size, height: size)
    .accessibilityHidden(true)
  }
}

struct FlowStrip: View {
  let provider: MailProviderKind
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    let layout = typeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
      : AnyLayout(HStackLayout(spacing: 0))
    layout {
      chip(title: provider.appName, detail: "Read-only", lifted: false) {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(Hue.sky.perceptualGradient)
          .frame(width: 36, height: 36)
          .overlay { HIconView(.envelope, size: 20, color: Hue.sky.ink, strokeWidth: 1.9) }
      }
      arrow
      chip(title: "This iPhone", detail: "Reads and sorts", lifted: true) {
        AppIconTile(size: 36, radius: 10)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("From \(provider.appName), read-only, to this iPhone, which reads and sorts")
  }

  private var arrow: some View {
    Canvas { context, _ in
      var dots = Path()
      dots.move(to: CGPoint(x: 2, y: 6))
      dots.addLine(to: CGPoint(x: 23, y: 6))
      context.stroke(dots, with: .color(HColor.blue400),
                     style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [0, 5]))
      var head = Path()
      head.move(to: CGPoint(x: 22, y: 2))
      head.addLine(to: CGPoint(x: 27, y: 6))
      head.addLine(to: CGPoint(x: 22, y: 10))
      context.stroke(head, with: .color(HColor.blue600),
                     style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
    }
    .frame(width: 30, height: 12)
    .frame(width: 36)
    .rotationEffect(typeSize.isAccessibilitySize ? .degrees(90) : .zero)
    .padding(.leading, typeSize.isAccessibilitySize ? 16 : 0)
  }

  private func chip(title: String, detail: String, lifted: Bool, @ViewBuilder tile: () -> some View) -> some View {
    HStack(spacing: 8) {
      tile()
      VStack(alignment: .leading, spacing: 0) {
        Text(title).hType(.subheadline.weight(.semibold)).foregroundStyle(HColor.textPrimary)
        Text(detail).hType(HType(size: 12, leading: 16, weight: .regular, textStyle: .caption))
          .foregroundStyle(HColor.textSecondary)
      }
      .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .padding(.vertical, 10)
    .padding(.leading, 8)
    .padding(.trailing, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .shadow(color: Color(HRGBA(0, 0, 0, 0.04)), radius: 1, x: 0, y: 1)
    .shadow(color: lifted ? Color(HRGBA(30, 42, 94, 0.08)) : .clear, radius: 10, x: 0, y: 8)
  }
}

struct ReadsNeverCard: View {
  let banks: [SupportedBank]

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 8) {
        Text("Hasala reads").hType(.overline).foregroundStyle(HColor.statusSuccessForeground)
          .accessibilityAddTraits(.isHeader)
        item("Alerts from \(MailCopy.banks(banks)), and nothing else", reads: true)
        item("Downloaded and read here, on this iPhone", reads: true)
      }
      HColor.borderSubtle.frame(height: 1).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 8) {
        Text("Never").hType(.overline).foregroundStyle(HColor.textSecondary)
          .accessibilityAddTraits(.isHeader)
        item("Downloading the rest of your inbox", reads: false)
        item("Sending, deleting or changing your email", reads: false)
        item("Passing your emails to our server or an AI service", reads: false)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.listGroup, style: .continuous))
  }

  private func item(_ text: String, reads: Bool) -> some View {
    HStack(alignment: .top, spacing: 9) {
      Circle()
        .fill(reads ? HColor.statusSuccessSurface : HColor.surfaceSecondary)
        .frame(width: 20, height: 20)
        .overlay {
          PaperGlyph(reads ? PaperGlyph.tick : PaperGlyph.dash, size: 12,
                     color: reads ? HColor.statusSuccessForeground : HColor.textSecondary, lineWidth: 3)
        }
      Text(text).hType(.subheadline).foregroundStyle(HColor.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(text)
  }
}

struct TextLinkRow: View {
  var lead: String?
  var link: String
  var identifier: String
  var busy = false
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      TextLinkLabel(lead: lead, link: link)
        .opacity(busy ? 0 : 1)
        .overlay { if busy { Spinner(size: 20) } }
    }
    .buttonStyle(.plain)
    .disabled(busy)
    .accessibilityLabel([lead, link].compactMap { $0 }.joined(separator: " "))
    .accessibilityValue(busy ? "In progress" : "")
    .accessibilityIdentifier(identifier)
  }
}

struct TellUsWhichLink: View {
  var small = false
  var leading = false
  @State private var textHeight: CGFloat = 0

  static let label = "Use another email service? Email us."
  static let lead = "Use another email service?"
  static let link = "Email us."

  static let mail: URL = {
    var parts = URLComponents()
    parts.scheme = "mailto"
    parts.path = BuildSurface.supportEmail
    parts.queryItems = [URLQueryItem(name: "subject", value: "Another email for my bank alerts")]
    return parts.url ?? BuildSurface.supportMail
  }()

  var body: some View {
    Link(destination: Self.mail) {
      if small {
        Text("\(Self.label)\u{00A0}\(Image(systemName: "arrow.up.right"))")
          .hType(HType.footnote.weight(.semibold))
          .foregroundStyle(HColor.textLink)
          .multilineTextAlignment(leading ? .leading : .center)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: leading ? .leading : .center)
          .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { textHeight = $0 }
          .frame(minHeight: HSpacing.targetMinimum)
          .contentShape(Rectangle())
      } else {
        TextLinkLabel(lead: Self.lead, link: Self.link, leading: leading, external: true)
      }
    }
    .accessibilityLabel(Self.label)
    .accessibilityHint("Opens Mail")
    .accessibilityAddTraits(.isLink)
    .accessibilityIdentifier("mail.choose.other")
    .padding(.vertical, small && textHeight > 0 ? -max(0, HSpacing.targetMinimum - textHeight) / 2 : 0)
  }
}

private struct TextLinkLabel: View {
  let lead: String?
  let link: String
  var leading = false
  var external = false
  @Environment(\.dynamicTypeSize) private var typeSize
  @Environment(\.legibilityWeight) private var legibilityWeight

  var body: some View {
    Self.text(lead: lead, link: link, wholeLink: !typeSize.isAccessibilitySize, boldText: legibilityWeight == .bold,
              external: external)
      .hType(.subheadline)
      .foregroundStyle(HColor.textSecondary)
      .multilineTextAlignment(leading ? .leading : .center)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, minHeight: HSpacing.targetMinimum, alignment: leading ? .leading : .center)
      .contentShape(Rectangle())
  }

  static func text(lead: String?, link: String, wholeLink: Bool, boldText: Bool, external: Bool = false) -> Text {
    let weight: HWeight = boldText ? HWeight.semibold.bolder : .semibold
    let words = wholeLink ? link.replacingOccurrences(of: " ", with: "\u{00A0}") : link
    let glyph = external ? Text("\u{00A0}\(Image(systemName: "arrow.up.right"))") : Text(verbatim: "")
    let run = Text("\(Text(words))\(glyph)").font(HType.subheadline.weight(weight).font).foregroundStyle(HColor.textLink)
    guard let lead else { return run }
    return Text("\(lead) \(run)")
  }
}

extension View {
  func dockPill() -> some View { fixedSize(horizontal: false, vertical: true) }
}

struct MailReasonsCard: View {
  struct Item: Hashable {
    let title: String
    let detail: String
  }

  let title: String
  let items: [Item]
  let numbered: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(title)
        .hType(HType(size: 13, leading: 18, weight: .bold, trackingEm: 0.06, uppercase: true, textStyle: .footnote))
        .foregroundStyle(HColor.textSecondary)
        .accessibilityAddTraits(.isHeader)
      ForEach(Array(items.enumerated()), id: \.element) { i, item in
        HStack(alignment: .top, spacing: 12) {
          if numbered {
            Circle().fill(HColor.statusInfoSurface).frame(width: 24, height: 24)
              .overlay {
                Text(verbatim: "\(i + 1)")
                  .font(.custom(HWeight.bold.interFace, size: 13))
                  .foregroundStyle(HColor.statusInfoForeground)
              }
              .accessibilityHidden(true)
          }
          VStack(alignment: .leading, spacing: 2) {
            Text(item.title).hType(.rowTitle).foregroundStyle(HColor.textPrimary)
            Text(item.detail).hType(HType(size: 14, leading: 20, weight: .regular, textStyle: .subheadline))
              .foregroundStyle(HColor.textSecondary)
          }
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
      }
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
  }
}

struct MailActionRow: View {
  let title: String
  let identifier: String
  var glyph = PaperGlyph.plus
  var icon: HIcon?
  var detail: String?
  var busy = false
  let action: () -> Void
  @Environment(\.isEnabled) private var isEnabled

  var body: some View {
    let ink = isEnabled || busy ? HColor.textLink : HColor.textDisabled
    Button(action: action) {
      HStack(spacing: HSpacing.listRowGap) {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(HColor.actionAccentSubtle)
          .frame(width: 40, height: 40)
          .overlay {
            if busy {
              Spinner(size: 20)
            } else if let icon {
              HIconView(icon, size: 18, color: ink, strokeWidth: 2)
            } else {
              PaperGlyph(glyph, size: 18, color: ink, lineWidth: 2.4)
            }
          }
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(title).hType(.rowTitle).foregroundStyle(ink)
          if let detail {
            Text(detail).hType(.footnote).foregroundStyle(HColor.listRowSupporting)
          }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.horizontal, HSpacing.listRowInsetInline)
      .padding(.vertical, 8)
      .frame(minHeight: 56)
      .contentShape(Rectangle())
    }
    .buttonStyle(HRowPressStyle())
    .accessibilityValue(busy ? "In progress" : "")
    .accessibilityIdentifier(identifier)
  }
}

struct BankAlertsBankRow: View {
  let bank: SupportedBank
  let detail: String

  var body: some View {
    ReflowingRow(spacing: HSpacing.listRowGap) {
      HStack(spacing: HSpacing.listRowGap) {
        BankPlate(initials: bank.monogram, hue: bank == .enbd ? .sky : bank == .adib ? .lilac : .sand)
        VStack(alignment: .leading, spacing: 2) {
          Text(bank.name).hType(.rowTitle).foregroundStyle(HColor.textPrimary)
          Text(detail).hType(.footnote).foregroundStyle(HColor.listRowSupporting)
        }
        .fixedSize(horizontal: false, vertical: true)
      }
    } trailing: {
      Circle().fill(HColor.statusSuccessSurface).frame(width: 24, height: 24)
        .overlay { PaperGlyph(PaperGlyph.check, size: 14, color: HColor.statusSuccessForeground, lineWidth: 3) }
    }
    .padding(.horizontal, HSpacing.listRowInsetInline)
    .padding(.vertical, HSpacing.listRowInsetBlock)
    .frame(minHeight: HSpacing.listRowMinHeightTwoLine)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(bank.name), \(detail)")
    .accessibilityValue("Read")
  }
}

private struct MailSwitchQuestionAlert: ViewModifier {
  let coordinator: MailConnectCoordinator?
  let asks: Bool
  @State private var shown = false
  @State private var attached: MailConnectCoordinator?
  @Environment(\.scenePhase) private var scenePhase

  private func sync() {
    let wanted = shown && asks ? coordinator : nil
    guard attached !== wanted else { return }
    attached?.detachPresenter()
    wanted?.attachPresenter()
    attached = wanted
  }

  func body(content: Content) -> some View {
    let question = asks ? coordinator?.question : nil
    content
      .alert(
        question.map(MailCopy.switchAddressTitle) ?? "",
        isPresented: Binding(get: { question != nil }, set: { _ in }), presenting: question
      ) { q in
        if q.offersRemove {
          Button(q.impact.map { MailCopy.keepOnSwitch("Switch", $0) } ?? "Switch, keep its transactions") {
            coordinator?.answer(.keep)
          }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("mail.switch.keep")
          Button(MailCopy.removeTitle(q.impact, lead: "Switch"), role: .destructive) { coordinator?.answer(.remove) }
            .accessibilityIdentifier("mail.switch.remove")
        } else {
          Button("Switch to this address") { coordinator?.answer(.keep) }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("mail.switch.keep")
        }
        Button(q.oldHasNoMailbox ? "Cancel" : "Try again", role: .cancel) { coordinator?.answer(.cancel) }
          .accessibilityIdentifier("mail.switch.cancel")
      } message: { q in
        Text(MailCopy.switchAddressMessage(q))
      }
      .onAppear {
        shown = true
        sync()
      }
      .onDisappear {
        shown = false
        sync()
      }
      .onChange(of: coordinator.map(ObjectIdentifier.init)) { sync() }
      .onChange(of: asks) { sync() }
      .onChange(of: scenePhase) { _, phase in
        if phase != .active { attached?.leftForeground() }
      }
  }
}

extension View {
  func mailSwitchQuestion(_ coordinator: MailConnectCoordinator?, asks: Bool = true) -> some View {
    modifier(MailSwitchQuestionAlert(coordinator: coordinator, asks: asks))
  }
}

struct HeldRemovalRow: View {
  let app: AppModel
  let lane: any MailboxConnecting
  let held: MailHeldRemoval
  @State private var settling = false
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    HStack(alignment: .top, spacing: HSpacing.listRowGap) {
      Circle().fill(HColor.statusWarningSurface).frame(width: 40, height: 40)
        .overlay { HIconView(.trash, size: 20, color: HColor.statusWarningForeground, strokeWidth: 1.9) }
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 7) {
          Circle().fill(HColor.paceFillOverPace).frame(width: 8, height: 8).accessibilityHidden(true)
          Text(MailCopy.heldRemovalTitle(held)).hType(.rowTitle).foregroundStyle(HColor.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Text(MailCopy.heldRemovalDetail(held)).hType(.footnote).foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
        let actions = typeSize.isAccessibilitySize
          ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0)) : AnyLayout(HStackLayout(spacing: 24))
        actions {
          Button("Remove them") { remove() }
            .foregroundStyle(HColor.textLink)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityIdentifier("bankAlerts.heldRemoval.remove")
          Button("Keep them") { keep() }
            .foregroundStyle(HColor.textSecondary)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityIdentifier("bankAlerts.heldRemoval.keep")
        }
        .hType(.subheadline.weight(.semibold))
        .buttonStyle(.plain)
        .disabled(settling)
        .padding(.top, -4)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, HSpacing.listRowInsetInline)
    .padding(.top, 14)
    .padding(.bottom, 2)
    .frame(minHeight: HSpacing.listRowMinHeightTwoLine)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("bankAlerts.heldRemoval")
  }

  private func remove() {
    guard !settling else { return }
    settling = true
    Task {
      defer { settling = false }
      let outcome = await lane.removeHeld()
      guard let line = MailCopy.heldRemovalLine(outcome, held) else { return }
      if case .removed = outcome { app.say(line) } else { app.say(line, icon: .info) }
    }
  }

  private func keep() {
    guard !settling else { return }
    settling = true
    Task {
      defer { settling = false }
      await lane.keepHeld()
    }
  }
}
