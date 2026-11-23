import HasalaDesign
import HasalaModels
import SwiftUI

enum AccountBack {
  case system
  case none
  case action(() -> Void)
}

let accountScreenBodyID = "account.screenBody"

struct AccountScreen<Content: View, Footer: View>: View {
  var title: String
  var subtitle: String?
  var email: EmailAside?
  var steps: (current: Int, of: Int)?
  var back: AccountBack
  var trailing: (title: String, action: () -> Void)?
  var wash: HWash
  @ViewBuilder var content: () -> Content
  @ViewBuilder var footer: () -> Footer

  init(
    title: String, subtitle: String? = nil, email: EmailAside? = nil, steps: (current: Int, of: Int)? = nil,
    back: AccountBack = .none, trailing: (title: String, action: () -> Void)? = nil, wash: HWash = .setup,
    @ViewBuilder content: @escaping () -> Content, @ViewBuilder footer: @escaping () -> Footer
  ) {
    self.title = title
    self.subtitle = subtitle
    self.email = email
    self.steps = steps
    self.back = back
    self.trailing = trailing
    self.wash = wash
    self.content = content
    self.footer = footer
  }

  @State private var keyboardUp = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        QuestionBlock(title: title, subtitle: subtitle, email: email, top: hasHeader ? 16 : 24 + 16)
        content()
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, 24)
      }
      .id(accountScreenBodyID)
      .padding(.horizontal, HSpacing.insetPage)
      .padding(.bottom, 16)
    }
    .scrollBounceBehavior(.basedOnSize)
    .dockScrollEdge()
    .contentMargins(.bottom, accountDockClearance, for: .scrollContent)
    .scrollDismissesKeyboard(.interactively)
    .safeAreaBar(edge: .bottom) {
      ActionDock(keyboardUp: keyboardUp, content: footer)
    }
    .onGeometryChange(for: Bool.self) { $0.safeAreaInsets.bottom > 120 } action: { keyboardUp = $0 }
    .background(alignment: .top) {
      AmbientWash(wash).ignoresSafeArea(edges: .top)
    }
    .background(HColor.surfaceSecondary)
    .accountHeader(steps: steps, back: back, trailing: trailing)
  }

  private var hasHeader: Bool {
    if case .none = back { return steps != nil || trailing != nil }
    return true
  }
}

extension AccountScreen where Footer == EmptyView {
  init(
    title: String, subtitle: String? = nil, email: EmailAside? = nil, steps: (current: Int, of: Int)? = nil,
    back: AccountBack = .none, trailing: (title: String, action: () -> Void)? = nil, wash: HWash = .setup,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.init(title: title, subtitle: subtitle, email: email, steps: steps, back: back, trailing: trailing,
              wash: wash, content: content, footer: { EmptyView() })
  }
}

extension View {
  func accountHeader(
    steps: (current: Int, of: Int)? = nil, back: AccountBack, trailing: (title: String, action: () -> Void)? = nil
  ) -> some View {
    modifier(AccountHeader(steps: steps, back: back, trailing: trailing))
  }
}

private struct AccountHeader: ViewModifier {
  let steps: (current: Int, of: Int)?
  let back: AccountBack
  let trailing: (title: String, action: () -> Void)?

  func body(content: Content) -> some View {
    content
      .navigationBarTitleDisplayMode(.inline)
      .navigationBarBackButtonHidden(!isSystemBack)
      .toolbar(isEmpty ? .hidden : .automatic, for: .navigationBar)
      .toolbar {
        if case .action(let run) = back {
          ToolbarItem(placement: .topBarLeading) {
            Button(action: run) {
              Image(systemName: "chevron.backward")
            }
            .tint(HColor.appleLabelsVibrantPrimary)
            .accessibilityLabel("Back")
          }
        }
        if let steps {
          ToolbarItem(placement: .principal) {
            StepIndicator(current: steps.current, of: steps.of)
          }
          .sharedBackgroundVisibility(.hidden)
        }
        if let trailing {
          ToolbarItem(placement: .topBarTrailing) {
            Button(action: trailing.action) {
              Text(trailing.title)
                .hType(HType(size: 17, leading: 22, weight: .regular, textStyle: .body))
                .foregroundStyle(HColor.textOnWashLink)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("account.trailing")
          }
          .sharedBackgroundVisibility(.hidden)
        }
      }
  }

  private var isSystemBack: Bool {
    if case .system = back { return true }
    return false
  }

  private var isEmpty: Bool {
    if case .none = back { return steps == nil && trailing == nil }
    return false
  }
}

private struct QuestionBlock: View {
  let title: String
  let subtitle: String?
  var email: EmailAside?
  let top: CGFloat

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .hType(.title1)
        .foregroundStyle(HColor.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
      if subtitle != nil || email != nil {
        SubtitleProse(text: subtitle, email: email)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.top, top)
  }
}

struct EmailAside: Equatable {
  var address: String
  var after: String?
}

struct SubtitleProse: View {
  var text: String?
  var email: EmailAside?
  var alignment: HorizontalAlignment = .leading

  var body: some View {
    VStack(alignment: alignment, spacing: 4) {
      if let text {
        Text(text)
          .hType(.body)
          .foregroundStyle(HColor.textOnWashSecondary)
      }
      if let email {
        Text(email.address)
          .hType(.body.weight(.semibold))
          .foregroundStyle(HColor.textPrimary)
          .lineLimit(2)
          .truncationMode(.middle)
        if let after = email.after {
          Text(after)
            .hType(.body)
            .foregroundStyle(HColor.textOnWashSecondary)
        }
      }
    }
    .accessibilityElement(children: .combine)
  }
}

let accountDockClearance: CGFloat = 12

struct ActionDock<Content: View>: View {
  let keyboardUp: Bool
  @ViewBuilder let content: () -> Content

  var body: some View {
    VStack(spacing: 4) { content() }
      .frame(maxWidth: .infinity)
      .padding(.horizontal, HSpacing.insetPage)
      .padding(.top, 8)
      .padding(.bottom, keyboardUp ? 12 : 0)
      .environment(\.pillDisabledBase, HColor.surfaceSecondary)
      .environment(\.dockTyping, keyboardUp)
      .hAnimation(.fade, value: keyboardUp)
  }
}

extension EnvironmentValues {
  @Entry var dockTyping = false
}

private struct DockScrollEdge: ViewModifier {
  @State private var overflows = false

  func body(content: Content) -> some View {
    content
      .scrollEdgeEffectStyle(.hard, for: .bottom)
      .scrollEdgeEffectHidden(!overflows, for: .bottom)
      .onScrollGeometryChange(for: Bool.self) { g in
        g.contentSize.height + g.contentInsets.top + g.contentInsets.bottom > g.containerSize.height + 0.5
      } action: { _, now in
        overflows = now
      }
  }
}

extension View {
  func dockScrollEdge() -> some View {
    modifier(DockScrollEdge())
  }
}

private struct DockLinkWhileTyping: ViewModifier {
  @Environment(\.dockTyping) private var typing

  func body(content: Content) -> some View {
    if !typing {
      content.transition(.opacity)
    }
  }
}

extension View {
  func dockLink() -> some View {
    modifier(DockLinkWhileTyping())
  }

  func revealsOnKeyboard(_ id: String) -> some View {
    modifier(KeyboardReveal(id: id))
  }
}

private struct KeyboardReveal: ViewModifier {
  let id: String
  @Environment(\.hMotion) private var motion

  func body(content: Content) -> some View {
    ScrollViewReader { proxy in
      content
        .onGeometryChange(for: Bool.self) { $0.safeAreaInsets.bottom > 120 } action: { up in
          guard up else { return }
          Task { withAnimation(motion.animation(.fade)) { proxy.scrollTo(id) } }
        }
    }
  }
}

extension AccountScreen {
  init<Main: View, Actions: View>(
    title: String, subtitle: String? = nil, email: EmailAside? = nil, steps: (current: Int, of: Int)? = nil,
    back: AccountBack = .none, trailing: (title: String, action: () -> Void)? = nil, wash: HWash = .setup,
    @ViewBuilder content: @escaping () -> Main, @ViewBuilder actions: @escaping () -> Actions
  ) where Content == ActionsAfterContent<Main, Actions>, Footer == DockedActions<Actions> {
    self.init(
      title: title, subtitle: subtitle, email: email, steps: steps, back: back, trailing: trailing, wash: wash,
      content: { ActionsAfterContent(content: content(), actions: actions) },
      footer: { DockedActions(actions: actions) })
  }
}

struct ActionsAfterContent<Main: View, Actions: View>: View {
  let content: Main
  let actions: () -> Actions

  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      content
      if typeSize.isAccessibilitySize {
        VStack(spacing: 4) { actions() }
          .frame(maxWidth: .infinity)
          .padding(.top, 32)
      }
    }
  }
}

struct DockedActions<Actions: View>: View {
  let actions: () -> Actions

  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    if !typeSize.isAccessibilitySize {
      VStack(spacing: 4) { actions() }
    }
  }
}

struct CelebrationScreen<Cards: View, Footer: View>: View {
  var badge: SuccessBadge.Content?
  var title: String
  var subtitle: String?
  var email: EmailAside?
  var wash: HWash
  var successHaptic: Bool
  var spacing: (top: CGFloat, cards: CGFloat)
  @ViewBuilder var cards: () -> Cards
  @ViewBuilder var footer: () -> Footer

  init(
    badge: SuccessBadge.Content? = .check, title: String, subtitle: String? = nil, email: EmailAside? = nil,
    wash: HWash = .ready, successHaptic: Bool = false, spacing: (top: CGFloat, cards: CGFloat) = (76, 36),
    @ViewBuilder cards: @escaping () -> Cards, @ViewBuilder footer: @escaping () -> Footer
  ) {
    self.badge = badge
    self.title = title
    self.subtitle = subtitle
    self.email = email
    self.wash = wash
    self.successHaptic = successHaptic
    self.spacing = spacing
    self.cards = cards
    self.footer = footer
  }

  @State private var keyboardUp = false
  @State private var landed = false
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    ScrollView {
      VStack(spacing: 0) {
        VStack(spacing: 20) {
          if let badge { SuccessBadge(content: badge) }
          VStack(spacing: 8) {
            Text(title)
              .hType(.largeTitle)
              .foregroundStyle(HColor.textPrimary)
              .accessibilityAddTraits(.isHeader)
            if subtitle != nil || email != nil {
              SubtitleProse(text: subtitle, email: email, alignment: .center)
                .frame(maxWidth: 300)
            }
          }
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.top, badge == nil ? min(40, spacing.top) : spacing.top)
        cards()
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, HSpacing.insetPage)
          .padding(.top, spacing.cards)
        if typeSize.isAccessibilitySize {
          VStack(spacing: 4) { footer() }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, HSpacing.insetPage)
            .padding(.top, 32)
            .environment(\.pillDisabledBase, HColor.surfaceSecondary)
        }
      }
      .padding(.bottom, 16)
    }
    .scrollBounceBehavior(.basedOnSize)
    .dockScrollEdge()
    .contentMargins(.bottom, accountDockClearance, for: .scrollContent)
    .safeAreaBar(edge: .bottom) {
      if !typeSize.isAccessibilitySize {
        ActionDock(keyboardUp: keyboardUp, content: footer)
      }
    }
    .background(alignment: .top) {
      AmbientWash(wash).ignoresSafeArea(edges: .top)
    }
    .background(HColor.surfaceSecondary)
    .navigationBarBackButtonHidden()
    .toolbar(.hidden, for: .navigationBar)
    .task {
      guard successHaptic, !landed else { return }
      try? await Task.sleep(for: .seconds(HMotion.celebrateResponse))
      landed = true
    }
    .hHaptic(.success, trigger: landed)
  }
}

extension CelebrationScreen where Footer == EmptyView {
  init(
    badge: SuccessBadge.Content? = .check, title: String, subtitle: String? = nil, email: EmailAside? = nil,
    wash: HWash = .ready, successHaptic: Bool = false, spacing: (top: CGFloat, cards: CGFloat) = (76, 36),
    @ViewBuilder cards: @escaping () -> Cards
  ) {
    self.init(badge: badge, title: title, subtitle: subtitle, email: email, wash: wash,
              successHaptic: successHaptic, spacing: spacing, cards: cards, footer: { EmptyView() })
  }
}

struct IconTile: View {
  var icon: HIcon
  var hue: Hue

  var body: some View {
    CategoryDisc(hue: hue, icon: icon, size: .s40)
  }
}

struct HueChip: View {
  var text: String
  var hue: Hue = .mint

  var body: some View {
    Text(text)
      .hType(HType(size: 13, leading: 18, weight: .semibold, textStyle: .footnote))
      .foregroundStyle(hue.ink)
      .lineLimit(1)
      .minimumScaleFactor(0.5)
      .padding(.horizontal, 9)
      .frame(minHeight: 24)
      .background(hue.perceptualGradient, in: Capsule())
  }
}

struct OptionCard: View {
  enum ButtonKind { case primary, secondary }

  var icon: HIcon
  var hue: Hue
  var chip: String?
  var title: String
  var detail: String
  var buttonTitle: String
  var buttonKind: ButtonKind = .secondary
  var buttonIcon: HIcon?
  var busy = false
  var identifier: String
  var action: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top, spacing: 12) {
        IconTile(icon: icon, hue: hue)
        CardText(chip: chip, title: title, detail: detail)
      }
      .accessibilityElement(children: .combine)
      Button(buttonTitle, action: action)
        .buttonStyle(CardButtonStyle(kind: buttonKind, icon: buttonIcon, loading: busy))
        .accessibilityIdentifier(identifier)
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
  }
}

private struct CardButtonStyle: ButtonStyle {
  let kind: OptionCard.ButtonKind
  let icon: HIcon?
  let loading: Bool

  func makeBody(configuration: Configuration) -> some View {
    CardButtonBody(configuration: configuration, kind: kind, icon: icon, loading: loading)
  }
}

private struct CardButtonBody: View {
  let configuration: ButtonStyleConfiguration
  let kind: OptionCard.ButtonKind
  let icon: HIcon?
  let loading: Bool
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.hMotion) private var policy
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let pressed = configuration.isPressed && !loading
    let motion = MotionPolicy(reduceMotion: policy.reduceMotion || reduceMotion, settled: policy.settled)
    HStack(spacing: 8) {
      if loading {
        Spinner(size: 20, tint: foreground,
                track: kind == .primary ? HColor.white.opacity(0.35) : HColor.actionAccentSubtlePressed)
      } else if let icon {
        HIconView(icon, size: 20, color: foreground, strokeWidth: 2)
      }
      configuration.label.multilineTextAlignment(.center)
    }
    .hType(HType(size: 17, leading: 24, weight: .semibold, textStyle: .body))
    .foregroundStyle(foreground)
    .padding(.horizontal, 12)
    .frame(maxWidth: .infinity, minHeight: 50)
    .background(fill(pressed: pressed), in: Capsule())
    .contentShape(Capsule())
    .scaleEffect(pressed && !motion.isStill ? HMotion.pressScale : 1)
    .animation(pressed ? nil : motion.animation(.press), value: pressed)
    .allowsHitTesting(!loading)
    .accessibilityValue(loading ? Text("In progress") : Text(""))
  }

  private var foreground: Color {
    guard isEnabled else { return HColor.textDisabled }
    return kind == .primary ? HColor.textOnAccent : HColor.textLink
  }

  private func fill(pressed: Bool) -> Color {
    guard isEnabled else { return HColor.appleFillsSecondary }
    switch kind {
    case .primary: return pressed ? HColor.actionAccentPressed : HColor.actionAccent
    case .secondary: return pressed ? HColor.actionAccentSubtlePressed : HColor.actionAccentSubtle
    }
  }
}

struct SelectionCard: View {
  var icon: HIcon
  var hue: Hue
  var chip: String?
  var title: String
  var detail: String
  var selected: Bool
  var identifier: String
  var action: () -> Void

  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    Button(action: action) {
      Group {
        if typeSize.isAccessibilitySize {
          VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
              IconTile(icon: icon, hue: hue)
              Spacer(minLength: 12)
              Radio(on: selected)
            }
            CardText(chip: chip, title: title, detail: detail)
          }
        } else {
          HStack(alignment: .top, spacing: 12) {
            IconTile(icon: icon, hue: hue)
            CardText(chip: chip, title: title, detail: detail)
            Radio(on: selected)
          }
        }
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: HRadius.card + 2, style: .continuous)
          .strokeBorder(HColor.actionAccent, lineWidth: 2)
          .padding(-2)
          .opacity(selected ? 1 : 0)
      }
      .hAnimation(.thumbSlide, value: selected)
    }
    .buttonStyle(HPressStyle(in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous), scales: false))
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    .accessibilityIdentifier(identifier)
  }
}

private struct Radio: View {
  let on: Bool

  var body: some View {
    ZStack {
      Circle().strokeBorder(HColor.controlCheckUnselected, lineWidth: 1.5).opacity(on ? 0 : 1)
      Circle().fill(HColor.actionAccent).opacity(on ? 1 : 0)
      HIconView(.check, size: 14, color: HColor.white, strokeWidth: 3).opacity(on ? 1 : 0)
    }
    .frame(width: 24, height: 24)
    .accessibilityHidden(true)
  }
}

private struct CardText: View {
  let chip: String?
  let title: String
  let detail: String

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      if let chip { HueChip(text: chip) }
      Text(title)
        .hType(HType(size: 17, leading: 22, weight: .semibold, textStyle: .headline))
        .foregroundStyle(HColor.textPrimary)
        .padding(.top, chip == nil ? 0 : 4)
      Text(detail)
        .hType(.subheadline)
        .foregroundStyle(HColor.textSecondary)
    }
    .multilineTextAlignment(.leading)
    .fixedSize(horizontal: false, vertical: true)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct InfoCard: View {
  var icon: HIcon
  var hue: Hue
  var title: String
  var detail: String
  var radius: CGFloat = HRadius.listGroup

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      IconTile(icon: icon, hue: hue)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).hType(.rowTitle).foregroundStyle(HColor.textPrimary)
        Text(detail).hType(.subheadline).foregroundStyle(HColor.textSecondary)
      }
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(16)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    .accessibilityElement(children: .combine)
  }
}

struct NoteRow: View {
  var icon: HIcon
  var text: String

  @ScaledMetric(relativeTo: .footnote) private var lane: CGFloat = 18

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      HIconView(icon, size: 18, color: HColor.iconSecondary).frame(height: lane)
      Text(text)
        .hType(.footnote)
        .foregroundStyle(HColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.top, 4)
    .padding(.horizontal, 4)
    .accessibilityElement(children: .combine)
  }
}

struct WarningCallout: View {
  var icon: HIcon = .cameraSlash
  var text: String

  @ScaledMetric(relativeTo: .subheadline) private var lane: CGFloat = 20

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      HIconView(icon, size: 20, color: HColor.statusWarningForeground).frame(height: lane)
      Text(text)
        .hType(.subheadline.weight(.medium))
        .foregroundStyle(HColor.statusWarningForeground)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 14)
    .padding(.horizontal, 16)
    .background(HColor.statusWarningSurface, in: RoundedRectangle(cornerRadius: HRadius.tile, style: .continuous))
    .accessibilityElement(children: .combine)
  }
}

struct HintCard: View {
  var icon: HIcon = .envelope
  var text: String

  @ScaledMetric(relativeTo: .footnote) private var lane: CGFloat = 18

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      HIconView(icon, size: 18, color: HColor.iconSecondary).frame(height: lane)
      Text(text)
        .hType(.footnote)
        .foregroundStyle(HColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 12)
    .padding(.horizontal, 14)
    .background(HColor.surfaceOnWash, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .accessibilityElement(children: .combine)
  }
}

struct SecondaryLink: View {
  var title: String
  var identifier: String
  var role: ButtonRole?
  var action: () -> Void

  var body: some View {
    Button(role: role, action: action) {
      Text(title)
        .hType(HType(size: 17, leading: 22, weight: .semibold, textStyle: .body))
        .foregroundStyle(role == .destructive ? HColor.actionDestructive : HColor.textLink)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier(identifier)
    .dockLink()
  }
}

struct ActionNote: View {
  var text: String

  var body: some View {
    Text(text)
      .hType(HType(size: 15, leading: 22, weight: .regular, textStyle: .subheadline))
      .foregroundStyle(HColor.textSecondary)
      .multilineTextAlignment(.center)
      .padding(.horizontal, 16)
      .frame(maxWidth: .infinity, minHeight: 44)
  }
}

struct LabeledField<Field: View, Accessory: View>: View {
  var label: String
  var footer: String?
  var error: String?
  var focused = false
  @ViewBuilder var field: () -> Field
  @ViewBuilder var accessory: () -> Accessory

  var body: some View {
    FieldFrame(label: label, help: footer, error: error, focused: focused,
               trailingPill: Accessory.self != EmptyView.self) {
      field()
    } trailing: {
      accessory()
    }
  }
}

extension LabeledField where Accessory == EmptyView {
  init(label: String, footer: String? = nil, error: String? = nil, focused: Bool = false,
       @ViewBuilder field: @escaping () -> Field) {
    self.init(label: label, footer: footer, error: error, focused: focused, field: field, accessory: { EmptyView() })
  }
}

struct StatusLine: View {
  enum Tone { case success, error, info }
  enum Size { case small, regular }
  var text: String
  var tone: Tone
  var size: Size = .small

  @ScaledMetric(relativeTo: .footnote) private var smallLane: CGFloat = 18
  @ScaledMetric(relativeTo: .subheadline) private var regularLane: CGFloat = 20

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Circle().fill(color).frame(width: 7, height: 7).frame(height: size == .regular ? regularLane : smallLane)
      Text(text)
        .hType((size == .regular ? HType.subheadline : HType.footnote).weight(tone == .info ? .regular : .semibold))
        .foregroundStyle(color)
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("status.\(tone)")
  }

  private var color: Color {
    switch tone {
    case .success: HColor.statusSuccessForeground
    case .error: HColor.statusErrorForeground
    case .info: HColor.textSecondary
    }
  }
}

struct NoteCard: View {
  var systemImage: String
  var title: String?
  var text: String
  var tint: Color = HColor.surfacePrimary

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: systemImage)
        .font(.system(size: 17, weight: .medium))
        .foregroundStyle(HColor.iconPrimary)
        .frame(width: 22)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        if let title {
          Text(title).hType(.rowTitle).foregroundStyle(HColor.textPrimary)
        }
        Text(text)
          .hType(.subheadline)
          .foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .padding(16)
    .background(tint, in: RoundedRectangle(cornerRadius: HRadius.tile, style: .continuous))
    .accessibilityElement(children: .combine)
  }
}

struct LockNote: View {
  var text: String
  var systemImage = "lock"

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: systemImage)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(HColor.iconSecondary)
        .padding(.top, 2)
        .accessibilityHidden(true)
      Text(text)
        .hType(.footnote)
        .foregroundStyle(HColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct BusyButton: View {
  var title: String
  var busy: Bool
  var kind: PillButtonStyle.Kind = .primary
  var enabled = true
  var identifier: String
  var action: () -> Void

  var body: some View {
    Button(title, action: action)
      .buttonStyle(.pill(kind, fill: true, loading: busy))
      .disabled(!enabled)
      .accessibilityIdentifier(identifier)
  }
}

typealias LinkButton = SecondaryLink

struct FailureBanner: View {
  var failure: AuthFailure?

  var body: some View {
    if let message = failure?.message {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: "exclamationmark.circle.fill")
          .foregroundStyle(HColor.statusErrorForeground)
          .accessibilityHidden(true)
        Text(message)
          .hType(.subheadline)
          .foregroundStyle(HColor.statusErrorForeground)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
      }
      .padding(14)
      .background(HColor.statusErrorSurface, in: RoundedRectangle(cornerRadius: HRadius.control, style: .continuous))
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("account.failure")
      .announcesError(message)
      .hTransition(.rise)
    }
  }
}

@MainActor
enum ErrorAnnouncer {
  static var post: (String) -> Void = { message in
    var text = AttributedString(message)
    text.accessibilitySpeechAnnouncementPriority = .high
    AccessibilityNotification.Announcement(text).post()
  }
}

private struct ErrorAnnouncement: ViewModifier {
  let message: String?
  let delay: Duration
  let key: AnyHashable?

  func body(content: Content) -> some View {
    content.task(id: [AnyHashable(message), key]) {
      guard let message, !message.isEmpty else { return }
      if delay > .zero {
        try? await Task.sleep(for: delay)
        guard !Task.isCancelled else { return }
      }
      ErrorAnnouncer.post(message)
    }
  }
}

extension View {
  func announcesError(_ message: String?, after delay: Duration = .zero, key: AnyHashable? = nil) -> some View {
    modifier(ErrorAnnouncement(message: message, delay: delay, key: key))
  }
}

struct WebLink: View {
  var title: String
  var url: String
  var identifier: String

  var body: some View {
    Link(destination: URL(string: url)!) {
      Text(title)
        .hType(HType(size: 17, leading: 22, weight: .semibold, textStyle: .body))
        .foregroundStyle(HColor.textLink)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(Rectangle())
    }
    .accessibilityIdentifier(identifier)
    .dockLink()
  }
}

struct InlineTextButton: View {
  var title: String
  var identifier: String
  var action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(title)
        .hType(.subheadline.weight(.semibold))
        .foregroundStyle(HColor.textLink)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier(identifier)
  }
}
