import HasalaDesign
import HasalaWidgetData
import SwiftUI

struct AccountRootView<Main: View>: View {
  let session: AccountSession
  let onboarding: OnboardingStore
  var setupFacts: OnboardingStep.Facts = .init(hasSession: true, keysReady: true)
  @ViewBuilder var main: () -> Main
  @State private var biometry = HBiometry.device()

  init(
    session: AccountSession, onboarding: OnboardingStore,
    setupFacts: OnboardingStep.Facts = .init(hasSession: true, keysReady: true), @ViewBuilder main: @escaping () -> Main
  ) {
    self.session = session
    self.onboarding = onboarding
    self.setupFacts = setupFacts
    self.main = main
  }

  var body: some View {
    ZStack {
      content
        .id(gate)
        .transition(.opacity)
    }
    .animation(handOff, value: gate)
    .environment(session)
    .environment(onboarding)
    .environment(\.hBiometry, biometry)
    .onAppear { onboarding.phaseChanged(from: nil, to: session.phase) }
    .onChange(of: session.phase) { old, new in onboarding.phaseChanged(from: old, to: new) }
    .onOpenURL { url in
      if let link = WidgetLink(url: url) {
        WidgetLinkInbox.shared.pending = link
      } else {
        session.open(url)
      }
    }
    .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
      if let url = activity.webpageURL { session.open(url) }
    }
    .overlay(alignment: .bottom) {
      ZStack {
        if let notice = session.notice {
          GlassToast(.ink(.info), title: notice, actionTitle: "OK") { session.notice = nil }
            .padding(.horizontal, HSpacing.insetPage)
            .padding(.bottom, 90)
            .hTransition(.toastIn)
            .task {
              try? await Task.sleep(for: .seconds(HMotion.toastDwell))
              session.notice = nil
            }
        }
      }
      .hAnimation(session.notice == nil ? .toastOut : .toastIn, value: session.notice)
    }
  }

  @Environment(\.scenePhase) private var scenePhase
  @State private var passcodeChecked = 0
  @State private var pendingReset: PendingReset?
  @State private var lockingDown = false
  @State private var lockdownAfterApproval = false

  @StageMotion private var motion: MotionPolicy

  private enum Gate: Hashable { case passcode, signedOut, checking, onboarding, needsUnlock, needsKeys, frozen, ready }

  private var gate: Gate {
    if session.phase != .ready, !session.services.hasPasscode() { return .passcode }
    switch session.phase {
    case .signedOut: return .signedOut
    case .checking: return .checking
    case .onboarding: return .onboarding
    case .needsUnlock: return .needsUnlock
    case .needsKeys: return .needsKeys
    case .frozen: return .frozen
    case .ready: return .ready
    }
  }

  private var handOff: Animation? {
    if motion.settled { return nil }
    return HMotion.easeOutSoft(motion.reduceMotion ? HMotion.reduceMotionFade : 0.3)
  }

  @ViewBuilder private var content: some View {
    let _ = passcodeChecked
    if gate == .passcode {
      PasscodeWall()
        .onChange(of: scenePhase) { _, p in if p == .active { passcodeChecked += 1 } }
    } else {
      phaseContent
    }
  }

  @ViewBuilder private var frozenBanner: some View {
    if let info = session.leftFrozen {
      FrozenBanner(by: info.by, onShowWall: { session.showFrozenWall() }, onSignOut: {
        Task { await session.signOut() }
      })
    }
  }

  @ViewBuilder private var phaseContent: some View {
    switch session.phase {
    case .signedOut:
      WelcomeFlowView(store: onboarding)
    case .checking:
      BootCheckView(session: session)
    case .onboarding:
      VStack(spacing: 0) {
        frozenBanner
        SetupFlowView(model: onboarding.setupModel(
          displayName: session.account.profile?.displayName ?? "", facts: setupFacts))
      }
    case .needsUnlock(let passkeyCanUnlock):
      UnlockView(model: onboarding.unlockModel(passkeyCanUnlock: passkeyCanUnlock), onSignOut: {
        Task { await session.signOut() }
      })
    case .needsKeys:
      InterruptedSetupFlowView(store: onboarding)
    case .frozen(let info):
      FrozenWall(session: session, info: info)
    case .ready:
      VStack(spacing: 0) {
        frozenBanner
        main()
      }
        .task(id: scenePhase) {
          guard scenePhase == .active, pendingReset == nil, session.capabilities.contains(.resetPassword) else { return }
          pendingReset = await session.account.pendingResetRequest()
        }
        .sheet(item: $pendingReset, onDismiss: {
          if lockdownAfterApproval {
            lockdownAfterApproval = false
            lockingDown = true
          }
        }) { request in
          ResetApprovalSheet(model: ResetApprovalModel(account: session.account, request: request)) {
            lockdownAfterApproval = true
          }
        }
        .sheet(isPresented: $lockingDown) {
          NavigationStack { LockdownSheetContent(session: session) }
        }
    }
  }
}

struct PasscodeWall: View {
  var body: some View {
    NavigationStack {
      AccountScreen(
        title: "Set a passcode first",
        subtitle: "Set an iPhone passcode to use Hasala. It protects your data and confirms it's you."
      ) {
        NoteCard(systemImage: "gear", title: "Settings › Face ID & Passcode",
                 text: "Turn on a passcode, then come back.")
      } footer: {
        EmptyView()
      }
    }
    .accessibilityIdentifier("passcode.wall")
  }
}

private struct LockdownSheetContent: View {
  @State private var model: SecurityModel
  @Environment(\.dismiss) private var dismiss

  init(session: AccountSession) {
    _model = State(initialValue: SecurityModel(session: session))
  }

  var body: some View {
    LockdownView(model: model)
      .task { await model.load() }
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button(role: .close) { dismiss() }
            .tint(HColor.iconGlass)
            .accessibilityIdentifier("lockdown.close")
        }
      }
  }
}
