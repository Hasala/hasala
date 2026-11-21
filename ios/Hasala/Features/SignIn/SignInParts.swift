import HasalaDesign
import HasalaModels
import SwiftUI
import UIKit

struct HeroDisc: View {
  var icon: HIcon
  var hue: Hue
  var shadow = true

  var body: some View {
    Circle()
      .fill(hue.perceptualGradient)
      .frame(width: 64, height: 64)
      .overlay { HIconView(icon, size: 30, color: hue.ink, strokeWidth: icon == .password ? 1.7 : 1.8) }
      .background { Circle().fill(HColor.white).padding(-4) }
      .shadow(color: shadow ? HColor.elevationFar : .clear, radius: 12, x: 0, y: 8)
      .accessibilityHidden(true)
  }
}

struct HeroAccountScreen<Content: View, Footer: View>: View {
  var hero: HeroDisc
  var title: String
  var subtitle: String?
  var email: EmailAside?
  var back: AccountBack = .none
  @ViewBuilder var content: () -> Content
  @ViewBuilder var footer: () -> Footer

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        hero
          .padding(.bottom, 16)
        VStack(alignment: .leading, spacing: 8) {
          Text(title)
            .hType(.title1)
            .foregroundStyle(HColor.textPrimary)
            .accessibilityAddTraits(.isHeader)
          if subtitle != nil || email != nil {
            SubtitleProse(text: subtitle, email: email)
          }
        }
        .fixedSize(horizontal: false, vertical: true)
        content()
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, 24)
      }
      .padding(.horizontal, HSpacing.insetPage)
      .padding(.top, hasHeader ? 16 : 40)
      .padding(.bottom, 16)
    }
    .scrollBounceBehavior(.basedOnSize)
    .dockScrollEdge()
    .contentMargins(.bottom, accountDockClearance, for: .scrollContent)
    .safeAreaBar(edge: .bottom) {
      AccountDock(content: footer)
    }
    .background(alignment: .top) {
      AmbientWash(.setup).ignoresSafeArea(edges: .top)
    }
    .background(HColor.surfaceSecondary)
    .accountHeader(back: back)
  }

  private var hasHeader: Bool {
    if case .none = back { return false }
    return true
  }
}

struct AccountDock<Content: View>: View {
  @ViewBuilder var content: () -> Content

  var body: some View {
    VStack(spacing: 4) { content() }
      .frame(maxWidth: .infinity)
      .padding(.horizontal, HSpacing.insetPage)
      .padding(.top, 8)
      .environment(\.pillDisabledBase, HColor.surfaceSecondary)
  }
}

extension View {
  func accountContentTop(_ top: CGFloat) -> some View {
    padding(.top, top - accountTemplateContentTop)
  }
}

private let accountTemplateContentTop: CGFloat = 24

struct OrDivider: View {
  var label: String
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    Group {
      if typeSize.isAccessibilitySize {
        text
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity)
      } else {
        HStack(spacing: 12) {
          rule
          text.fixedSize()
          rule
        }
      }
    }
    .padding(.vertical, 8)
  }

  private var rule: some View {
    Rectangle().fill(HColor.appleSeparatorsNonOpaque).frame(height: 1).accessibilityHidden(true)
  }

  private var text: some View {
    Text(label)
      .hType(.footnote.weight(.semibold))
      .foregroundStyle(HColor.textSecondary)
      .accessibilityIdentifier("orDivider.label")
  }
}

struct StatusListRow: Identifiable {
  enum State { case done, active, pending }

  var title: String
  var value: String
  var state: State
  var id: String { title }
}

struct StatusListCard: View {
  var rows: [StatusListRow]

  @ScaledMetric(relativeTo: .callout) private var lane: CGFloat = 22

  var body: some View {
    HListCard {
      ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
        if i > 0 { HDivider(inset: .lane35) }
        HStack(alignment: .top, spacing: 12) {
          Circle().fill(dot(row.state)).frame(width: 7, height: 7).frame(height: lane)
          ReflowingRow {
            Text(row.title)
              .hType(.rowTitle)
              .foregroundStyle(row.state == .pending ? HColor.textSecondary : HColor.textPrimary)
          } trailing: {
            Text(row.value).hType(.subheadline).foregroundStyle(HColor.textSecondary)
          }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .frame(minHeight: 52)
        .accessibilityElement(children: .combine)
      }
    }
  }

  private func dot(_ state: StatusListRow.State) -> Color {
    switch state {
    case .done: HColor.statusSuccessForeground
    case .active: HColor.actionAccent
    case .pending: HColor.neutral300
    }
  }
}

struct BulletCard: View {
  var lines: [String]

  @ScaledMetric(relativeTo: .subheadline) private var lane: CGFloat = 20

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(lines, id: \.self) { line in
        HStack(alignment: .top, spacing: 10) {
          Circle().fill(HColor.textSecondary).frame(width: 7, height: 7).frame(height: lane)
          Text(line)
            .hType(.subheadline)
            .foregroundStyle(HColor.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.tile, style: .continuous))
    .accessibilityElement(children: .combine)
  }
}

struct NeedRow: View {
  var icon: HIcon
  var hue: Hue
  var title: String
  var detail: String

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
    .accessibilityElement(children: .combine)
  }
}

struct NeedsCard<Content: View>: View {
  @ViewBuilder var content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: 16) { content() }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.card, style: .continuous))
  }
}

struct WarningNote: View {
  var text: String

  @ScaledMetric(relativeTo: .footnote) private var lane: CGFloat = 18

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      HIconView(.lock, size: 18, color: HColor.statusErrorForeground).frame(height: lane)
      Text(text)
        .hType(.footnote.weight(.medium))
        .foregroundStyle(HColor.statusErrorForeground)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, 12)
    .padding(.horizontal, 14)
    .background(HColor.statusErrorSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .accessibilityElement(children: .combine)
  }
}

struct CardNote: View {
  var icon: HIcon
  var text: String

  @ScaledMetric(relativeTo: .subheadline) private var lane: CGFloat = 20

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      HIconView(icon, size: 22, color: HColor.iconPrimary, strokeWidth: 1.8).frame(height: lane)
      Text(text)
        .hType(.subheadline)
        .foregroundStyle(HColor.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(16)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: HRadius.tile, style: .continuous))
    .accessibilityElement(children: .combine)
  }
}

struct ResendRow: View {
  var sentAt: Date?
  var wait: TimeInterval = 60
  var busy = false
  var trailing: (title: String, identifier: String, action: () -> Void)?
  var onResend: () -> Void

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      let left = sentAt.map { max(0, wait - context.date.timeIntervalSince($0)) } ?? 0
      ReflowingRow {
        if left > 0 {
          Text("Resend code in \(Self.clock(left))")
            .hType(.subheadline)
            .foregroundStyle(HColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: 44)
            .accessibilityIdentifier("code.resendWait")
        } else {
          InlineTextButton(title: "Resend code", identifier: "code.resend", action: onResend)
            .disabled(busy)
        }
      } trailing: {
        if let trailing {
          InlineTextButton(title: trailing.title, identifier: trailing.identifier, action: trailing.action)
        }
      }
    }
  }

  static func clock(_ seconds: TimeInterval) -> String {
    let s = Int(seconds.rounded(.up))
    return "\(s / 60):" + String(format: "%02d", s % 60)
  }
}

struct CodeStepScreen: View {
  var title: String
  var subtitle: String
  var steps: (current: Int, of: Int)?
  @Binding var code: String
  var busy: Bool
  var failure: AuthFailure?
  var sentAt: Date?
  var expired: (Date) -> Bool
  var trailing: (title: String, identifier: String, action: () -> Void)?
  var onSubmit: () -> Void
  var onResend: () -> Void

  @State private var now = Date.now

  private static let revealID = "code.step.reveal"

  static func cellState(failure: AuthFailure?, code: String, expired: Bool) -> CodeCells.State {
    if expired { return .expired }
    switch failure {
    case .codeExpired: return .expired
    case .codeWrong: return code.count == 6 ? .wrong : .typing
    default: return .typing
    }
  }

  static func line(failure: AuthFailure?, state: CodeCells.State) -> AuthFailure? {
    guard state == .expired else { return failure }
    if case .codeWrong = failure { return .codeExpired }
    return failure ?? .codeExpired
  }

  var body: some View {
    let state = Self.cellState(failure: failure, code: code, expired: expired(now))
    let shown = Self.line(failure: failure, state: state)
    AccountScreen(title: title, subtitle: subtitle, steps: steps, back: .system) {
      VStack(alignment: .leading, spacing: 12) {
        VStack(alignment: .leading, spacing: 12) {
          CodeCells(code: $code, state: state, revealTarget: Self.revealID)
            .onChange(of: code) { _, new in
              if new.count == 6, !busy { onSubmit() }
            }
          if let message = shown?.message {
            FieldErrorLine(text: message, warning: shown == .codeExpired)
              .accessibilityIdentifier("code.failure")
          }
        }
        .id(Self.revealID)
        if state != .expired {
          ResendRow(sentAt: sentAt, busy: busy, trailing: trailing, onResend: onResend)
        }
        HintCard(text: "Not there? Check Spam or Promotions for no-reply@hasala.app.")
      }
    } footer: {
      if state == .expired {
        BusyButton(title: "Send a new code", busy: busy, identifier: "code.resendNew", action: onResend)
      }
    }
    .task(id: sentAt) {
      guard let sentAt else { return }
      let left = sentAt.addingTimeInterval(EmailCode.lifetime + 1).timeIntervalSinceNow
      if left > 0 { try? await Task.sleep(for: .seconds(left)) }
      if !Task.isCancelled { now = .now }
    }
  }
}

struct UnlockingBadge: View {
  @StageMotion private var motion: MotionPolicy

  var body: some View {
    let still = motion.isStill
    ZStack {
      RadialGradient(colors: [HColor.white.opacity(0.9), HColor.white.opacity(0)], center: .center,
                     startRadius: 0, endRadius: 42)
        .frame(width: 120, height: 120)
      sparks
      ZStack {
        Circle().stroke(HColor.progressRingTrack, lineWidth: 5).frame(width: 80, height: 80)
        TimelineView(.animation(paused: still)) { context in
          let turn = still ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2
          Circle().trim(from: 0, to: 0.64)
            .stroke(HColor.actionAccent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
            .rotationEffect(.degrees(-90 + turn * 360))
            .frame(width: 80, height: 80)
        }
        Circle().fill(Hue.sky.perceptualGradient).frame(width: 68, height: 68)
          .overlay { Circle().stroke(HColor.white, lineWidth: 1).blendMode(.overlay) }
          .overlay { OpenPadlock().stroke(Hue.sky.ink, style: StrokeStyle(lineWidth: 1.8 * 30 / 24, lineCap: .round, lineJoin: .round)).frame(width: 30, height: 30) }
      }
      .frame(width: 88, height: 88)
    }
    .frame(width: 200, height: 96)
    .accessibilityHidden(true)
  }

  private var sparks: some View {
    ZStack(alignment: .topLeading) {
      spark(Hue.sky, 8, x: 30, y: 22)
      spark(Hue.sand, 6, x: 52, y: 70)
      spark(Hue.lilac, 7, x: 156, y: 14)
      spark(Hue.mint, 9, x: 164, y: 62)
    }
    .frame(width: 200, height: 96, alignment: .topLeading)
  }

  private func spark(_ hue: Hue, _ size: CGFloat, x: CGFloat, y: CGFloat) -> some View {
    Circle().fill(hue.end).frame(width: size, height: size).offset(x: x, y: y)
  }
}

private nonisolated struct OpenPadlock: Shape {
  func path(in rect: CGRect) -> Path {
    var p = Path()
    p.addRoundedRect(in: CGRect(x: 5, y: 10.5, width: 14, height: 10), cornerSize: CGSize(width: 2.5, height: 2.5))
    p.move(to: CGPoint(x: 8.5, y: 10.5))
    p.addLine(to: CGPoint(x: 8.5, y: 8))
    p.addArc(center: CGPoint(x: 12, y: 8), radius: 3.5, startAngle: .degrees(180), endAngle: .degrees(-20),
             clockwise: false)
    return p.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24))
  }
}

struct ProgressCelebrationScreen<Cards: View, Foot: View>: View {
  var title: String
  var subtitle: String
  @ViewBuilder var cards: () -> Cards
  @ViewBuilder var foot: () -> Foot

  var body: some View {
    ScrollView {
      VStack(spacing: 0) {
        VStack(spacing: 20) {
          UnlockingBadge()
          VStack(spacing: 8) {
            Text(title)
              .hType(.largeTitle)
              .foregroundStyle(HColor.textPrimary)
              .accessibilityAddTraits(.isHeader)
            Text(subtitle)
              .hType(.body)
              .foregroundStyle(HColor.textOnWashSecondary)
              .frame(maxWidth: 300)
          }
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.top, 76)
        cards()
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, HSpacing.insetPage)
          .padding(.top, 36)
      }
      .padding(.bottom, 16)
    }
    .scrollBounceBehavior(.basedOnSize)
    .scrollEdgeEffectStyle(.soft, for: .bottom)
    .safeAreaBar(edge: .bottom) {
      foot()
        .padding(.horizontal, HSpacing.insetPage)
        .padding(.bottom, 6)
    }
    .background(alignment: .top) {
      AmbientWash(.ready).ignoresSafeArea(edges: .top)
    }
    .background(HColor.surfaceSecondary)
    .navigationBarBackButtonHidden()
    .toolbar(.hidden, for: .navigationBar)
  }
}

@MainActor
func screenIsCaptured() -> Bool {
  #if DEBUG
    if ProcessInfo.processInfo.arguments.contains("-HasalaScreenCaptured") { return true }
  #endif
  return UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.contains { $0.screen.isCaptured }
}
