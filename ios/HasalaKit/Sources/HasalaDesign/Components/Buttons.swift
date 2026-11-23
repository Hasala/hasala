import HasalaModels
import SwiftUI

public struct PillButtonStyle: ButtonStyle {
  public enum Kind: Sendable {
    case primary
    case secondary
    case onGrouped
    case tertiary
    case destructive
    case destructiveQuiet
    case destructiveText
  }

  public enum Size: Sendable {
    case large, medium, small

    var height: CGFloat {
      switch self {
      case .large: HSpacing.buttonHeightLarge
      case .medium: HSpacing.buttonHeightMedium
      case .small: HSpacing.buttonHeightSmall
      }
    }

    public var hitOutset: CGFloat {
      self == .small ? 4 : 0
    }

    var inset: CGFloat {
      switch self {
      case .large: HSpacing.buttonInsetLarge
      case .medium: HSpacing.buttonInsetMedium
      case .small: HSpacing.buttonInsetSmall
      }
    }
  }

  let kind: Kind
  let size: Size
  let fill: Bool
  let loading: Bool
  let leadingIcon: HIcon?
  let greysWhenDisabled: Bool

  public init(_ kind: Kind = .primary, size: Size = .large, fill: Bool = false, loading: Bool = false,
              leadingIcon: HIcon? = nil, greysWhenDisabled: Bool = false)
  {
    self.kind = kind
    self.size = size
    self.fill = fill
    self.loading = loading
    self.leadingIcon = leadingIcon
    self.greysWhenDisabled = greysWhenDisabled
  }

  enum Leading: Equatable {
    case empty
    case icon(HIcon)
    case spinner
  }

  static func leading(icon: HIcon?, loading: Bool, spinnerDue: Bool) -> Leading {
    if loading && spinnerDue { return .spinner }
    return icon.map(Leading.icon) ?? .empty
  }

  public func makeBody(configuration: Configuration) -> some View {
    PillButtonBody(configuration: configuration, kind: kind, size: size, fill: fill, loading: loading,
                   leadingIcon: leadingIcon, greysWhenDisabled: greysWhenDisabled)
  }

  public static func disabledFill(_ kind: Kind, greysWhenDisabled: Bool) -> Color {
    switch kind {
    case .onGrouped where greysWhenDisabled: return HColor.appleFillsSecondary
    case .onGrouped, .destructiveQuiet: return HColor.surfacePrimary
    case .tertiary, .destructiveText: return .clear
    default: return HColor.appleFillsSecondary
    }
  }
}

public extension ButtonStyle where Self == PillButtonStyle {
  static func pill(
    _ kind: PillButtonStyle.Kind = .primary, size: PillButtonStyle.Size = .large, fill: Bool = false,
    loading: Bool = false, leadingIcon: HIcon? = nil, greysWhenDisabled: Bool = false
  ) -> PillButtonStyle {
    PillButtonStyle(kind, size: size, fill: fill, loading: loading, leadingIcon: leadingIcon,
                    greysWhenDisabled: greysWhenDisabled)
  }
}

struct PillButtonBody: View {
  let configuration: ButtonStyleConfiguration
  let kind: PillButtonStyle.Kind
  let size: PillButtonStyle.Size
  let fill: Bool
  let loading: Bool
  let leadingIcon: HIcon?
  let greysWhenDisabled: Bool
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.pillDisabledBase) private var disabledBase
  @ResolvedMotion private var motion: MotionPolicy
  @State private var showsSpinner = false

  var body: some View {
    let pressed = configuration.isPressed && !loading
    HStack(spacing: leadingIcon == .faceID ? 10 : 8) {
      switch PillButtonStyle.leading(icon: leadingIcon, loading: loading, spinnerDue: showsSpinner) {
      case .spinner:
        Spinner(size: size == .small ? 16 : 20, tint: foreground, track: spinnerTrack)
      case .icon(let icon):
        HIconView(icon, size: icon == .faceID ? 22 : HSpacing.iconInline, color: foreground)
      case .empty:
        EmptyView()
      }
      configuration.label
        .multilineTextAlignment(.center)
        .lineLimitAtDefaultTextSize(1)
    }
    .hType(size == .small ? .smallButton : .button)
    .foregroundStyle(foreground)
    .padding(.horizontal, kind == .destructiveText ? 8 : (fill ? 12 : size.inset))
    .padding(.vertical, 4)
    .frame(maxWidth: fill ? .infinity : nil, minHeight: size.height)
    .background(background(pressed: pressed), in: Capsule())
    .background {
      if !isEnabled, let disabledBase, disabledFillIsTranslucent {
        Capsule().fill(disabledBase)
      }
    }
    .contentShape(Capsule().inset(by: -size.hitOutset))
    .scaleEffect(pressed && !motion.isStill ? HMotion.pressScale : 1)
    .animation(pressed ? nil : motion.animation(.press), value: pressed)
    .allowsHitTesting(!loading)
    .accessibilityValue(loading ? Text("In progress") : Text(""))
    .task(id: loading) {
      guard loading else {
        showsSpinner = false
        return
      }
      try? await Task.sleep(for: .milliseconds(300))
      if !Task.isCancelled { showsSpinner = true }
    }
  }

  private var foreground: Color {
    if !isEnabled { return HColor.textDisabled }
    switch kind {
    case .primary, .destructive: return HColor.textOnAccent
    case .secondary, .onGrouped, .tertiary: return HColor.textLink
    case .destructiveQuiet, .destructiveText: return HColor.actionDestructive
    }
  }

  private var spinnerTrack: Color {
    switch kind {
    case .primary, .destructive: HColor.white.opacity(0.35)
    default: HColor.actionAccentSubtlePressed
    }
  }

  private var disabledFillIsTranslucent: Bool {
    switch kind {
    case .onGrouped: greysWhenDisabled
    case .destructiveQuiet, .tertiary, .destructiveText: false
    case .primary, .secondary, .destructive: true
    }
  }

  private func background(pressed: Bool) -> Color {
    if !isEnabled {
      return PillButtonStyle.disabledFill(kind, greysWhenDisabled: greysWhenDisabled)
    }
    switch kind {
    case .primary: return pressed ? HColor.actionAccentPressed : HColor.actionAccent
    case .secondary: return pressed ? HColor.actionAccentSubtlePressed : HColor.actionAccentSubtle
    case .onGrouped, .destructiveQuiet: return pressed ? HColor.listRowSurfacePressed : HColor.surfacePrimary
    case .tertiary, .destructiveText: return pressed ? HColor.stateLayerPressed : .clear
    case .destructive: return pressed ? HColor.actionDestructivePressed : HColor.actionDestructive
    }
  }
}

public struct HPressStyle: ButtonStyle {
  let shape: AnyShape
  let scales: Bool

  public init(scales: Bool = true) {
    self.init(in: Capsule(), scales: scales)
  }

  public init<S: Shape>(in shape: S, scales: Bool = true) {
    self.shape = AnyShape(shape)
    self.scales = scales
  }

  public func makeBody(configuration: Configuration) -> some View {
    PressBody(configuration: configuration, shape: shape, scales: scales)
  }

  struct PressBody: View {
    let configuration: ButtonStyleConfiguration
    let shape: AnyShape
    let scales: Bool
    @ResolvedMotion private var motion: MotionPolicy

    var body: some View {
      let pressed = configuration.isPressed
      configuration.label
        .overlay { if pressed { shape.fill(HColor.stateLayerPressed) } }
        .contentShape(shape)
        .scaleEffect(pressed && scales && !motion.isStill ? HMotion.pressScale : 1)
        .animation(pressed ? nil : motion.animation(.press), value: pressed)
    }
  }
}

public struct HRowPressStyle: ButtonStyle {
  public init() {}

  public func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .contentShape(Rectangle())
      .background(configuration.isPressed ? HColor.listRowSurfacePressed : .clear)
      .animation(.easeOut(duration: HMotion.highlight), value: configuration.isPressed)
  }
}

public struct ProviderButton: View {
  let provider: MailProviderKind
  let loading: Bool
  let action: () -> Void

  public init(provider: MailProviderKind, loading: Bool = false, action: @escaping () -> Void) {
    self.provider = provider
    self.loading = loading
    self.action = action
  }

  public var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        if !loading { ProviderMark(provider, size: .disc26) }
        Text(provider.continueTitle)
      }
    }
    .buttonStyle(.pill(.primary, size: .large, fill: true, loading: loading))
  }
}

public struct HInlineLinkStyle: ButtonStyle {
  public static let minimumHitHeight: CGFloat = 44
  let color: Color

  public init(color: Color = HColor.textLink) {
    self.color = color
  }

  public func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .hType(.inlineLink)
      .foregroundStyle(color)
      .opacity(configuration.isPressed ? 0.6 : 1)
      .frame(minHeight: Self.minimumHitHeight)
      .contentShape(Rectangle())
  }
}

public extension ButtonStyle where Self == HInlineLinkStyle {
  static var inlineLink: HInlineLinkStyle { HInlineLinkStyle() }
  static func inlineLink(color: Color) -> HInlineLinkStyle { HInlineLinkStyle(color: color) }
}

public extension EnvironmentValues {
  @Entry var pillDisabledBase: Color? = nil
}
