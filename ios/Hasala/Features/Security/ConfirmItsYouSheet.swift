import HasalaDesign
import HasalaModels
import SwiftUI

struct ConfirmRequest: Equatable {
  enum Factor: Equatable {
    case faceID
    case password
    case noKey
  }

  var title: String
  var factor: Factor
  var bullets: [String] = []
  var otherDevice: String?
}

struct ConfirmItsYouSheet: View {
  @Environment(\.hBiometry) private var biometry
  var request: ConfirmRequest
  @Binding var password: String
  var busy: Bool
  var failure: AuthFailure?
  var onConfirm: () -> Void
  var onEnterWords: (() -> Void)?
  var onClose: () -> Void

  @State private var visible = false
  @FocusState private var passwordFocused: Bool

  var body: some View {
    FittedSheet(busy: busy) { content }
      .onAppear { if request.factor == .password { passwordFocused = true } }
  }

  private var content: some View {
    VStack(spacing: 0) {
      header
      VStack(spacing: 16) {
        HeroDisc(icon: hero.icon, hue: hero.hue, shadow: request.factor == .noKey)
          .padding(.bottom, request.factor == .noKey ? 8 : 0)
        VStack(spacing: 6) {
          Text(title)
            .hType(.section)
            .foregroundStyle(HColor.textPrimary)
            .accessibilityAddTraits(.isHeader)
          Text(subtitle)
            .hType(.subheadline)
            .foregroundStyle(HColor.textSecondary)
            .infoTip(request.factor == .noKey ? Self.noKeyDetail : nil, about: "why this iPhone can't confirm")
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        switch request.factor {
        case .faceID:
          if !request.bullets.isEmpty { BulletCard(lines: request.bullets) }
        case .password:
          passwordField
          DeviceKeyRow()
        case .noKey:
          BulletCard(lines: Self.noKeyLines(otherDevice: request.otherDevice, entersWords: onEnterWords != nil))
        }
        if let message = otherFailure?.message {
          FieldErrorLine(text: message)
            .accessibilityIdentifier("confirm.failure")
        }
        primary
      }
      .padding(.top, 12)
    }
    .padding(.horizontal, HSpacing.insetPage)
    .padding(.bottom, 30)
  }

  private var header: some View {
    HStack {
      GlassIconButton(.close, label: "Close", action: onClose)
        .accessibilityIdentifier("confirm.cancel")
        .disabled(busy)
      Spacer(minLength: 8)
      Text("Confirm it's you")
        .hType(HType(size: 17, leading: 22, weight: .semibold, textStyle: .headline))
        .foregroundStyle(HColor.textPrimary)
        .lineLimit(1)
        .accessibilityIdentifier(hasalaCappedFigureIdentifier)
      Spacer(minLength: 8)
      Color.clear.frame(width: HSpacing.glassButton, height: HSpacing.glassButton)
    }
    .padding(.top, 21)
    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
  }

  private var hero: (icon: HIcon, hue: Hue) {
    switch request.factor {
    case .faceID: (biometry.icon, .sky)
    case .password: (.password, .other)
    case .noKey: (.lock, .sand)
    }
  }

  private var title: String { request.factor == .noKey ? "This iPhone can't confirm yet" : request.title }

  private var subtitle: String {
    switch request.factor {
    case .faceID: biometry.name.map { "\($0) confirms it's you, with your passkey." } ?? "Your passkey confirms it's you."
    case .password: "Your password, plus this iPhone's own key."
    case .noKey:
      "Changes need an iPhone where your data is open. It's still sealed here."
    }
  }

  static let noKeyDetail =
    "A password alone can't make a change. An iPhone with your data open signs it too."

  private var otherFailure: AuthFailure? {
    guard let failure, !(request.factor == .password && failure == .stepUpFailed) else { return nil }
    return failure
  }

  private var passwordField: some View {
    FieldFrame(
      label: "Current password",
      error: request.factor == .password && failure == .stepUpFailed ? failure?.message : nil,
      focused: passwordFocused, trailingPill: true, labelsField: true, onTap: { passwordFocused = true }
    ) {
      Group {
        if visible {
          TextField("", text: $password, prompt: .fieldPrompt("Your password"))
        } else {
          SecureField("", text: $password, prompt: .fieldPrompt("Your password"))
        }
      }
      .textContentType(.password)
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()
      .submitLabel(.done)
      .onSubmit { if !password.isEmpty, !busy { onConfirm() } }
      .focused($passwordFocused)
      .accessibilityIdentifier("confirm.password")
      .accessibilityLabel("Current password")
    } trailing: {
      ShowHidePill(visible: $visible)
    }
  }

  @ViewBuilder private var primary: some View {
    switch request.factor {
    case .faceID:
      Button(biometry.confirmTitle, action: onConfirm)
        .buttonStyle(.pill(.primary, fill: true, loading: busy, leadingIcon: biometry.icon))
        .accessibilityIdentifier("confirm.submit")
    case .password:
      Button("Confirm", action: onConfirm)
        .buttonStyle(.pill(.primary, fill: true, loading: busy))
        .disabled(password.isEmpty)
        .accessibilityIdentifier("confirm.submit")
    case .noKey:
      if let onEnterWords {
        Button("Enter my 12 words", action: onEnterWords)
          .buttonStyle(.pill(.primary, fill: true))
          .accessibilityIdentifier("confirm.enterWords")
      } else if request.otherDevice == nil {
        VStack(spacing: 8) {
          Link(destination: URL(string: "https://hasala.app/support")!) {
            Text("Talk to a person")
          }
          .buttonStyle(.pill(.primary, fill: true))
          .accessibilityIdentifier("confirm.talk")
          SecondaryLink(title: "Close", identifier: "confirm.close", action: onClose)
        }
      } else {
        Button("Close", action: onClose)
          .buttonStyle(.pill(.primary, fill: true))
          .accessibilityIdentifier("confirm.close")
      }
    }
  }

  static func noKeyLines(otherDevice: String?, entersWords: Bool) -> [String] {
    switch (entersWords, otherDevice) {
    case (true, let other?): ["Enter your 12 words to open it here", "Or make the change on \(other)"]
    case (true, nil): ["Enter your 12 words to open it here"]
    case (false, let other?): ["Make the change on \(other), where your data is open"]
    case (false, nil): ["Only an iPhone where your data is open can confirm this"]
    }
  }
}

struct FittedSheet<Content: View>: View {
  var busy = false
  @ViewBuilder var content: () -> Content

  @State private var height: CGFloat = 520
  @State private var bottomInset: CGFloat = 0
  @Environment(\.dynamicTypeSize) private var typeSize

  private var fitted: Bool { !typeSize.isAccessibilitySize }

  var body: some View {
    ScrollView {
      content()
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0.rounded(.up) }
    }
    .scrollBounceBehavior(.basedOnSize)
    .ignoresSafeArea(.container, edges: fitted ? .bottom : [])
    .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { inset in
      if inset < 60 { bottomInset = inset }
    }
    .presentationDetents(fitted ? [.height(max(height - bottomInset, 200))] : [.large])
    .presentationCornerRadius(HRadius.sheet)
    .presentationBackground(HColor.surfaceSecondary)
    .presentationDragIndicator(.visible)
    .interactiveDismissDisabled(busy)
  }
}

private struct DeviceKeyRow: View {
  var body: some View {
    HStack(spacing: 10) {
      Circle()
        .fill(Hue.mint.perceptualGradient)
        .frame(width: 32, height: 32)
        .overlay { HIconView(.phone, size: 18, color: Hue.mint.ink) }
      VStack(alignment: .leading, spacing: 1) {
        Text("This iPhone signs it too")
          .hType(.subheadline.weight(.semibold))
          .foregroundStyle(HColor.textPrimary)
        Text("Its own key, never sent")
          .hType(.footnote)
          .foregroundStyle(HColor.textSecondary)
      }
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      HIconView(.check, size: 20, color: HColor.statusSuccessForeground, strokeWidth: 2)
    }
    .padding(.vertical, 12)
    .padding(.horizontal, 14)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.field, style: .continuous))
    .accessibilityElement(children: .combine)
  }
}
