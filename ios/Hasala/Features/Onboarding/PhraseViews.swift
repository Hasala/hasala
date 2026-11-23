import HasalaDesign
import HasalaModels
import SwiftUI
import UIKit

struct PhraseIntroView: View {
  var model: SignupModel

  static func onlyYouHaveThem(wordsOnlyInSetup: Bool) -> String {
    let setup = wordsOnlyInSetup ? " You'll see them only during setup." : ""
    return "We can't reset or resend them.\(setup) Lose them and every device that can unlock Hasala, and your data is gone for good."
  }

  static let keyDetail = "Only your devices hold your data's key. We never see it or these words."

  var body: some View {
    AccountScreen(
      title: "Your recovery phrase is your spare key",
      subtitle: "These 12 words can rebuild the key that locks your data.",
      steps: (3, 3)
    ) {
      VStack(alignment: .leading, spacing: 18) {
        point(.paper, .sand, "Write them on paper", "Keep it safe at home, not in photos, notes or email.")
        point(.phone, .sky, "For a new iPhone", newIPhone)
        point(.lock, .rose, "Only you have them", Self.onlyYouHaveThem(wordsOnlyInSetup: model.wordsOnlyInSetup))
          .infoTip(Self.keyDetail, about: "how your data is locked")
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
    } actions: {
      Button("Show my 12 words") { model.go(.phraseShow) }
        .buttonStyle(.pill(.primary, fill: true))
        .accessibilityIdentifier("phrase.start")
      ActionNote(text: "Takes about two minutes. It can't be skipped.")
    }
  }

  private var newIPhone: String {
    model.capabilities.contains(.recoverAccess)
      ? "No passkey there? These words unlock your data. A password can't."
      : "After you sign in there, they unlock your data. A password can't."
  }

  private func point(_ icon: HIcon, _ hue: Hue, _ title: String, _ text: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      IconTile(icon: icon, hue: hue)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).hType(.rowTitle).foregroundStyle(HColor.textPrimary)
        Text(text).hType(.subheadline).foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .combine)
  }
}

struct PhraseShowView: View {
  @Binding var revealed: Bool
  var words: [String]
  var mode: Mode = .create
  var onBack: (() -> Void)?
  var onContinue: () -> Void
  var seen = true
  var busy = false
  var failure: AuthFailure?
  var onCapture: (Bool) -> Void = { _ in }
  var canShowAgain = true

  enum Mode { case create, view }

  static func createNote(canShowAgain: Bool) -> String {
    canShowAgain ? "They hide again when you leave this screen." : "After this, you can't see them again. Check every word."
  }

  @Environment(\.scenePhase) private var scenePhase
  @State private var captured = screenIsCaptured()
  @State private var screenshotWarning = false

  private var shown: Bool { revealed && !captured }

  var body: some View {
    AccountScreen(
      title: "Write these down, in order",
      subtitle: shown
        ? "On paper, numbered. Check each word twice."
        : "Make sure no one's watching, then tap to show them.",
      steps: mode == .create ? (3, 3) : nil,
      back: mode == .view ? onBack.map { AccountBack.action($0) } ?? AccountBack.none : AccountBack.none
    ) {
      VStack(alignment: .leading, spacing: shown ? 10 : 12) {
        PhraseGrid(words: words, revealed: $revealed, masked: captured)
        FailureBanner(failure: failure)
        if screenshotWarning {
          FailureBanner(failure: .badPhrase("That screenshot shows your recovery phrase. Delete it from Photos and Recently Deleted."))
        }
        WarningCallout(icon: .cameraSlash,
                       text: "No screenshots or copying. Photos sync, and apps can read your clipboard.")
      }
      .padding(.top, shown ? -12 : 0)
      .hAnimation(.stateSwap, value: shown)
    } actions: {
      if mode == .create {
        BusyButton(title: "I've written them down", busy: busy, enabled: seen, identifier: "phrase.written") {
          onContinue()
        }
        ActionNote(text: Self.createNote(canShowAgain: canShowAgain))
      } else {
        Button("Done", action: onContinue)
          .buttonStyle(.pill(.primary, fill: true))
          .accessibilityIdentifier("phrase.done")
      }
    }
    .onChange(of: scenePhase) { _, phase in
      if phase != .active { revealed = false }
    }
    .onAppear { noteCapture() }
    .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
      noteCapture()
    }
    .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
      screenshotWarning = revealed
    }
    .onDisappear { revealed = false }
  }

  private func noteCapture() {
    captured = screenIsCaptured()
    if captured { revealed = false }
    onCapture(captured)
  }
}

struct AccountReadyView: View {
  var profile: AccountProfile?
  var signupEmail = ""
  var outlook: Bool
  var capabilities: AccountCapabilities
  var passkeyHoldsKeys = true
  var onContinue: () -> Void

  @State private var whoSeesOpen = false

  private var passkey: Bool { profile?.method != .password }

  private var subtitle: String {
    Self.subtitle(capabilities: capabilities, passkey: passkey, passkeyHoldsKeys: passkeyHoldsKeys)
  }

  static func subtitle(capabilities: AccountCapabilities, passkey: Bool, passkeyHoldsKeys: Bool) -> String {
    let keep = "Keep the paper safe, away from this iPhone."
    guard capabilities.contains(.viewPhrase) else { return "\(keep) It's your only copy." }
    if passkey && passkeyHoldsKeys { return "\(keep) See the words again in Profile, with Face ID." }
    return "\(keep) Your words can't be shown again."
  }

  var body: some View {
    CelebrationScreen(
      badge: .check,
      title: "Your account is ready.",
      subtitle: subtitle
    ) {
      summary
    } footer: {
      handOff.padding(.bottom, 12)
      actions
    }
    .sheet(isPresented: $whoSeesOpen) { WhoCanSeeSheet(outlook: outlook) }
  }

  @ViewBuilder private var actions: some View {
    Button("Continue", action: onContinue)
      .buttonStyle(.pill(.primary, fill: true))
      .accessibilityIdentifier("ready.continue")
    Button("What Hasala reads, and what it doesn't") { whoSeesOpen = true }
      .buttonStyle(.pill(.tertiary, fill: true))
      .accessibilityIdentifier("ready.whoSees")
  }

  private var summary: some View {
    VStack(spacing: 0) {
      row(profile?.email.isEmpty == false ? profile?.email ?? "" : signupEmail, "Verified")
      divider
      row(passkey ? "Face ID passkey" : "Password", passkey ? "In iCloud Keychain" : "Set")
      divider
      row("Recovery phrase", "On paper")
    }
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
  }

  private var divider: some View {
    Rectangle().fill(HColor.borderSubtle).frame(height: 1).padding(.leading, 35)
  }

  private var handOff: some View {
    InfoCard(icon: .envelope, hue: .sky, title: "Next: connect your email",
             detail: "Read-only, on this iPhone. Only your banks' alerts.")
  }

  private func row(_ title: String, _ value: String) -> some View {
    ReflowingRow(spacing: 12) {
      HStack(spacing: 12) {
        Circle().fill(HColor.statusSuccessForeground).frame(width: 7, height: 7).accessibilityHidden(true)
        Text(title).hType(.rowTitle).foregroundStyle(HColor.textPrimary)
          .lineLimitAtDefaultTextSize(1).truncationMode(.middle)
      }
    } trailing: {
      Text(value).hType(.subheadline).foregroundStyle(HColor.textSecondary)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .frame(minHeight: 52)
    .accessibilityElement(children: .combine)
  }
}
