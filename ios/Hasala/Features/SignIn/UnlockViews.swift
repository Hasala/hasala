import HasalaDesign
import Observation
import SwiftUI

@MainActor
@Observable
final class UnlockModel {
  enum Way: Equatable { case passkey, words }

  enum Stage: Equatable {
    case choosing
    case unlocking(Way)
    case unlocked
  }

  enum Route: Hashable { case words, honestEnd }

  let account: AccountService
  private let onUnlocked: () -> Void
  let passkeyCanUnlock: Bool
  var path: [Route] = []
  private(set) var stage: Stage = .choosing
  var phraseText = ""
  var pastedChangeCount: Int?
  var busy = false
  var failure: AuthFailure?
  private(set) var failedOnWords = false
  private(set) var unlockedWith: Way?
  var addingPasskey = false
  var confirmPassword = ""
  private(set) var passkeyAdded = false

  init(account: AccountService, passkeyCanUnlock: Bool, onUnlocked: @escaping () -> Void) {
    self.account = account
    self.passkeyCanUnlock = passkeyCanUnlock
    self.onUnlocked = onUnlocked
  }

  var unlocked: Bool { stage == .unlocked }
  var capabilities: AccountCapabilities { account.capabilities }
  var profile: AccountProfile? { account.profile }

  func enterWords() {
    failure = nil
    failedOnWords = false
    path = [.words]
  }

  func noWords() {
    failure = nil
    path = [.honestEnd]
  }

  func unlockWithPasskey() async {
    busy = true
    failure = nil
    stage = .unlocking(.passkey)
    defer { busy = false }
    do {
      try await account.unlockWithPasskey()
      unlockedWith = .passkey
      stage = .unlocked
    } catch .cancelled {
      stage = .choosing
    } catch .noCredential, .unsupported {
      stage = .choosing
      failure = .badPhrase("Your passkey provider can't unlock your data. Use your 12 words.")
      failedOnWords = true
      path = [.words]
    } catch {
      stage = .choosing
      failedOnWords = false
      failure = error
    }
  }

  func unlockWithWords() async {
    switch PhraseRules.validate(phraseText) {
    case .failure(let f):
      failure = f
      failedOnWords = true
    case .success(let words):
      busy = true
      failure = nil
      instantly {
        path = []
        stage = .unlocking(.words)
      }
      defer { busy = false }
      do {
        try await account.unlockWithPhrase(words)
        clearPastedPhrase(changeCount: pastedChangeCount)
        pastedChangeCount = nil
        phraseText = ""
        unlockedWith = .words
        stage = .unlocked
      } catch {
        stage = .choosing
        failure = error
        failedOnWords = true
        path = [.words]
      }
    }
  }

  var offersPasskey: Bool {
    capabilities.contains(.addPasskey) && unlockedWith == .words && profile?.method != .passkey && !passkeyAdded
  }

  func addPasskey() async {
    let pw = confirmPassword
    busy = true
    defer { busy = false }
    do {
      try await account.perform(.addPasskey, password: pw)
      confirmPassword = ""
      passkeyAdded = true
      addingPasskey = false
      failure = nil
    } catch .cancelled {
      confirmPassword = ""
    } catch {
      confirmPassword = ""
      failure = error
    }
  }

  func openApp() {
    account.endUnlockOffer()
    onUnlocked()
  }
}

struct UnlockView: View {
  @Environment(\.hBiometry) private var biometry
  @State private var model: UnlockModel
  var onSignOut: () -> Void
  @FocusState private var typing: Bool
  @State private var edit: PhraseEdit?

  @Environment(OnboardingStore.self) private var store: OnboardingStore?

  init(model: UnlockModel, onSignOut: @escaping () -> Void) {
    _model = State(initialValue: model)
    self.onSignOut = onSignOut
  }

  private var afterReset: Bool { store?.signIn.resetApproved ?? false }

  var body: some View {
    NavigationStack(path: $model.path) {
      root
        .navigationDestination(for: UnlockModel.Route.self) { route in
          switch route {
          case .words: words
          case .honestEnd:
            HonestEndScreen(
              context: .unlock, onFoundWords: { model.enterWords() }, onSignOut: onSignOut)
          }
        }
    }
    #if HASALA_MOCKS
      .task { await ScreenLaunch.applyUnlockLaunch(model) }
    #endif
  }

  @ViewBuilder private var root: some View {
    switch model.stage {
    case .choosing: choose
    case .unlocking(let method): unlocking(method)
    case .unlocked: welcomeBack
    }
  }

  private var signedInEmail: String? {
    guard let email = model.profile?.email, !email.isEmpty else { return nil }
    return email
  }

  private var sealedLine: String {
    model.passkeyCanUnlock
      ? "Your budget is still sealed. Open it here with one of these."
      : "Your budget is still sealed. Your 12 words open it here."
  }

  private var choose: some View {
    HeroAccountScreen(
      hero: HeroDisc(icon: .lock, hue: .sand),
      title: afterReset ? "You're in. Your data is still locked." : "Unlock your data",
      subtitle: afterReset
        ? "Your other iPhone let you in. Only your 12 words open your data here."
        : signedInEmail == nil ? "You're signed in. \(sealedLine)" : "You're signed in as",
      email: afterReset ? nil : signedInEmail.map { EmailAside(address: $0, after: sealedLine) }
    ) {
      VStack(alignment: .leading, spacing: 12) {
        if model.passkeyCanUnlock && !afterReset {
          OptionCard(icon: biometry.icon, hue: .sky, title: "Use your passkey",
                     detail: "If it synced through iCloud Keychain, \(biometry.name ?? "your passkey") opens everything.",
                     buttonTitle: biometry.name.map { "Unlock with \($0)" } ?? "Unlock with your passkey", buttonKind: .primary,
                     buttonIcon: biometry.icon,
                     busy: model.busy, identifier: "unlock.passkey") {
            Task { await model.unlockWithPasskey() }
          }
          OptionCard(icon: .paper, hue: .sand, title: "Enter your recovery phrase",
                     detail: "Written on paper when you joined.", buttonTitle: "Enter words",
                     identifier: "unlock.words") { model.enterWords() }
        } else {
          OptionCard(icon: .paper, hue: .sand, title: "Have your paper ready",
                     detail: "Your 12 words from when you joined. Once per iPhone.",
                     buttonTitle: "Enter my 12 words", buttonKind: .primary, identifier: "unlock.words") {
            model.enterWords()
          }
        }
        if !model.failedOnWords { FailureBanner(failure: model.failure) }
        if !afterReset {
          NoteRow(icon: .shield,
                  text: "A password can't do this, so a stolen one can't open your budget.")
        }
      }
    } footer: {
      SecondaryLink(title: model.passkeyCanUnlock && !afterReset ? "I don't have either" : "I don't have my words",
                    identifier: "unlock.noWords") { model.noWords() }
    }
  }

  private var words: some View {
    let state = PhraseEntryState(model.phraseText)
    return AccountScreen(
      title: "Enter your recovery phrase",
      subtitle: "In the order on your paper. \(state.finished) of 12 so far.",
      back: .system
    ) {
      VStack(alignment: .leading, spacing: 12) {
        PhraseEntryGrid(text: $model.phraseText, pastedChangeCount: $model.pastedChangeCount, focused: $typing, edit: $edit) {
          Task { await model.unlockWithWords() }
        }
        if model.failedOnWords { FailureBanner(failure: model.failure) }
      }
      .accountContentTop(16)
    } footer: {
      if edit != nil || (typing && !model.busy && !state.isComplete) {
        PhraseSuggestions(text: $model.phraseText, edit: $edit)
      } else {
        BusyButton(title: "Unlock", busy: model.busy, enabled: state.isComplete, identifier: "unlock.submit") {
          Task { await model.unlockWithWords() }
        }
      }
    }
    .revealsPhraseEntry(model.phraseText)
  }

  private func unlocking(_ method: UnlockModel.Way) -> some View {
    ProgressCelebrationScreen(
      title: "Unlocking your data",
      subtitle: "Keep Hasala open for about a minute."
    ) {
      StatusListCard(rows: method == .words
        ? [
          StatusListRow(title: "Words checked", value: "Done", state: .done),
          StatusListRow(title: "Downloading sealed copy", value: "Now", state: .active),
          StatusListRow(title: "Opening it on this iPhone", value: "Next", state: .pending),
        ]
        : [
          StatusListRow(title: "Your passkey", value: "Now", state: .active),
          StatusListRow(title: "Downloading sealed copy", value: "Next", state: .pending),
          StatusListRow(title: "Opening it on this iPhone", value: "Next", state: .pending),
        ])
    } foot: {
      InfoCard(icon: .shieldCheck, hue: .mint, title: "Sealed all the way here",
               detail: "We hold only the locked copy. Its key never leaves this iPhone.")
    }
    .accessibilityIdentifier("unlock.unlocking")
  }

  private var welcomeBack: some View {
    let name = model.profile?.greetingName ?? ""
    return CelebrationScreen(
      badge: .check,
      title: name.isEmpty ? "Welcome back." : "Welcome back, \(name).",
      subtitle: "Everything is unlocked on this iPhone. We emailed you about this sign-in."
    ) {
      EmptyView()
    } footer: {
      if model.offersPasskey {
        InfoCard(icon: .faceID, hue: .sky, title: "Add a passkey to this iPhone",
                 detail: "Next time \(biometry.name ?? "your passkey") signs you in and unlocks everything. Keep your paper as backup.")
          .padding(.bottom, 12)
        Button("Add a passkey") {
          model.confirmPassword = ""
          model.failure = nil
          model.addingPasskey = true
        }
        .buttonStyle(.pill(.primary, fill: true))
        .accessibilityIdentifier("unlock.addPasskey")
        Button("Go to Home") { model.openApp() }
          .buttonStyle(.pill(.tertiary, fill: true))
          .accessibilityIdentifier("unlock.open")
      } else {
        Button("Go to Home") { model.openApp() }
          .buttonStyle(.pill(.primary, fill: true))
          .accessibilityIdentifier("unlock.open")
      }
    }
    .sheet(isPresented: $model.addingPasskey) {
      ConfirmItsYouSheet(
        request: ConfirmRequest(
          title: "Add a passkey", factor: .password,
          bullets: ["iOS asks where to save it next", "Then \(biometry.name ?? "your passkey") signs you in and unlocks your data"]),
        password: $model.confirmPassword, busy: model.busy, failure: model.failure,
        onConfirm: { Task { await model.addPasskey() } },
        onClose: { model.addingPasskey = false })
    }
  }
}
