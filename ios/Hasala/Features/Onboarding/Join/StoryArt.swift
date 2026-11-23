import HasalaDesign
import HasalaModels
import SwiftUI

struct StoryRun: Equatable, Sendable {
  var id: Int
  var byUser: Bool
}

enum StoryTiming {
  static let count = 0.8
  static let fill = 0.8
  static let arrow = 0.35
  static let typing = 0.32
  static let connector = 0.35
  static let scramble = 0.4
  static let lean = 0.22
  static let leanHold = 0.18
  static let check = 0.25
}

struct StoryArt: View {
  let index: Int
  let run: StoryRun?
  let floating: Bool

  static let heights: [CGFloat] = [341, 341, 329, 405]
  static let orbitTop: [CGFloat] = [16, 16, 16, 40]

  var body: some View {
    Group {
      switch index {
      case 0: SpendStage(run: run, floating: floating)
      case 1: EmailStage(run: run, floating: floating)
      case 2: KeyStage(run: run, floating: floating)
      default: SortStage(run: run, floating: floating)
      }
    }
    .frame(width: 402, height: Self.heights[min(max(index, 0), 3)], alignment: .topLeading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Self.descriptions[min(max(index, 0), 3)])
    .accessibilityAddTraits(.isImage)
  }

  static let descriptions = [
    "A budget card: AED 8,711.66 left, on track. Rent counts when due.",
    "An Emirates NBD alert email becomes a Carrefour grocery transaction.",
    "The Carrefour transaction, sealed in Hasala's coin slot. Your key stays on your devices.",
    "A Lulu Hypermarket card, AED 214.30, to sort. Hasala suggests Groceries next time.",
  ]
}

enum ArtEntrance {
  case deal(from: CGSize, swing: Double)
  case pop
  case fade
}

struct ArtPiece: ViewModifier {
  let x: CGFloat
  let y: CGFloat
  let tilt: Double
  let shown: Bool
  let entrance: ArtEntrance
  let opacity: Double
  let motion: MotionPolicy

  func body(content: Content) -> some View {
    let travels = !shown && !motion.isStill
    var turn = 0.0
    var scale: CGFloat = 1
    var move = CGSize.zero
    if travels {
      switch entrance {
      case .deal(let from, let swing):
        turn = swing
        scale = HMotion.dealScale
        move = from
      case .pop:
        scale = HMotion.chipPopScale
      case .fade:
        break
      }
    }
    return content
      .rotationEffect(.degrees(tilt + turn), anchor: .topLeading)
      .scaleEffect(scale)
      .opacity(shown ? opacity : 0)
      .offset(x: x + move.width, y: y + move.height)
      .animation(animation, value: shown)
  }

  private var animation: Animation? {
    guard shown else { return nil }
    if motion.settled { return nil }
    if motion.reduceMotion { return HMotion.reduceMotionCurve.animation }
    switch entrance {
    case .deal: return HMotion.springDeal
    case .pop: return HMotion.bouncy
    case .fade: return HMotion.easeOutSoft(HMotion.fade)
    }
  }
}

struct IdleFloat: ViewModifier {
  let active: Bool
  let phase: Int

  func body(content: Content) -> some View {
    content.keyframeAnimator(initialValue: CGFloat.zero, repeating: active) { view, y in
      view.offset(y: active ? y : 0)
    } keyframes: { _ in
      Self.track(phase: phase)
    }
  }

  static func track(phase: Int) -> some Keyframes<CGFloat> {
    let quarter = HMotion.idlePeriod / 4
    let sign: CGFloat = phase.isMultiple(of: 2) ? -1 : 1
    return KeyframeTrack {
      CubicKeyframe(sign * HMotion.idleFloat, duration: quarter)
      CubicKeyframe(0, duration: quarter)
      CubicKeyframe(-sign * HMotion.idleFloat, duration: quarter)
      CubicKeyframe(0, duration: quarter)
    }
  }
}

extension View {
  func artPiece(
    _ x: CGFloat, _ y: CGFloat, tilt: Double = 0, shown: Bool, _ entrance: ArtEntrance, opacity: Double = 1,
    motion: MotionPolicy
  ) -> some View {
    modifier(ArtPiece(x: x, y: y, tilt: tilt, shown: shown, entrance: entrance, opacity: opacity, motion: motion))
  }

  func idleFloat(_ active: Bool, phase: Int) -> some View {
    modifier(IdleFloat(active: active, phase: phase))
  }
}

struct ArtText: View {
  let text: String
  let size: CGFloat
  let leading: CGFloat
  var weight: HWeight = .regular
  var color: Color = HColor.textPrimary
  var tracking: CGFloat = 0
  var mono = false
  var uppercase = false

  var body: some View {
    let extra = max(0, leading - size * (mono ? 1.32 : 1.21))
    Text(text)
      .font(mono ? .system(size: size, weight: weight.systemWeight, design: .monospaced) : .artInter(size, weight))
      .tracking(tracking)
      .textCase(uppercase ? .uppercase : nil)
      .foregroundStyle(color)
      .lineSpacing(extra)
      .padding(.vertical, extra / 2)
      .fixedSize(horizontal: false, vertical: true)
  }
}

struct ArtFigure: View {
  let text: String
  let size: CGFloat
  var weight: Font.Weight = .bold
  var tracking: CGFloat = 0
  var color: Color = HColor.moneyOut

  var body: some View {
    Text(text)
      .font(Font.artRounded(size, weight).monospacedDigit())
      .tracking(tracking)
      .foregroundStyle(color)
      .lineLimit(1)
      .fixedSize()
  }
}

@MainActor @propertyWrapper
struct StageMotion: DynamicProperty {
  @Environment(\.hMotion) private var policy
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

  init() {}

  var wrappedValue: MotionPolicy {
    MotionPolicy(reduceMotion: policy.reduceMotion || systemReduceMotion, settled: policy.settled)
  }
}

private struct StageClock {
  let start = ContinuousClock.now

  func at(_ t: Double) async -> Bool {
    try? await Task.sleep(until: start.advanced(by: .milliseconds(Int(t * 1000))), clock: .continuous)
    return !Task.isCancelled
  }
}

@MainActor
func instantly(_ body: () -> Void) {
  var t = Transaction()
  t.disablesAnimations = true
  withTransaction(t, body)
}

private struct SpendStage: View {
  let run: StoryRun?
  let floating: Bool
  @StageMotion private var motion: MotionPolicy

  @State private var hero = false
  @State private var counted = false
  @State private var filled = false
  @State private var marker = false
  @State private var verdict = false
  @State private var rent = false
  @State private var arrow = false
  @State private var chip = false
  @State private var landed = 0

  var body: some View {
    ZStack(alignment: .topLeading) {
      rentCard
        .frame(width: 236)
        .idleFloat(floating && rent, phase: 1)
        .artPiece(146, 32, tilt: 7, shown: rent, .deal(from: CGSize(width: 60, height: 0), swing: 10), opacity: 0.85,
                  motion: motion)
      ArtText(text: "Rent counted on its due date", size: 13, leading: 18, weight: .semibold, color: HColor.hueSkyInk)
        .frame(width: 112, alignment: .leading)
        .artPiece(24, 40, shown: arrow, .fade, motion: motion)
      CaptionArrow()
        .trim(from: 0, to: arrow ? 1 : 0)
        .stroke(HColor.hueSkyInk, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        .frame(width: 64, height: 40)
        .offset(x: 80, y: 70)
      heroCard
        .frame(width: 330)
        .idleFloat(floating && hero, phase: 0)
        .artPiece(36, 128, tilt: -2, shown: hero, .deal(from: CGSize(width: 0, height: HMotion.travelDeal), swing: -10),
                  motion: motion)
      privacyChip
        .frame(width: 402)
        .artPiece(0, 282, shown: chip, .pop, motion: motion)
    }
    .hHaptic(.impactLight, trigger: landed)
    .task(id: run) { await play() }
  }

  private var rentCard: some View {
    HStack(spacing: 12) {
      ArtDisc(hue: .sand, icon: .rent, size: 40, iconSize: 20)
      VStack(alignment: .leading, spacing: 2) {
        ArtText(text: "Rent", size: 16, leading: 22, weight: .semibold)
        ArtText(text: "Paid 1 Oct", size: 13, leading: 18, color: HColor.textOnWashSecondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      ArtFigure(text: "7,500.00", size: 16)
    }
    .padding(.vertical, 12)
    .padding(.leading, 14)
    .padding(.trailing, 16)
    .background(HColor.surfaceOnWash, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .strokeBorder(HColor.hueSkyInk.opacity(0.3), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
    }
  }

  private var heroCard: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          ArtFigure(text: "AED", size: 17, weight: .semibold, color: HColor.textPrimary)
          ArtFigure(text: counted ? "10,288.34" : "0.00", size: 44, tracking: -0.8, color: HColor.textPrimary)
            .contentTransition(motion.isStill ? .identity : .numericText(value: counted ? 10288.34 : 0))
        }
        ArtText(text: "spent of 19,000 on needs and wants", size: 15, leading: 20, color: HColor.textSecondary)
      }
      VStack(alignment: .leading, spacing: 10) {
        ZStack(alignment: .topLeading) {
          RoundedRectangle(cornerRadius: 4).fill(HColor.paceTrack).frame(width: 290, height: 8).offset(y: 4)
          RoundedRectangle(cornerRadius: 4).fill(HColor.paceFill).frame(width: filled ? 157 : 0, height: 8).offset(y: 4)
          RoundedRectangle(cornerRadius: 1)
            .fill(HColor.paceMarker)
            .frame(width: 2, height: 16)
            .background(RoundedRectangle(cornerRadius: 2).fill(HColor.surfacePrimary).padding(-1.5))
            .offset(x: 171, y: marker || motion.isStill ? 0 : -HMotion.markerDrop)
            .opacity(marker ? 1 : 0)
        }
        .frame(width: 290, height: 16, alignment: .topLeading)
        HStack(spacing: 6) {
          Circle().fill(HColor.paceOnTrack).frame(width: 8, height: 8)
          ArtText(text: "On track", size: 15, leading: 20, weight: .semibold, color: HColor.paceOnTrack)
          ArtText(text: "· AED 8,711.66 left", size: 15, leading: 20, color: HColor.textSecondary)
        }
        .opacity(verdict ? 1 : 0)
      }
    }
    .padding(20)
    .frame(maxWidth: .infinity, alignment: .leading)
    .artCard(RoundedRectangle(cornerRadius: HRadius.card, style: .continuous), shadow: .hero)
  }

  private var privacyChip: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(HColor.statusSuccessSurface)
        .frame(width: 20, height: 20)
        .overlay { HIconView(.lock, size: 12, color: HColor.statusSuccessForeground, strokeWidth: 2.4) }
      ArtText(text: "Only your devices can read this", size: 13, leading: 18, weight: .semibold)
    }
    .padding(.leading, 8)
    .padding(.trailing, 14)
    .frame(height: 32)
    .artCard(Capsule(), shadow: .chip)
  }

  private func play() async {
    instantly {
      hero = false
      counted = false
      filled = false
      marker = false
      verdict = false
      rent = false
      arrow = false
      chip = false
    }
    guard let run else { return }
    let m = motion
    if m.settled {
      instantly { hero = true; counted = true; filled = true; marker = true; verdict = true; rent = true; arrow = true; chip = true }
      return
    }
    let clock = StageClock()
    hero = true
    withAnimation(m.reduceMotion ? nil : HMotion.easeInOut(StoryTiming.count)) { counted = true }
    guard await clock.at(0.5) else { return }
    withAnimation(m.reduceMotion ? nil : HMotion.easeInOut(StoryTiming.fill)) { filled = true }
    guard await clock.at(0.6) else { return }
    rent = true
    guard await clock.at(0.75) else { return }
    withAnimation(m.reduceMotion ? HMotion.reduceMotionCurve.animation : HMotion.easeOutSoft(StoryTiming.arrow)) {
      arrow = true
    }
    guard await clock.at(StoryTiming.count) else { return }
    if run.byUser { landed += 1 }
    guard await clock.at(0.9) else { return }
    chip = true
    guard await clock.at(0.5 + StoryTiming.fill) else { return }
    withAnimation(m.reduceMotion ? nil : HMotion.easeOutSoft(HMotion.marker)) { marker = true }
    guard await clock.at(0.5 + StoryTiming.fill + HMotion.marker) else { return }
    withAnimation(m.reduceMotion ? nil : HMotion.easeOutSoft(HMotion.verdict)) { verdict = true }
  }
}

private nonisolated struct CaptionArrow: Shape {
  func path(in rect: CGRect) -> Path {
    let sx = rect.width / 64, sy = rect.height / 40
    var p = Path()
    p.move(to: CGPoint(x: 4 * sx, y: 10 * sy))
    p.addCurve(to: CGPoint(x: 58 * sx, y: 22 * sy), control1: CGPoint(x: 12 * sx, y: 28 * sy),
               control2: CGPoint(x: 38 * sx, y: 32 * sy))
    p.move(to: CGPoint(x: 51 * sx, y: 18.5 * sy))
    p.addLine(to: CGPoint(x: 58.5 * sx, y: 21.8 * sy))
    p.addLine(to: CGPoint(x: 54.2 * sx, y: 28.6 * sy))
    return p
  }
}

private struct EmailStage: View {
  let run: StoryRun?
  let floating: Bool
  @StageMotion private var motion: MotionPolicy

  static let alert = "AED 342.15 at CARREFOUR MALL OF EMIRATES"

  @State private var email = false
  @State private var typed = 0
  @State private var connector = false
  @State private var source = false
  @State private var pulse = false
  @State private var row = false
  @State private var discs = 0
  @State private var landed = 0

  var body: some View {
    ZStack(alignment: .topLeading) {
      Connector(from: CGPoint(x: 116, y: 168), c1: CGPoint(x: 116, y: 200), c2: CGPoint(x: 240, y: 186),
                to: CGPoint(x: 240, y: 220))
        .trim(from: 0, to: connector ? 1 : 0)
        .stroke(HColor.blue400, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [0, 7]))
        .frame(width: 402, height: 341)
      emailCard
        .frame(width: 300)
        .idleFloat(floating && email, phase: 0)
        .artPiece(22, 38, tilt: -3, shown: email, .deal(from: CGSize(width: 0, height: -HMotion.travelDeal), swing: -10),
                  motion: motion)
      sourceChip
        .scaleEffect(pulse ? 1.06 : 1)
        .artPiece(110, 178, shown: source, .pop, motion: motion)
      carrefourCard
        .frame(width: 296)
        .idleFloat(floating && row, phase: 1)
        .artPiece(82, 222, tilt: 2, shown: row, .deal(from: CGSize(width: -10, height: -56), swing: -10), motion: motion)
      disc(.lilac, .dining, size: 52, icon: 24, index: 0)
        .artPiece(334, 84, tilt: 8, shown: discs > 0, .deal(from: Self.orbitFrom(334, 84, 52), swing: 10),
                  motion: motion)
      disc(.sand, .transport, size: 46, icon: 22, index: 1)
        .artPiece(18, 172, tilt: -10, shown: discs > 1, .deal(from: Self.orbitFrom(18, 172, 46), swing: -10),
                  motion: motion)
      disc(.mint, .savings, size: 40, icon: 20, index: 2)
        .artPiece(28, 268, tilt: 9, shown: discs > 2, .deal(from: Self.orbitFrom(28, 268, 40), swing: 10),
                  motion: motion)
    }
    .hHaptic(.impactLight, trigger: landed)
    .task(id: run) { await play() }
  }

  static func orbitFrom(_ x: CGFloat, _ y: CGFloat, _ size: CGFloat) -> CGSize {
    let c = CGPoint(x: 201, y: 180)
    let p = CGPoint(x: x + size / 2 - c.x, y: y + size / 2 - c.y)
    let a = -0.5
    let q = CGPoint(x: p.x * cos(a) - p.y * sin(a), y: p.x * sin(a) + p.y * cos(a))
    return CGSize(width: q.x - p.x, height: q.y - p.y)
  }

  private func disc(_ hue: Hue, _ icon: HIcon, size: CGFloat, icon iconSize: CGFloat, index: Int) -> some View {
    ArtDisc(hue: hue, icon: icon, size: size, iconSize: iconSize)
      .artCard(Circle(), fill: .clear, shadow: .float)
      .idleFloat(floating && discs > index, phase: index + 2)
  }

  private var emailCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(Hue.sky.perceptualGradient)
          .frame(width: 26, height: 26)
          .overlay { HIconView(.envelope, size: 16, color: HColor.hueSkyInk, strokeWidth: 2) }
        ArtText(text: "Emirates NBD · Transaction alert", size: 13, leading: 18, weight: .semibold)
      }
      ZStack(alignment: .topLeading) {
        ArtText(text: Self.alert, size: 12, leading: 17, color: .clear, mono: true)
        ArtText(text: String(Self.alert.prefix(typed)), size: 12, leading: 17, color: HColor.textSecondary, mono: true)
      }
      VStack(alignment: .leading, spacing: 6) {
        RoundedRectangle(cornerRadius: 3).fill(HColor.neutral100).frame(height: 6)
        RoundedRectangle(cornerRadius: 3).fill(HColor.neutral100).frame(width: 167, height: 6)
      }
    }
    .padding(.top, 14)
    .padding(.leading, 14)
    .padding(.trailing, 16)
    .padding(.bottom, 16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .artCard(RoundedRectangle(cornerRadius: 18, style: .continuous), shadow: .float)
  }

  private var sourceChip: some View {
    HStack(spacing: 7) {
      AppIconTile(size: 24, radius: 7)
      ArtText(text: "Read on this iPhone", size: 13, leading: 18, weight: .semibold)
    }
    .padding(.leading, 4)
    .padding(.trailing, 12)
    .frame(height: 32)
    .artCard(Capsule(), shadow: .chipLift)
  }

  private var carrefourCard: some View {
    HStack(spacing: 12) {
      ArtDisc(hue: .sand, icon: .groceries, size: 40, iconSize: 20)
      VStack(alignment: .leading, spacing: 2) {
        ArtText(text: "Carrefour", size: 16, leading: 22, weight: .semibold)
        ArtText(text: "Groceries · 19:12", size: 13, leading: 18, color: HColor.textSecondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      ArtFigure(text: "342.15", size: 16)
    }
    .padding(.horizontal, 16)
    .frame(minHeight: 64)
    .padding(.vertical, 4)
    .artCard(RoundedRectangle(cornerRadius: 20, style: .continuous), shadow: .hero)
  }

  private func play() async {
    instantly {
      email = false
      typed = 0
      connector = false
      source = false
      pulse = false
      row = false
      discs = 0
    }
    guard let run else { return }
    let m = motion
    if m.settled {
      instantly { email = true; typed = Self.alert.count; connector = true; source = true; row = true; discs = 3 }
      return
    }
    let clock = StageClock()
    email = true
    async let typing: Void = typeAlert(clock, all: m.reduceMotion)
    guard await clock.at(HMotion.stagger) else { return }
    source = true
    guard await clock.at(0.45) else { return }
    withAnimation(m.reduceMotion ? HMotion.reduceMotionCurve.animation : HMotion.easeOutSoft(StoryTiming.connector)) {
      connector = true
    }
    if !m.reduceMotion { withAnimation(HMotion.snappy) { pulse = true } }
    guard await clock.at(0.65) else { return }
    row = true
    guard await clock.at(0.45 + HMotion.snappyResponse) else { return }
    if !m.reduceMotion { withAnimation(HMotion.snappy) { pulse = false } }
    for i in 1...3 {
      guard await clock.at(0.65 + HMotion.stagger * Double(i)) else { return }
      discs = i
    }
    guard await clock.at(0.65 + HMotion.dealResponse * 0.8) else { return }
    if run.byUser { landed += 1 }
    await typing
  }

  private func typeAlert(_ clock: StageClock, all: Bool) async {
    let count = Self.alert.count
    if all {
      typed = count
      return
    }
    for i in 1...count {
      guard await clock.at(0.12 + StoryTiming.typing * Double(i) / Double(count)) else { return }
      typed = i
    }
  }
}

private nonisolated struct Connector: Shape {
  let from: CGPoint
  let c1: CGPoint
  let c2: CGPoint
  let to: CGPoint

  func path(in rect: CGRect) -> Path {
    var p = Path()
    p.move(to: from)
    p.addCurve(to: to, control1: c1, control2: c2)
    return p
  }
}

private struct KeyStage: View {
  let run: StoryRun?
  let floating: Bool
  @StageMotion private var motion: MotionPolicy

  static let sealed = "8f3a c91e 0b7d 52e4 a6f0"

  @State private var card = false
  @State private var connector = false
  @State private var tray = false
  @State private var coinIn = false
  @State private var badge = false
  @State private var shut = false
  @State private var pill = false
  @State private var hex = KeyStage.sealed
  @State private var key = false
  @State private var snapped = 0

  var body: some View {
    ZStack(alignment: .topLeading) {
      mini
        .frame(width: 232)
        .idleFloat(floating && card, phase: 0)
        .artPiece(22, 30, tilt: -4, shown: card, .deal(from: CGSize(width: 0, height: HMotion.travelDeal), swing: -10),
                  motion: motion)
      Connector(from: CGPoint(x: 146, y: 84), c1: CGPoint(x: 146, y: 110), c2: CGPoint(x: 201, y: 98),
                to: CGPoint(x: 201, y: 118))
        .trim(from: 0, to: connector ? 1 : 0)
        .stroke(HColor.blue400, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [0, 7]))
        .frame(width: 402, height: 329)
      SlotMark(plate: .onWash, coinShadow: true, drop: coinIn || motion.isStill ? 0 : 220)
        .frame(width: 240, height: 143 + 90)
        .opacity(tray ? 1 : 0)
        .offset(x: 81, y: 112 - 90)
      lockBadge
        .scaleEffect(badge || motion.isStill ? 1 : 0.6)
        .opacity(badge ? 1 : 0)
        .offset(x: 233, y: 116)
      keyChip
        .idleFloat(floating && key, phase: 1)
        .artPiece(238, 70, tilt: 6, shown: key, .deal(from: CGSize(width: 48, height: 0), swing: 10), motion: motion)
      cipher
        .frame(width: 402)
        .artPiece(0, 262, shown: pill, .deal(from: CGSize(width: 0, height: HMotion.travelRise), swing: 0),
                  motion: motion)
    }
    .hHaptic(.impactRigid, trigger: snapped)
    .task(id: run) { await play() }
  }

  private var mini: some View {
    HStack(spacing: 10) {
      ArtDisc(hue: .sand, icon: .groceries, size: 34, iconSize: 18)
      VStack(alignment: .leading, spacing: 0) {
        ArtText(text: "Carrefour", size: 15, leading: 20, weight: .semibold)
        ArtText(text: "Groceries · 19:12", size: 12, leading: 16, color: HColor.textSecondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      ArtFigure(text: "342.15", size: 15)
    }
    .padding(.vertical, 12)
    .padding(.leading, 12)
    .padding(.trailing, 14)
    .artCard(RoundedRectangle(cornerRadius: 18, style: .continuous), shadow: .float)
  }

  private var lockBadge: some View {
    Circle()
      .fill(HColor.surfacePrimary)
      .frame(width: 40, height: 40)
      .shadow(color: HColor.hueSkyInk.opacity(0.16), radius: 9, y: 8)
      .shadow(color: HColor.hueSkyInk.opacity(0.08), radius: 1, y: 1)
      .overlay { SealLock(shut: shut).frame(width: 20, height: 20) }
  }

  private var keyChip: some View {
    HStack(spacing: 7) {
      Circle()
        .fill(LinearGradient(colors: [SlotMark.coinLight, SlotMark.coinDeep], startPoint: .top, endPoint: .bottom))
        .frame(width: 24, height: 24)
        .overlay { HIconView(.key, size: 14, color: HColor.amber800, strokeWidth: 2.4) }
      VStack(alignment: .leading, spacing: 0) {
        ArtText(text: "Your key", size: 12, leading: 15, weight: .semibold)
        ArtText(text: "stays on your devices", size: 11, leading: 13, weight: .medium, color: HColor.textSecondary)
      }
    }
    .padding(.leading, 5)
    .padding(.trailing, 12)
    .frame(height: 34)
    .artCard(Capsule(), shadow: .float)
  }

  private var cipher: some View {
    VStack(spacing: 2) {
      ArtText(text: hex, size: 13, leading: 18, weight: .medium, color: Color.white.opacity(0.78), tracking: 0.26,
              mono: true)
      ArtText(text: "How our server stores it", size: 11, leading: 14, weight: .semibold, color: HColor.amber300,
              tracking: 0.66, uppercase: true)
    }
    .padding(.vertical, 9)
    .padding(.horizontal, 16)
    .background {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(HColor.ink900)
        .shadow(color: HColor.hueSkyInk.opacity(0.16), radius: 12, y: 10)
        .shadow(color: Color.black.opacity(0.04), radius: 1, y: 1)
    }
  }

  private func play() async {
    instantly {
      card = false
      connector = false
      tray = false
      coinIn = false
      badge = false
      shut = false
      pill = false
      hex = Self.sealed
      key = false
    }
    guard let run else { return }
    let m = motion
    if m.settled {
      instantly { card = true; connector = true; tray = true; coinIn = true; badge = true; shut = true; pill = true; key = true }
      return
    }
    let clock = StageClock()
    card = true
    withAnimation(m.reduceMotion ? HMotion.reduceMotionCurve.animation : HMotion.easeOutSoft(HMotion.fade)) {
      tray = true
    }
    withAnimation(m.reduceMotion ? nil : HMotion.springDrop) { coinIn = true }
    guard await clock.at(0.12) else { return }
    withAnimation(m.reduceMotion ? HMotion.reduceMotionCurve.animation : HMotion.easeOutSoft(StoryTiming.connector)) {
      connector = true
    }
    guard await clock.at(0.3) else { return }
    if !m.reduceMotion { hex = Self.scrambled(seed: 0) }
    pill = true
    guard await clock.at(0.35) else { return }
    withAnimation(m.reduceMotion ? HMotion.reduceMotionCurve.animation : HMotion.springDrop) { badge = true }
    async let scramble: Void = settleHex(clock, at: 0.35, all: m.reduceMotion)
    guard await clock.at(0.43) else { return }
    withAnimation(m.reduceMotion ? nil : HMotion.springDrop) { shut = true }
    guard await clock.at(0.5) else { return }
    if run.byUser { snapped += 1 }
    guard await clock.at(0.6) else { return }
    key = true
    await scramble
  }

  private func settleHex(_ clock: StageClock, at start: Double, all: Bool) async {
    if all {
      hex = Self.sealed
      return
    }
    let steps = 8
    for i in 1...steps {
      guard await clock.at(start + StoryTiming.scramble * Double(i) / Double(steps)) else { return }
      hex = i == steps ? Self.sealed : Self.scrambled(seed: i, settled: Self.sealed.count * i / steps)
    }
  }

  static func scrambled(seed: Int, settled: Int = 0) -> String {
    let digits = Array("0123456789abcdef")
    return String(sealed.enumerated().map { i, c in
      if c == " " || i < settled { return c }
      return digits[(i * 7 + seed * 11 + 3) % digits.count]
    })
  }
}

private struct SealLock: View {
  let shut: Bool

  var body: some View {
    Canvas { context, size in
      let s = size.width / 24
      let body = Path(roundedRect: CGRect(x: 5 * s, y: 10.5 * s, width: 14 * s, height: 10 * s), cornerRadius: 2.5 * s)
      context.fill(body, with: .color(HColor.blue950))
      var shackle = Path()
      let lift: CGFloat = shut ? 0 : 3.5
      shackle.move(to: CGPoint(x: 8.5 * s, y: (10.5 - lift) * s))
      shackle.addLine(to: CGPoint(x: 8.5 * s, y: (8 - lift) * s))
      shackle.addArc(center: CGPoint(x: 12 * s, y: (8 - lift) * s), radius: 3.5 * s, startAngle: .degrees(180),
                     endAngle: .degrees(0), clockwise: false)
      shackle.addLine(to: CGPoint(x: 15.5 * s, y: (10.5 - lift) * s))
      context.stroke(shackle, with: .color(HColor.blue950), style: StrokeStyle(lineWidth: 2.2 * s, lineCap: .round))
      context.fill(Path(ellipseIn: CGRect(x: (12 - 1.6) * s, y: (15.5 - 1.6) * s, width: 3.2 * s, height: 3.2 * s)),
                   with: .color(HColor.amber300))
    }
  }
}

private struct SortStage: View {
  let run: StoryRun?
  let floating: Bool
  @StageMotion private var motion: MotionPolicy

  @State private var ghost = false
  @State private var card = false
  @State private var chips = 0
  @State private var leaning = false
  @State private var rule = false
  @State private var ticked = false
  @State private var leaned = 0

  var body: some View {
    ZStack(alignment: .topLeading) {
      RoundedRectangle(cornerRadius: 24, style: .continuous)
        .fill(HColor.surfaceOnWash)
        .shadow(color: HColor.hueSkyInk.opacity(0.08), radius: 10, y: 8)
        .frame(width: 196, height: 150)
        .idleFloat(floating && ghost, phase: 1)
        .artPiece(103, 88, tilt: -5, shown: ghost, .deal(from: CGSize(width: 0, height: HMotion.travelDeal), swing: -10),
                  motion: motion)
      reviewCard
        .frame(width: 196)
        .rotationEffect(.degrees(leaning ? 6 : 0), anchor: .bottom)
        .offset(x: leaning ? 54 : 0)
        .idleFloat(floating && card && !leaning, phase: 0)
        .artPiece(103, 86, tilt: 5, shown: card, .deal(from: CGSize(width: 0, height: HMotion.travelDeal), swing: 10),
                  motion: motion)
      chip("↑ Transfer", hue: .other)
        .frame(width: 402)
        .artPiece(0, 38, shown: chips > 0, .pop, motion: motion)
      HStack {
        chip("← Want", hue: .lilac)
          .scaleEffect(chips > 1 || motion.isStill ? 1 : HMotion.chipPopScale)
          .opacity(chips > 1 ? 1 : 0)
          .animation(chipAnimation, value: chips > 1)
        Spacer()
        chip("Need →", hue: .sand, ring: true)
          .scaleEffect(leaning ? 1.06 : 1)
          .shadow(color: HColor.hueSandInk.opacity(leaning ? 0.28 : 0), radius: 10)
          .scaleEffect(chips > 2 || motion.isStill ? 1 : HMotion.chipPopScale)
          .opacity(chips > 2 ? 1 : 0)
          .animation(chipAnimation, value: chips > 2)
      }
      .padding(.horizontal, 14)
      .frame(width: 402)
      .offset(y: 145)
      chip("↓ Save", hue: .mint)
        .frame(width: 402)
        .artPiece(0, 252, shown: chips > 3, .pop, motion: motion)
      ruleChip
        .frame(width: 402)
        .artPiece(0, 304, shown: rule, .pop, motion: motion)
    }
    .hHaptic(.impactLight, trigger: leaned)
    .task(id: run) { await play() }
  }

  private var chipAnimation: Animation? {
    if motion.settled { return nil }
    return motion.reduceMotion ? HMotion.reduceMotionCurve.animation : HMotion.bouncy
  }

  private var reviewCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      Circle()
        .fill(HColor.surfaceSecondary)
        .overlay { Circle().strokeBorder(HColor.borderSubtle, lineWidth: 1) }
        .overlay { ArtText(text: "L", size: 17, leading: 22, weight: .semibold) }
        .frame(width: 40, height: 40)
      ArtText(text: "Lulu Hypermarket", size: 17, leading: 22, weight: .semibold)
      HStack(alignment: .firstTextBaseline, spacing: 5) {
        ArtFigure(text: "AED", size: 15, weight: .semibold, color: HColor.textPrimary)
        ArtFigure(text: "214.30", size: 28, tracking: -0.4, color: HColor.textPrimary)
      }
    }
    .padding(18)
    .frame(maxWidth: .infinity, alignment: .leading)
    .artCard(RoundedRectangle(cornerRadius: 24, style: .continuous), shadow: .hero)
  }

  private func chip(_ title: String, hue: Hue, ring: Bool = false) -> some View {
    ArtText(text: title, size: 14, leading: 18, weight: .semibold, color: hue.ink)
      .padding(.horizontal, 13)
      .frame(height: 32)
      .background(hue.perceptualGradient, in: Capsule())
      .overlay {
        if ring { Capsule().strokeBorder(HColor.hueSandInk.opacity(0.18), lineWidth: 1.5) }
      }
  }

  private var ruleChip: some View {
    HStack(spacing: 6) {
      ArtText(text: "Always Groceries for Lulu", size: 13, leading: 18, weight: .semibold)
      RuleCheck()
        .trim(from: 0, to: ticked ? 1 : 0)
        .stroke(HColor.moneyIn, style: StrokeStyle(lineWidth: 2.6 * 16 / 24, lineCap: .round, lineJoin: .round))
        .frame(width: 16, height: 16)
    }
    .padding(.leading, 14)
    .padding(.trailing, 12)
    .frame(height: 32)
    .artCard(Capsule(), shadow: .chip)
  }

  private func play() async {
    instantly {
      ghost = false
      card = false
      chips = 0
      leaning = false
      rule = false
      ticked = false
    }
    guard let run else { return }
    let m = motion
    if m.settled {
      instantly { ghost = true; card = true; chips = 4; rule = true; ticked = true }
      return
    }
    let clock = StageClock()
    ghost = true
    guard await clock.at(HMotion.stagger) else { return }
    card = true
    for i in 1...4 {
      guard await clock.at(HMotion.stagger * Double(i + 2)) else { return }
      chips = i
    }
    guard await clock.at(0.7) else { return }
    if !m.reduceMotion {
      withAnimation(HMotion.easeOutSoft(StoryTiming.lean)) { leaning = true }
    }
    guard await clock.at(0.7 + StoryTiming.lean) else { return }
    if run.byUser { leaned += 1 }
    guard await clock.at(0.7 + StoryTiming.lean + StoryTiming.leanHold) else { return }
    if !m.reduceMotion {
      withAnimation(HMotion.cardReturn) { leaning = false }
    }
    guard await clock.at(1.1) else { return }
    rule = true
    guard await clock.at(1.1 + HMotion.snappyResponse) else { return }
    withAnimation(m.reduceMotion ? nil : HMotion.easeOutSoft(StoryTiming.check)) { ticked = true }
  }
}

private nonisolated struct RuleCheck: Shape {
  func path(in rect: CGRect) -> Path {
    let s = rect.width / 24
    var p = Path()
    p.move(to: CGPoint(x: 5 * s, y: 12.5 * s))
    p.addLine(to: CGPoint(x: 9.5 * s, y: 17 * s))
    p.addLine(to: CGPoint(x: 19 * s, y: 7.5 * s))
    return p
  }
}
