import HasalaDesign
import HasalaModels
import SwiftUI
import UIKit

struct InviteCodeView: View {
  @Bindable var model: SignupModel
  var onSignIn: () -> Void
  @State private var focused = false

  static let notAnInviteLink = "Not a Hasala invite link. Enter the code from your invite email."

  private var notFound: Bool { model.failure == .notInvited }

  static let alreadyUsedDetail = "Each invite works once. Made an account? You don't need another."
  static let linkNotFound = "This invite link didn't work. It may have been used or expired."

  static func notFoundMessage(fromLink: Bool) -> String? {
    fromLink ? linkNotFound : AuthFailure.notInvited.message
  }

  static func canContinue(_ model: SignupModel) -> Bool {
    model.inviteCode != nil && model.failure != .notInvited
  }

  var body: some View {
    AccountScreen(
      title: "Enter your invite code",
      subtitle: "It's in your invite email from Hasala.",
      back: .system
    ) {
      VStack(alignment: .leading, spacing: 12) {
        field
        if !notFound {
          InfoCard(icon: .envelope, hue: .sky, title: "Look for \u{201C}Your Hasala invite\u{201D}",
                   detail: "From no-reply@hasala.app, to your waitlist email.", radius: HRadius.tile)
            .hTransition(.fade)
        } else {
          ReasonsCard(
            reasons: [
              ("Already used it?", Self.alreadyUsedDetail),
              ("Past the date in your email?",
               "Expired invites go back to the waitlist. Ask again at hasala.app for a new one."),
            ],
            link: ReasonsCard.ReasonLink(row: 0, title: "Sign in instead", identifier: "invite.signIn", action: onSignIn))
          .hTransition(.rise)
        }
      }
      .hAnimation(.rise, value: notFound)
    } actions: {
      Button("Continue") { model.submitInvite() }
        .buttonStyle(.pill(.primary, fill: true))
        .disabled(!Self.canContinue(model))
        .accessibilityIdentifier("invite.continue")
      WebLink(title: "No invite yet? Join the waitlist", url: "https://hasala.app", identifier: "invite.waitlist")
    }
  }

  private var field: some View {
    VStack(alignment: .leading, spacing: HSpacing.fieldLabelGap) {
      Text("Invite code")
        .hType(.footnote.weight(.semibold))
        .foregroundStyle(HColor.textSecondary)
        .accessibilityHidden(true)
      InviteCodeField(text: $model.inviteText, focused: $focused, identifier: "invite.field") { link in
        model.applyInviteLink(link, pasteboardChange: UIPasteboard.general.changeCount)
      }
      .padding(.horizontal, HSpacing.fieldInsetInline)
      .padding(.vertical, 8)
      .frame(minHeight: HSpacing.codeCellHeight)
      .background(HColor.fieldSurfaceOnGrouped, in: RoundedRectangle(cornerRadius: HRadius.field, style: .continuous))
      .overlay { FieldRing(color: notFound ? HColor.fieldError : focused ? HColor.fieldFocus : .clear) }
      .hAnimation(.fade, value: focused)
      HStack(alignment: .top, spacing: 8) {
        status
        Spacer(minLength: 0)
        PasteButton(payloadType: String.self) { pasted in
          guard let text = pasted.first, !text.isEmpty else { return }
          Task { @MainActor in
            model.paste(text, pasteboardChange: UIPasteboard.general.changeCount)
          }
        }
        .labelStyle(.titleOnly)
        .buttonBorderShape(.capsule)
        .tint(HColor.surfacePrimary)
        .padding(.top, -6)
        .accessibilityIdentifier("invite.paste")
      }
      .padding(.top, 6)
    }
  }

  @ViewBuilder private var status: some View {
    if notFound, let message = Self.notFoundMessage(fromLink: model.inviteFromLink) {
      JoinStatusLine(text: message, tone: .error)
    } else if model.pastedLinkRefused {
      JoinStatusLine(text: Self.notAnInviteLink, tone: .error)
    } else if let hint = model.inviteHint {
      JoinStatusLine(text: hint, tone: .error)
    } else if model.inviteFromLink, model.inviteCode != nil {
      JoinStatusLine(text: "From your invite link.", tone: .success)
    } else if model.invitePasted, model.inviteCode != nil {
      JoinStatusLine(text: "Pasted from your invite email.", tone: .success)
    }
  }
}

struct AboutYouView: View {
  @Bindable var model: SignupModel
  var onSignIn: () -> Void

  @Environment(\.dynamicTypeSize) private var typeSize
  @State private var chipInline = true

  private var nameError: String? {
    model.nameError ?? (AccountFields.nameTooLong(model.displayName) ? AuthFailure.badName.message : nil)
  }

  private var emailError: String? {
    model.emailError
      ?? (AccountFields.emailTooLong(model.email)
        ? "Too long. Use a shorter address." : nil)
  }

  private var chipBeside: Bool { model.emailConfirmed && !typeSize.isAccessibilitySize && chipInline }
  private var chipUnder: Bool { model.emailConfirmed && !chipBeside }

  var body: some View {
    AccountScreen(
      title: "Create your account",
      subtitle: "A name and an email. No usernames.",
      steps: (1, 3),
      back: .system
    ) {
      VStack(alignment: .leading, spacing: 12) {
        VStack(alignment: .leading, spacing: 12) {
          AccountField("Your name", help: "Used in the app and emails.", error: nameError) {
            WrappingTextField(placeholder: "", text: $model.displayName)
              .textContentType(.name)
              .textInputAutocapitalization(.words)
              .autocorrectionDisabled()
              .accessibilityIdentifier("about.name")
          }
          AccountField("Email", help: model.emailHelp, error: emailError) {
            WrappingTextField(placeholder: "you@example.com", text: $model.email)
              .textContentType(.username)
              .keyboardType(.emailAddress)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .accessibilityIdentifier("about.email")
          } trailing: {
            if chipBeside { ConfirmedChip() }
          }
          .background { chipProbe }
          .onPreferenceChange(ChipFitsKey.self) { chipInline = $0 }
          if chipUnder { ConfirmedChip() }
        }
        .id(Self.fieldsID)
        FailureBanner(failure: model.failure)
        GlyphNote(icon: .shieldCheck,
                  text: "We email only codes, invites and security alerts. Never your money or marketing.")
      }
    } actions: {
      BusyButton(title: "Continue", busy: model.busy, enabled: model.aboutYouReady, identifier: "about.continue") {
        Task { await model.submitAboutYou() }
      }
      LinkButton(title: "Already have an account? Sign in", identifier: "about.signIn", action: onSignIn)
    }
    .revealsOnKeyboard(Self.fieldsID)
  }

  private static let fieldsID = "about.fields"

  private var chipProbe: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 8) {
        Text(model.email.isEmpty ? " " : model.email)
          .hType(FieldFrame<EmptyView, EmptyView>.valueType)
          .lineLimit(1)
          .fixedSize()
        ConfirmedChip()
      }
      .padding(.leading, HSpacing.fieldInsetInline)
      .padding(.trailing, 8)
      .preference(key: ChipFitsKey.self, value: true)
      Color.clear.preference(key: ChipFitsKey.self, value: false)
    }
    .hidden()
    .accessibilityHidden(true)
  }
}

private struct ChipFitsKey: PreferenceKey {
  static let defaultValue = true
  static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value && nextValue() }
}

struct SignInMethodView: View {
  @Bindable var model: SignupModel

  static func subtitle(emailProvenByLink: Bool) -> String {
    emailProvenByLink
      ? "Your invite link confirmed your email."
      : "Your email is verified."
  }

  static let passwordDetail =
    "Signs you in anywhere. Can't unlock your data on a new iPhone, and your 12 words can't be shown again."

  var body: some View {
    AccountScreen(
      title: "How do you want to sign in?",
      subtitle: Self.subtitle(emailProvenByLink: model.ticket?.emailProven == true),
      steps: (2, 3),
      back: .system
    ) {
      VStack(spacing: 12) {
        choice(.passkey, icon: .faceID, hue: .sky, title: "Use Face ID (passkey)", recommended: true,
               text: "Nothing to remember. Syncs in iCloud Keychain and unlocks your data on a new iPhone.")
        choice(.password, icon: .password, hue: .other, title: "Use a password", recommended: false,
               text: Self.passwordDetail)
        FailureBanner(failure: model.failure)
      }
    } actions: {
      BusyButton(title: model.method == .passkey ? "Continue with Face ID" : "Continue with a password",
                 busy: model.busy, identifier: "method.continue") {
        Task { await model.continueWithMethod() }
      }
      WebLink(title: "What's a passkey?", url: "https://support.apple.com/102195", identifier: "method.whatsAPasskey")
    }
  }

  private func choice(_ m: SignInMethod, icon: HIcon, hue: Hue, title: String, recommended: Bool, text: String)
    -> some View
  {
    SelectionCard(icon: icon, hue: hue, chip: recommended ? "Recommended" : nil, title: title, detail: text,
                  selected: model.method == m, identifier: "method.\(m.rawValue)") {
      model.method = m
      model.failure = nil
    }
    .disabled(m == .password && model.passkeyRegistered)
  }
}

struct CreatePasswordView: View {
  @Bindable var model: SignupModel

  var body: some View {
    AccountScreen(
      title: "Create a password",
      subtitle: "12 characters or more. A short phrase works well.",
      steps: (2, 3),
      back: .system
    ) {
      VStack(alignment: .leading, spacing: 12) {
        VStack(alignment: .leading, spacing: 12) {
          LabeledField(label: "Password") {
            RuledNewPasswordField(placeholder: "12 characters or more", text: $model.newPassword, secure: !model.passwordShown,
                                  identifier: "password.new")
          } accessory: {
            ShowHidePill(visible: $model.passwordShown)
          }
          if !model.newPassword.isEmpty {
            PasswordStrengthCard(assessment: model.passwordAssessment)
              .hTransition(.rise)
          }
          VStack(alignment: .leading, spacing: 8) {
            LabeledField(label: "Type it again", error: mismatch ? "Passwords don't match." : nil) {
              RuledNewPasswordField(placeholder: "Confirm password", text: $model.confirmPassword, secure: true,
                                    identifier: "password.confirm")
            }
            if model.passwordsMatch {
              StatusLine(text: "Passwords match.", tone: .success)
                .padding(.top, 2)
            }
          }
          .padding(.top, 4)
        }
        .id(Self.fieldsID)
        NoteRow(icon: .lock,
                text: "A password can't unlock your data on a new iPhone. Your 12 words can.")
      }
      .hAnimation(.rise, value: model.newPassword.isEmpty)
    } actions: {
      BusyButton(title: "Create account", busy: model.busy, enabled: model.passwordReady,
                 identifier: "password.create") {
        model.submitPassword()
      }
      LinkButton(title: "Use Face ID instead", identifier: "password.useFaceID") {
        model.method = .passkey
        model.back()
      }
    }
    .revealsOnKeyboard(Self.fieldsID)
  }

  private static let fieldsID = "password.fields"

  private var mismatch: Bool {
    !model.confirmPassword.isEmpty && !model.passwordsMatch && model.confirmPassword.count >= model.newPassword.count
  }
}
