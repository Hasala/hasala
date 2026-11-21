import HasalaDesign
import HasalaModels
import SwiftUI

struct SecurityView: View {
  @Environment(\.hBiometry) private var biometry
  let session: AccountSession
  let app: AppModel
  @Environment(AppLockController.self) private var lock: AppLockController?
  @State private var model: SecurityModel
  @State private var alert: PendingAlert?
  @State private var deleting = false
  @State private var lockingDown = false

  init(session: AccountSession, app: AppModel) {
    self.session = session
    self.app = app
    _model = State(initialValue: SecurityModel(session: session))
  }

  enum PendingAlert: Identifiable {
    case removePasskey(PasskeyRow)
    case removeDevice(DeviceRow)
    case removeThisIPhone
    case removePassword
    case signOut
    case signOutEverywhere
    case freeze

    var id: String {
      switch self {
      case .removePasskey(let p): "pk.\(p.id)"
      case .removeDevice(let d): "dev.\(d.id)"
      case .removeThisIPhone: "thisIPhone"
      case .removePassword: "pw"
      case .signOut: "out"
      case .signOutEverywhere: "outAll"
      case .freeze: "freeze"
      }
    }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        if let s = model.state {
          hero(s)
          if let frozen = s.frozen { frozenAction(frozen) }
          if let notice = model.notice {
            StatusLine(text: notice, tone: .success, size: .regular)
              .accessibilityIdentifier("security.notice")
          }
          if model.confirming == nil { FailureBanner(failure: model.failure) }
          section("Email") { emailCard(s) }
          if s.hasPasskey || (can(.addPasskey) && s.frozen == nil) {
            section("Passkeys", footer: s.hasPasskey
              ? "Signs you in and unlocks your data."
              : "Add one and \(biometry.name ?? "your passkey") signs you in.") { passkeys(s) }
          }
          section("Password", footer: passwordFooter(s), tip: s.hasPasskey ? Self.passwordTip : nil,
                  tipAbout: "unlocking your data") { passwordCard(s) }
          if let lock { AppLockSecuritySection(app: app, lock: lock) }
          section("Devices") { devices(s) }
          section("Recovery phrase", footer: phraseFooter(s)) { phrase(s) }
          footerActions(s)
        } else if model.failure != nil {
          FailureBanner(failure: model.failure)
        } else {
          ProgressView().frame(maxWidth: .infinity, minHeight: 200)
        }
      }
      .padding(.horizontal, HSpacing.insetPage)
      .padding(.top, 8)
      .padding(.bottom, 48)
      .fullScreenCover(isPresented: Binding(get: { model.viewedPhrase != nil }, set: { if !$0 { model.closePhrase() } })) {
        PhraseViewer(model: model)
      }
    }
    .background(HColor.surfaceSecondary)
    .navigationTitle("Sign-in & security")
    .navigationBarTitleDisplayMode(.inline)
    .task {
      await model.keepLoading()
      #if HASALA_MOCKS
        await ScreenLaunch.applySecurityLaunch(model, alert: $alert, lockingDown: $lockingDown)
      #endif
    }
    .confirmSheet(model, onEnterWords: BuildSurface.showsUnfinished ? { model.enterWordsToUnlock() } : nil)
    .navigationDestination(isPresented: $model.editingPassword) {
      PasswordEditPage(model: model)
    }
    .navigationDestination(isPresented: $deleting) {
      DeleteAccountView(session: session)
    }
    .navigationDestination(isPresented: $lockingDown) {
      LockdownView(model: model, context: .fromSecurity)
    }
    .fullScreenCover(item: $model.emailChange) { ticket in
      ChangeEmailFlow(account: model.accountForEmailChange, ticket: ticket) { newEmail in
        Task { await model.finishEmailChange(to: newEmail) }
      }
    }
    .alert(alertTitle, isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } }),
           presenting: alert) { a in
      alertButtons(a)
    } message: { a in
      Text(alertMessage(a))
    }
  }

  private func can(_ action: AccountCapabilities) -> Bool { model.capabilities.contains(action) }

  private func hero(_ s: SecurityState) -> some View {
    Group {
      if let frozen = s.frozen {
        StatusHero(title: "Frozen", body: Self.frozenBody(frozen, canUnfreeze: can(.unfreeze)), hue: .rose, icon: .lockKeyhole)
      } else if s.hasPasskey, unseen {
        StatusHero(title: "Almost protected", body: "Write down your 12 words to finish.",
                   hue: .sand, icon: .paper)
      } else if s.hasPasskey {
        StatusHero(title: "Protected", body: "Passkey and 12 words are set.\nLast sign-in \(s.lastSignIn).",
                   hue: .mint, icon: .check)
      } else {
        StatusHero(
          title: "Password only",
          body: can(.addPasskey)
            ? "Your 12 words are set. A passkey\nwould make sign-in one glance."
            : "Password and 12 words are set.\nLast sign-in \(s.lastSignIn).",
          hue: .sand, icon: .faceID)
      }
    }
    .accessibilityIdentifier("security.hero")
  }

  private var unseen: Bool { session.services.unseenPhrase.unseen }

  static func frozenBody(_ frozen: FreezeInfo, canUnfreeze: Bool) -> String {
    if frozen.by == .operator || (canUnfreeze && !frozen.holderCanLift) {
      return frozen.by == .operator
        ? "We froze your account to protect it. Talk to us to unfreeze it."
        : "Only we can lift this freeze. Talk to us to unfreeze it."
    }
    return canUnfreeze ? "Confirm it's you to unfreeze it." : "Your account is frozen."
  }

  static func phraseDetail(_ s: SecurityState, unseen: Bool) -> String {
    if s.frozen != nil { return "Unfreeze to view" }
    return unseen && s.hasPasskey ? "Not written down yet" : s.phraseConfirmed
  }

  static let emailDetail = "Verified · sign-in codes and security emails"

  @ViewBuilder private func frozenAction(_ frozen: FreezeInfo) -> some View {
    if frozen.by == .holder, frozen.holderCanLift, can(.unfreeze) {
      Button("Unfreeze") { Task { await model.request(.unfreeze) } }
        .buttonStyle(.pill(.primary, fill: true))
        .accessibilityIdentifier("security.unfreeze")
    } else {
      Link(destination: URL(string: "https://hasala.app/support")!) {
        Text("Talk to a person")
      }
      .buttonStyle(.pill(.primary, fill: true))
      .accessibilityIdentifier("security.frozenTalk")
    }
  }

  private func section<C: View>(
    _ title: String, footer: String? = nil, tip: String? = nil, tipAbout: String = "",
    @ViewBuilder _ content: () -> C
  ) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title).hType(.section).foregroundStyle(HColor.textPrimary).accessibilityAddTraits(.isHeader)
      HListCard { content() }
      if let footer {
        Text(footer)
          .hType(.footnote)
          .foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .infoTip(tip, about: tipAbout)
          .padding(.horizontal, 4)
      }
    }
  }

  private func emailCard(_ s: SecurityState) -> some View {
    SecurityRow(tile: .plate(.envelope, .sky), title: s.email,
                detail: s.emailVerified ? Self.emailDetail : "Not verified yet",
                titleLabel: "Email address \(s.email)", titleLines: 2) {
      if can(.changeEmail), BuildSurface.showsUnfinished {
        Button("Change") { model.requestEmailChange() }
          .buttonStyle(.pill(.secondary, size: .small))
          .accessibilityIdentifier("security.changeEmail")
      }
    }
  }

  private func passkeys(_ s: SecurityState) -> some View {
    Group {
      ForEach(Array(s.passkeys.enumerated()), id: \.element.id) { i, p in
        if i > 0 { HDivider() }
        SecurityRow(tile: p.isThisCredential ? .plate(.faceID, .sky) : .plate(.passkey, .other), title: p.provider,
                    detail: p.detail, titleLines: 2, titleTruncation: .tail) {
          if can(.removePasskey), s.canRemove(p) {
            InlineDestructive(title: "Remove", identifier: "security.removePasskey.\(p.id)") {
              alert = .removePasskey(p)
            }
          }
        }
      }
      if can(.addPasskey), s.frozen == nil {
        if !s.passkeys.isEmpty { HDivider() }
        AddRow(title: "Add a passkey", identifier: "security.addPasskey") {
          Task { await model.request(.addPasskey) }
        }
      }
    }
  }

  private func passwordFooter(_ s: SecurityState) -> String {
    s.hasPasskey
      ? "A password never unlocks your data."
      : can(.addPasskey)
        ? "Your only sign-in until you add a passkey. It never unlocks your data."
        : "Your only sign-in. It never unlocks your data."
  }

  static let passwordTip = "On a new iPhone, you'd still need a passkey or your 12 words."

  private func phraseFooter(_ s: SecurityState) -> String {
    guard s.hasPasskey else {
      return "It can't be shown again. Keep your written copy."
    }
    return can(.rotatePhrase) && BuildSurface.showsUnfinished
      ? "We can't see or reset your words. Viewing them emails you; new words replace them everywhere."
      : "We can't see or reset your words. Viewing them emails you."
  }

  private func passwordCard(_ s: SecurityState) -> some View {
    Group {
      if let changed = s.passwordChanged {
        SecurityRow(tile: .plate(.password, .other), title: "Password", detail: changed) {
          if can(.changePassword) {
            Button("Change") { model.editingPassword = true }
              .buttonStyle(.pill(.secondary, size: .small))
              .accessibilityIdentifier("security.changePassword")
          }
        }
        if s.canRemovePassword, can(.changePassword) {
          HDivider()
          AddRow(title: "Remove password", identifier: "security.removePassword", plus: false, destructive: true) {
            alert = .removePassword
          }
        }
      } else {
        SecurityRow(tile: .plate(.password, .other), title: "No password",
                    detail: can(.changePassword) ? "Optional. Signs you in where \(biometry.name ?? "a passkey") can't." : "You sign in with your passkey.") {
          if can(.changePassword) {
            Button("Set one") { model.editingPassword = true }
              .buttonStyle(.pill(.secondary, size: .small))
              .accessibilityIdentifier("security.setPassword")
          }
        }
      }
    }
  }

  @ViewBuilder private func devices(_ s: SecurityState) -> some View {
    if s.devices.isEmpty {
      SecurityRow(tile: .plate(.phone, .mint), title: "Only this iPhone", detail: nil) { EmptyView() }
        .accessibilityIdentifier("security.devices.empty")
    }
    ForEach(Array(s.devices.enumerated()), id: \.element.id) { i, d in
      if i > 0 { HDivider() }
      SecurityRow(tile: d.isThisDevice ? .plate(.phone, .mint) : .plate(d.isTablet ? .iPad : .phone, .other),
                  title: d.title, detail: d.detail, titleLines: 2, titleTruncation: .tail) {
        if d.isThisDevice {
          HStack(spacing: 6) {
            Circle().fill(HColor.statusSuccessForeground).frame(width: 7, height: 7)
            Text("You").hType(.footnote.weight(.semibold)).foregroundStyle(HColor.statusSuccessForeground)
          }
          .accessibilityElement(children: .combine)
        } else if can(.removeDevice) {
          InlineDestructive(title: "Remove", identifier: "security.removeDevice.\(d.id)") { alert = .removeDevice(d) }
        }
      }
    }
  }

  private func phrase(_ s: SecurityState) -> some View {
    Group {
      if s.hasPasskey, can(.viewPhrase), s.frozen == nil {
        Button {
          model.requestPhrase()
        } label: {
          SecurityRow(tile: .disc(.paper, .sand), title: "View recovery phrase",
                      detail: "\(Self.phraseDetail(s, unseen: unseen)) · Asks for \(biometry.noun)") {
            HIconView(.chevronRight, size: 16, color: HColor.listRowChevron)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(HRowPressStyle())
        .accessibilityIdentifier("security.viewPhrase")
      } else {
        SecurityRow(tile: .disc(.paper, .sand), title: "Recovery phrase", detail: Self.phraseDetail(s, unseen: unseen)) {
          EmptyView()
        }
      }
      if can(.rotatePhrase), BuildSurface.showsUnfinished {
        HDivider()
        AddRow(title: "New recovery phrase", identifier: "security.newWords", plus: false) {
          model.failure = .notInThisBuild
        }
      }
    }
  }

  private func footerActions(_ s: SecurityState) -> some View {
    VStack(spacing: 4) {
      if can(.signOut) {
        Button("Sign out of this iPhone") { alert = .signOut }
          .buttonStyle(.pill(.destructiveQuiet, fill: true))
          .accessibilityIdentifier("security.signOut")
      }
      if can(.signOutEverywhere), s.frozen == nil {
        TextLink(title: "Sign out everywhere", identifier: "security.signOutEverywhere") { alert = .signOutEverywhere }
      }
      if s.frozen == nil, can(.freeze) {
        TextLink(title: "Freeze my account", identifier: "security.freeze") { alert = .freeze }
      }
      if model.offersLockdown {
        TextLink(title: "Something not right? Lock it down", identifier: "security.lockdown") { lockingDown = true }
      }
      if can(.deleteAccount) {
        if s.frozen == nil {
          TextLink(title: "Delete your account", identifier: "security.delete", destructive: true) { deleting = true }
        } else {
          Text(AccountCopy.unfreezeToDelete)
            .hType(.subheadline.weight(.semibold))
            .foregroundStyle(HColor.textSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 44)
            .accessibilityIdentifier("security.deleteFrozen")
        }
      }
      if model.lacksAnAction {
        SupportLink(lead: "Don't recognise something here? Contact us.", identifier: "security.support")
      }
      Text(s.hasPasskey ? "Changes here ask for \(biometry.noun) first." : "Changes here need your password and this iPhone's key.")
        .hType(.footnote)
        .foregroundStyle(HColor.textSecondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }
    .padding(.top, 8)
  }

  static let removeThisIPhoneTitle = "Remove this iPhone?"

  static let removeThisIPhoneMessage =
    "Changes that can't upload are lost for good. Everything you uploaded stays in your account."

  private var alertTitle: String {
    switch alert {
    case .removePasskey(let p): "Remove the \(p.provider) passkey?"
    case .removeDevice(let d): "Remove \(d.title)?"
    case .removeThisIPhone: Self.removeThisIPhoneTitle
    case .removePassword: "Remove your password?"
    case .signOut: "Sign out of this iPhone?"
    case .signOutEverywhere: "Sign out everywhere?"
    case .freeze: "Freeze your account?"
    case nil: ""
    }
  }

  private func alertMessage(_ a: PendingAlert) -> String {
    let confirmWith = model.state?.hasPasskey == true ? biometry.noun : "your password"
    switch a {
    case .removePasskey:
      return "It can't sign in after this. You'll confirm with \(confirmWith) next."
    case .removeDevice:
      return "It's signed out now. Its copy of your data is erased when it next opens Hasala."
    case .removeThisIPhone:
      return Self.removeThisIPhoneMessage
    case .removePassword:
      return "You'll sign in with your passkey only. You'll confirm with \(biometry.noun) next."
    case .signOut:
      return AccountCopy.signOutMessage
    case .signOutEverywhere:
      return LockdownView.signOutEverywhereMessage
    case .freeze:
      return "Signs everyone out and blocks password sign-in, resets and the recovery phrase. To unfreeze, use a passkey or your password on one of your iPhones."
    }
  }

  @ViewBuilder private func alertButtons(_ a: PendingAlert) -> some View {
    Button("Cancel", role: .cancel) {}
    switch a {
    case .removePasskey(let p):
      Button("Remove", role: .destructive) { Task { await model.request(.removePasskey(id: p.id)) } }
    case .removeDevice(let d):
      Button("Remove", role: .destructive) { Task { await model.request(.removeDevice(id: d.id)) } }
    case .removeThisIPhone:
      Button("Remove", role: .destructive) { Task { await model.request(.removeThisIPhoneLosingUnsent) } }
        .accessibilityIdentifier("security.removeThisIPhone.confirm")
    case .removePassword:
      Button("Remove", role: .destructive) { Task { await model.request(.removePassword) } }
    case .signOut:
      Button("Sign out", role: .destructive) { Task { await model.signOut() } }
    case .signOutEverywhere:
      Button("Sign out all", role: .destructive) { Task { await model.request(.signOutEverywhere) } }
    case .freeze:
      Button("Freeze my account", role: .destructive) { Task { await model.request(.freeze) } }
    }
  }
}

struct SecurityRow<Trailing: View>: View {
  enum Tile {
    case plate(HIcon, Hue)
    case disc(HIcon, Hue)
  }

  var tile: Tile
  var title: String
  var detail: String?
  var titleLabel: String?
  var titleLines = 1
  var titleTruncation: Text.TruncationMode = .middle
  @ViewBuilder var trailing: () -> Trailing

  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    HStack(alignment: typeSize.isAccessibilitySize || detail != nil ? .top : .center, spacing: 12) {
      tileView
      if typeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 4) {
          text
          trailing()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        HStack(spacing: 12) {
          text.frame(maxWidth: .infinity, alignment: .leading)
          trailing().fixedSize()
        }
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .frame(minHeight: 64)
  }

  private var text: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .hType(.rowTitle)
        .foregroundStyle(HColor.textPrimary)
        .lineLimitAtDefaultTextSize(titleLines)
        .truncationMode(titleTruncation)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel(titleLabel ?? title)
      if let detail {
        Text(detail)
          .hType(.footnote)
          .foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder private var tileView: some View {
    switch tile {
    case .plate(let icon, let hue):
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(hue.perceptualGradient)
        .frame(width: 40, height: 40)
        .overlay { HIconView(icon, size: 20, color: hue.ink) }
        .accessibilityHidden(true)
    case .disc(let icon, let hue):
      CategoryDisc(hue: hue, icon: icon)
    }
  }
}

private struct AddRow: View {
  var title: String
  var identifier: String
  var plus = true
  var destructive = false
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 12) {
        if plus {
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(HColor.actionAccentSubtle)
            .frame(width: 40, height: 40)
            .overlay { HIconView(.add, size: 18, color: HColor.textLink, strokeWidth: 2.4) }
            .accessibilityHidden(true)
        } else {
          Color.clear.frame(width: 40, height: 1)
        }
        Text(title)
          .hType(.rowTitle)
          .foregroundStyle(destructive ? HColor.actionDestructive : HColor.textLink)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
      .frame(minHeight: 56)
      .contentShape(Rectangle())
    }
    .buttonStyle(HRowPressStyle())
    .accessibilityIdentifier(identifier)
  }
}

private struct InlineDestructive: View {
  var title: String
  var identifier: String
  var action: () -> Void

  var body: some View {
    Button(role: .destructive, action: action) {
      Text(title)
        .hType(.subheadline.weight(.semibold))
        .foregroundStyle(HColor.actionDestructive)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier(identifier)
  }
}

struct TextLink: View {
  var title: String
  var identifier: String
  var destructive = false
  var action: () -> Void

  var body: some View {
    Button(role: destructive ? .destructive : nil, action: action) {
      Text(title)
        .hType(.subheadline.weight(.semibold))
        .foregroundStyle(destructive ? HColor.actionDestructive : HColor.textPrimary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier(identifier)
  }
}

extension View {
  func confirmSheet(
    _ model: SecurityModel, host: SecurityModel.Host = .page, onEnterWords: (() -> Void)? = nil
  ) -> some View {
    sheet(
      item: Binding(
        get: { model.confirmHost == host ? model.confirming : nil },
        set: { if $0 == nil, model.confirming != nil { model.cancelConfirmation() } }),
      onDismiss: { model.confirmationDismissed() }
    ) { _ in
      ConfirmSheetHost(model: model, onEnterWords: onEnterWords)
    }
  }
}

private struct ConfirmSheetHost: View {
  @Bindable var model: SecurityModel
  var onEnterWords: (() -> Void)?

  var body: some View {
    if let request = model.confirmRequest {
      ConfirmItsYouSheet(
        request: request, password: $model.confirmPassword, busy: model.busy, failure: model.failure,
        onConfirm: { Task { await model.confirm() } }, onEnterWords: onEnterWords,
        onClose: { model.cancelConfirmation() })
    }
  }
}

struct PasswordEditPage: View {
  @Bindable var model: SecurityModel

  var body: some View {
    AccountScreen(
      title: model.state?.hasPassword == true ? "Change your password" : "Set a password",
      subtitle: "12 characters or more. Other devices are signed out when it changes.",
      back: .system
    ) {
      NewPasswordBlock(password: $model.newPassword, confirm: $model.confirmNewPassword,
                       assessment: model.newPasswordAssessment,
                       matches: model.newPasswordsMatch)
    } footer: {
      BusyButton(title: "Save password", busy: model.busy, enabled: model.newPasswordReady,
                 identifier: "passwordEdit.save") {
        Task { await model.savePassword() }
      }
    }
    .confirmSheet(model, host: .passwordEditor,
                  onEnterWords: BuildSurface.showsUnfinished ? { model.enterWordsToUnlock() } : nil)
  }
}
