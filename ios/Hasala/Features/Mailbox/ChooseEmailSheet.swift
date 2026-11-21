import HasalaDesign
import HasalaModels
import SwiftUI

enum ChooseEmailTitle: Sendable {
  case setup
  case addMailbox
  case change

  var title: String {
    switch self {
    case .setup: "Choose your email"
    case .addMailbox: "Add a mailbox"
    case .change: "Use another email"
    }
  }

  func subtitle(oneLink: Bool) -> String {
    let setup = "Pick where your bank sends alerts. \(Self.notSignIn) Read-only, on this iPhone."
    switch self {
    case .setup, .change: return setup
    case .addMailbox:
      return oneLink ? setup : "Pick another email your bank sends alerts to. \(Self.notSignIn) Read-only, on this iPhone."
    }
  }

  static let notSignIn = "It can differ from your Hasala sign-in email."

  func footnote(oneLink: Bool) -> String {
    switch self {
    case .setup:
      oneLink
        ? "Change it later in Profile › Bank alerts."
        : "You can add another mailbox later in Profile › Bank alerts."
    case .addMailbox:
      oneLink ? "You can disconnect it at any time." : "You can disconnect each one separately."
    case .change: "Your pick replaces the current mailbox. You choose whether its transactions stay."
    }
  }
}

struct ChooseEmailSheet: View {
  let mailbox: MailboxConnecting
  let title: ChooseEmailTitle
  var onPick: (MailProviderKind) -> Void
  @State private var height: CGFloat = 0
  @Environment(\.dismiss) private var dismiss

  init(mailbox: MailboxConnecting, title: ChooseEmailTitle, onPick: @escaping (MailProviderKind) -> Void) {
    self.mailbox = mailbox
    self.title = title
    self.onPick = onPick
  }

  var body: some View {
    switch title {
    case .setup: sheet
    case .addMailbox, .change: page
    }
  }

  private var sheet: some View {
    ScrollView {
      content(headingTop: 43)
        .padding(.horizontal, HSpacing.sheetPadding)
        .padding(.bottom, 14)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
    }
    .scrollBounceBehavior(.basedOnSize)
    .background(HColor.sheetSurfaceLarge)
    .presentationDetents(height > 0 ? [.height(height)] : [.medium])
    .presentationDragIndicator(.visible)
    .presentationCornerRadius(HRadius.sheetLarge)
    .presentationBackground(HColor.sheetSurfaceLarge)
    .accessibilityIdentifier("mail.choose")
  }

  private var page: some View {
    ScrollView {
      content(headingTop: 8)
        .padding(.horizontal, HSpacing.insetPage)
        .padding(.bottom, 32)
    }
    .scrollBounceBehavior(.basedOnSize)
    .background(HColor.surfaceSecondary)
    .navigationTitle("")
    .navigationBarTitleDisplayMode(.inline)
    .accessibilityIdentifier("mail.choose")
  }

  private func content(headingTop: CGFloat) -> some View {
    VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 8) {
        Text(title.title)
          .hType(HType(size: 28, leading: 34, weight: .bold, tracking: -0.5, textStyle: .title))
          .foregroundStyle(HColor.textPrimary)
          .accessibilityAddTraits(.isHeader)
        Text(title.subtitle(oneLink: mailbox.holdsOneLink)).hType(.callout).foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.top, headingTop)
      HListCard {
        ForEach(Array(mailbox.connectable.enumerated()), id: \.element) { i, provider in
          if i > 0 { HDivider(inset: .disc68) }
          ProviderRow(provider: provider, subtitle: Self.subtitle(
            provider, mailboxes: mailbox.mailboxes, offer: title == .setup ? nil : mailbox.offer,
            oneLink: mailbox.holdsOneLink)) {
            pick(provider)
          }
            .accessibilityIdentifier("mail.choose.\(provider.rawValue)")
        }
      }
      VStack(alignment: .leading, spacing: 6) {
        Text(title.footnote(oneLink: mailbox.holdsOneLink)).hType(.footnote).foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
        TellUsWhichLink(small: true, leading: true)
      }
      .padding(.horizontal, 4)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  static func subtitle(
    _ provider: MailProviderKind, mailboxes: [MailboxSnapshot], offer: MailOffer? = nil, oneLink: Bool = false
  ) -> String? {
    let own = mailboxes.filter { $0.provider == provider }
    if case .signInAgain(let id) = ConnectMailPage.context(provider, offer: offer),
       let broken = own.first(where: { $0.id == id }) {
      return "Sign in to \(broken.address) again."
    }
    if let connected = own.first(where: { [.connected, .syncing, .readingStopped].contains($0.state) }) {
      return oneLink
        ? "\(connected.address) is connected." : "\(connected.address) is connected. Add another \(provider.company) account."
    }
    if let broken = own.first(where: { $0.state == .needsSignIn }) {
      return "\(broken.address) needs a new sign-in."
    }
    return nil
  }

  private func pick(_ provider: MailProviderKind) {
    if title == .setup { dismiss() }
    onPick(provider)
  }
}
