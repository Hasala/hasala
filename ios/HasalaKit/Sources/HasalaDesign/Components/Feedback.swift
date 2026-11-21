import HasalaModels
import SwiftUI

public struct ToastTouch: Sendable, Equatable {
  public enum Effect: Sendable, Equatable {
    case hold, resume, dismiss
  }

  public static let dismissPull: CGFloat = 24

  private var held = false

  public init() {}

  public mutating func moved() -> Effect? {
    guard !held else { return nil }
    held = true
    return .hold
  }

  public mutating func ended(pulled: CGFloat) -> Effect? {
    let wasHeld = held
    held = false
    if pulled > Self.dismissPull { return .dismiss }
    return wasHeld ? .resume : nil
  }

  public mutating func lost() -> Effect? {
    guard held else { return nil }
    held = false
    return .resume
  }
}

public struct GlassToast: View {
  public enum Disc: Sendable {
    case accent(HIcon)
    case ink(HIcon)
  }

  private let disc: Disc
  let title: String
  let subtitle: String?
  let actionTitle: String?
  let action: (() -> Void)?
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.dynamicTypeSize) private var typeSize

  public init(_ disc: Disc = .accent(.check), title: String, subtitle: String? = nil, actionTitle: String? = nil,
              action: (() -> Void)? = nil)
  {
    self.disc = disc
    self.title = title
    self.subtitle = subtitle
    self.actionTitle = actionTitle
    self.action = action
  }

  public var body: some View {
    HStack(spacing: 12) {
      discView
      VStack(alignment: .leading, spacing: 0) {
        Text(title)
          .hType(subtitle == nil ? .rowTitle : HType(size: 16, leading: 20, weight: .semibold, textStyle: .callout))
          .foregroundStyle(HColor.textPrimary)
        if let subtitle {
          Text(subtitle).hType(HType(size: 13, leading: 16, weight: .regular, textStyle: .footnote))
            .foregroundStyle(HColor.textSecondary)
        }
      }
      .fixedSize(horizontal: false, vertical: true)
      if let actionTitle {
        Button(actionTitle) { action?() }
          .buttonStyle(.plain)
          .hType(.rowTitle)
          .foregroundStyle(HColor.textLink)
          .frame(minWidth: 44, minHeight: 44)
          .contentShape(Rectangle())
      }
    }
    .padding(.leading, 10)
    .padding(.trailing, 18)
    .padding(.vertical, 6)
    .frame(minHeight: HSpacing.toastHeight)
    .background {
      if !reduceTransparency {
        Capsule().fill(.regularMaterial)
          .overlay { Capsule().fill(HColor.materialGlassFrostStrong) }
      }
    }
    .hGlass(in: Capsule(), interactive: false)
    .shadow(color: HColor.materialGlassShadowFar, radius: 12, x: 0, y: 8)
    .accessibilityElement(children: .contain)
    .frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : Self.maxWidth)
  }

  public static let maxWidth: CGFloat = 320

  @ViewBuilder private var discView: some View {
    switch disc {
    case .accent(let icon):
      Circle().fill(HColor.actionAccent).frame(width: 36, height: 36)
        .overlay { HIconView(icon, size: HSpacing.iconInline, color: HColor.iconOnAccent, strokeWidth: 2.6) }
        .accessibilityHidden(true)
    case .ink(let icon):
      Circle().fill(HColor.textPrimary).frame(width: 36, height: 36)
        .overlay { HIconView(icon, size: HSpacing.iconInline, color: HColor.white, strokeWidth: 2.1) }
        .accessibilityHidden(true)
    }
  }
}

public struct Spinner: View {
  let size: CGFloat
  let tint: Color
  let track: Color
  @ResolvedMotion private var motion: MotionPolicy
  @State private var turning = false

  public init(size: CGFloat = 16, tint: Color = HColor.actionAccent, track: Color = HColor.actionAccentSubtlePressed) {
    self.size = size
    self.tint = tint
    self.track = track
  }

  public var body: some View {
    let line = size * 3 / 24
    ZStack {
      Circle().stroke(track, lineWidth: line)
      Circle().trim(from: 0, to: 0.25).stroke(tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
        .rotationEffect(.degrees(turning ? 270 : -90))
    }
    .padding(size * 3 / 24)
    .frame(width: size, height: size)
    .onAppear {
      guard !motion.isStill else { return }
      withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { turning = true }
    }
    .accessibilityHidden(true)
  }
}

public struct ProgressBar: View {
  let progress: Permille
  let label: String?
  let count: String?
  let onHue: Bool

  public init(_ progress: Permille, label: String? = nil, count: String? = nil, onHue: Bool = false) {
    self.progress = progress
    self.label = label
    self.count = count
    self.onHue = onHue
  }

  public var body: some View {
    VStack(spacing: 8) {
      if label != nil || count != nil {
        ReflowingRow {
          if let label { Text(label).hType(.subheadline.weight(.semibold)).foregroundStyle(HColor.textPrimary) }
        } trailing: {
          if let count { Text(count).hFigure(HFigure.badge.weight(.semibold)).foregroundStyle(HColor.textSecondary) }
        }
      }
      SlimProgressBar(progress, fill: HColor.feedbackProgressIndicator,
                      track: onHue ? HColor.progressTrackOnHue : HColor.feedbackProgressTrack)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(label ?? "Progress")
    .accessibilityValue(count ?? "\(progress.value / 10) percent")
  }
}

public struct StepIndicator: View {
  let current: Int
  let total: Int

  public init(current: Int, of total: Int) {
    self.current = current
    self.total = total
  }

  public static func caption(current: Int, total: Int) -> String {
    "Step \(current) of \(total)"
  }

  public var body: some View {
    HStack(spacing: 8) {
      HStack(spacing: 6) {
        ForEach(1...max(1, total), id: \.self) { step in
          RoundedRectangle(cornerRadius: 2)
            .fill(step <= current ? HColor.actionAccent : HColor.appleFillsSecondary)
            .frame(width: 24, height: 4)
        }
      }
      .hAnimation(.thumbSlide, value: current)
      Text(Self.caption(current: current, total: total))
        .hType(.footnote.weight(.semibold))
        .foregroundStyle(HColor.textOnWashSecondary)
        .lineLimit(1)
        .fixedSize()
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }
    .frame(minWidth: 44, minHeight: 44)
    .contentShape(Rectangle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Self.caption(current: current, total: total))
  }
}

public struct StoryProgress: View {
  let count: Int
  let current: Int
  let fill: Double

  public init(count: Int, current: Int, fill: Double) {
    self.count = count
    self.current = current
    self.fill = fill
  }

  public var body: some View {
    HStack(spacing: 4) {
      ForEach(0..<max(1, count), id: \.self) { index in
        GeometryReader { geo in
          ZStack(alignment: .leading) {
            Capsule().fill(HColor.progressTrackOnHue)
            if index < current {
              Capsule().fill(HColor.textPrimary)
            } else if index == current {
              Capsule().fill(HColor.textPrimary).frame(width: geo.size.width * min(1, max(0, fill)))
            }
          }
        }
        .frame(height: 3)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Story \(current + 1) of \(count)")
  }
}

public struct BackgroundWorkPill: View {
  let label: String
  let count: String?
  let busy: Bool

  public init(label: String, count: String? = nil, busy: Bool = true) {
    self.label = label
    self.count = count
    self.busy = busy
  }

  @Environment(\.dynamicTypeSize) private var typeSize

  public var body: some View {
    let large = typeSize.isAccessibilitySize
    HStack(spacing: 8) {
      if busy {
        Spinner(size: 16)
      } else {
        Circle().fill(HColor.iconTertiary).frame(width: 8, height: 8)
      }
      if large {
        VStack(alignment: .leading, spacing: 2) {
          labelText.lineLimit(2)
          countText.lineLimit(1)
        }
        .fixedSize(horizontal: false, vertical: true)
      } else {
        labelText
        countText
      }
    }
    .padding(.leading, 10)
    .padding(.trailing, 14)
    .padding(.vertical, large ? 8 : 0)
    .frame(minHeight: 36)
    .background(HColor.surfacePrimary, in: large ? AnyShape(RoundedRectangle(cornerRadius: 18, style: .continuous)) : AnyShape(Capsule()))
    .shadow(color: HColor.elevationNear, radius: 1, x: 0, y: 1)
    .shadow(color: Color(HRGBA(30, 42, 94, 0.08)), radius: 8, x: 0, y: 6)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel([label, count].compactMap { $0 }.joined(separator: ", "))
  }

  private var labelText: some View {
    Text(label).hType(.footnote.weight(.semibold)).foregroundStyle(HColor.textPrimary)
  }

  @ViewBuilder private var countText: some View {
    if let count {
      Text(count).hFigure(HFigure.badge.weight(.semibold)).foregroundStyle(HColor.textSecondary)
    }
  }
}

public struct InlineStatus: View {
  public enum Tone: Sendable, Hashable {
    case success, warning, error, accent, neutral
    case pace(Verdict)
  }

  public enum Size: Sendable { case small, regular }

  let tone: Tone
  let text: String
  let context: String?
  let size: Size
  let fieldError: Bool

  public init(tone: Tone, text: String, context: String? = nil, size: Size = .small, fieldError: Bool = false) {
    self.tone = tone
    self.text = text
    self.context = context
    self.size = size
    self.fieldError = fieldError
  }

  @ScaledMetric(relativeTo: .subheadline) private var regularLane: CGFloat = 20
  @ScaledMetric(relativeTo: .footnote) private var smallLane: CGFloat = 18

  public var body: some View {
    HStack(alignment: .top, spacing: fieldError ? 8 : 6) {
      Circle().fill(dot).frame(width: 7, height: 7)
        .frame(height: size == .regular || fieldError ? regularLane : smallLane)
      Text("\(Text(text).font(wordType.font).foregroundStyle(words))\(Text(verbatim: context.map { " · " + $0 } ?? ""))")
        .hType(size == .regular || fieldError ? .subheadline : .footnote)
        .foregroundStyle(HColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel([text, context].compactMap { $0 }.joined(separator: ", "))
  }

  private var wordType: HType {
    let base = size == .regular || fieldError ? HType.subheadline : HType.footnote
    return base.weight(fieldError ? .medium : .semibold)
  }

  private var dot: Color {
    switch tone {
    case .pace(let v): v == .overPace ? HColor.paceFillOverPace : v.foreground
    case .neutral: HColor.neutral300
    default: words
    }
  }

  private var words: Color {
    switch tone {
    case .success: HColor.statusSuccessForeground
    case .warning: HColor.statusWarningForeground
    case .error: HColor.statusErrorForeground
    case .accent: HColor.actionAccent
    case .neutral: HColor.textSecondary
    case .pace(let v): v.foreground
    }
  }
}

public struct StatusHero: View {
  let title: String
  let message: String
  let hue: Hue
  let icon: HIcon
  let action: (title: String, run: () -> Void)?

  public init(title: String, body: String, hue: Hue, icon: HIcon, action: (title: String, run: () -> Void)? = nil) {
    self.title = title
    self.message = body
    self.hue = hue
    self.icon = icon
    self.action = action
  }

  @Environment(\.dynamicTypeSize) private var typeSize

  public var body: some View {
    let layout = typeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
      : AnyLayout(HStackLayout(alignment: .center, spacing: 16))
    VStack(alignment: .leading, spacing: 16) {
      layout {
        Circle().fill(HColor.posterGlyph).frame(width: 56, height: 56)
          .overlay { HIconView(icon, size: 26, color: hue.ink) }
        VStack(alignment: .leading, spacing: 2) {
          Text(title).hType(.title1).foregroundStyle(hue.ink).accessibilityAddTraits(.isHeader)
          Text(message).hType(.subheadline).foregroundStyle(HColor.textOnHueSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      if let action {
        Button(action.title, action: action.run).buttonStyle(.pill(.onGrouped, size: .medium, fill: true))
      }
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(hue.perceptualGradient, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
    .accessibilityElement(children: .combine)
  }
}

public struct ResultCard: View {
  public enum Tone: Sendable { case success, warning, error }

  let tone: Tone
  let title: String
  let detail: String?
  let action: (title: String, run: () -> Void)?

  public init(tone: Tone, title: String, detail: String? = nil, action: (title: String, run: () -> Void)? = nil) {
    self.tone = tone
    self.title = title
    self.detail = detail
    self.action = action
  }

  @ScaledMetric(relativeTo: .headline) private var lane: CGFloat = 24

  public var body: some View {
    VStack(alignment: .leading, spacing: action == nil ? 4 : 12) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .top, spacing: 8) {
          Circle().fill(dot).frame(width: 8, height: 8).frame(height: lane)
          Text(title).hType(.headline).foregroundStyle(HColor.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
        }
        if let detail {
          Text(detail).hType(.subheadline).foregroundStyle(foreground)
            .padding(.leading, 16)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .accessibilityElement(children: .combine)
      if let action {
        Button(action.title, action: action.run).buttonStyle(.pill(.primary, size: .medium))
          .padding(.leading, 16)
      }
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(surface, in: RoundedRectangle(cornerRadius: HRadius.tile, style: .continuous))
  }

  private var dot: Color {
    switch tone {
    case .success: HColor.statusSuccessForeground
    case .warning: HColor.paceFillOverPace
    case .error: HColor.statusErrorForeground
    }
  }

  private var foreground: Color {
    switch tone {
    case .success: HColor.statusSuccessForeground
    case .warning: HColor.statusWarningForeground
    case .error: HColor.statusErrorForeground
    }
  }

  private var surface: Color {
    switch tone {
    case .success: HColor.statusSuccessSurface
    case .warning: HColor.statusWarningSurface
    case .error: HColor.statusErrorSurface
    }
  }
}

public struct SuccessBadge: View {
  public enum Content: Sendable, Hashable {
    case check
    case coin
    case ring(Double)
  }

  let content: Content
  @ResolvedMotion private var motion: MotionPolicy
  @State private var landed = false

  public init(content: Content) {
    self.content = content
  }

  public var body: some View {
    ZStack {
      RadialGradient(colors: [HColor.white.opacity(0.9), HColor.white.opacity(0)], center: .center,
                     startRadius: 0, endRadius: 42)
        .frame(width: 120, height: 120)
      sparks
      centre
        .scaleEffect(landed || motion.isStill ? 1 : HMotion.chipPopScale)
        .opacity(landed || motion.isStill ? 1 : 0)
    }
    .frame(width: 200, height: 96)
    .onAppear {
      withAnimation(motion.animation(.celebrate)) { landed = true }
    }
    .accessibilityHidden(true)
  }

  private var sparks: some View {
    ZStack(alignment: .topLeading) {
      spark(HPalette.hueSkyEnd, 8, x: 30, y: 22)
      spark(HPalette.hueSandEnd, 6, x: 52, y: 70)
      spark(HPalette.hueLilacEnd, 7, x: 156, y: 14)
      spark(HPalette.hueMintEnd, 9, x: 164, y: 62)
    }
    .frame(width: 200, height: 96, alignment: .topLeading)
  }

  private func spark(_ color: HRGBA, _ size: CGFloat, x: CGFloat, y: CGFloat) -> some View {
    Circle().fill(Color(color)).frame(width: size, height: size).offset(x: x, y: y)
  }

  @ViewBuilder private var centre: some View {
    switch content {
    case .check:
      Circle().fill(Hue.mint.perceptualGradient).frame(width: 72, height: 72)
        .overlay { Circle().stroke(HColor.white, lineWidth: 1).blendMode(.overlay) }
        .shadow(color: Color(HRGBA(22, 74, 53, 0.10)), radius: 1, x: 0, y: 1)
        .shadow(color: Color(HRGBA(22, 74, 53, 0.16)), radius: 14, x: 0, y: 12)
        .overlay { HIconView(.check, size: 36, color: Hue.mint.ink) }
    case .coin:
      HasalaMark()
        .frame(width: 160, height: 96)
        .shadow(color: Color(HRGBA(20, 38, 89, 0.22)), radius: 8, x: 0, y: 12)
    case .ring(let progress):
      ZStack {
        Circle().stroke(HColor.progressRingTrack, lineWidth: 5).frame(width: 80, height: 80)
        Circle().trim(from: 0, to: min(1, max(0, progress)))
          .stroke(HColor.actionAccent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
          .rotationEffect(.degrees(-90))
          .frame(width: 80, height: 80)
        Circle().fill(Hue.sky.perceptualGradient).frame(width: 68, height: 68)
          .overlay { HIconView(.lock, size: 30, color: Hue.sky.ink, strokeWidth: 1.8) }
      }
      .frame(width: 88, height: 88)
    }
  }
}

public struct EmptyStateCard: View {
  public enum Tone: Sendable {
    case success
    case neutral
  }

  let icon: HIcon
  let tone: Tone
  let title: String
  let message: String
  let action: (title: String, run: () -> Void)?

  public init(icon: HIcon = .check, tone: Tone = .success, title: String, message: String,
              action: (title: String, run: () -> Void)? = nil)
  {
    self.icon = icon
    self.tone = tone
    self.title = title
    self.message = message
    self.action = action
  }

  public var body: some View {
    VStack(spacing: 12) {
      Circle()
        .fill(tone == .success ? HColor.statusSuccessSurface : HColor.surfacePrimary)
        .frame(width: 56, height: 56)
        .overlay {
          HIconView(icon, size: 26, color: tone == .success ? HColor.statusSuccessForeground : HColor.iconSecondary,
                    strokeWidth: tone == .success ? 2.2 : nil)
        }
        .accessibilityHidden(true)
      VStack(spacing: 4) {
        Text(title)
          .hType(HType(size: HFontSize.title3, leading: 25, weight: .semibold, tracking: HTracking.title3,
                       textStyle: .title3))
          .foregroundStyle(HColor.textPrimary)
          .accessibilityAddTraits(.isHeader)
        Text(message).hType(.subheadline).foregroundStyle(HColor.textSecondary)
      }
      .multilineTextAlignment(.center)
      .accessibilityElement(children: .combine)
      if let action {
        Button(action.title, action: action.run).buttonStyle(.pill(.secondary, size: .medium))
      }
    }
    .padding(.top, 28)
    .padding(.bottom, 8)
    .padding(.horizontal, 24)
    .frame(maxWidth: .infinity)
  }
}
