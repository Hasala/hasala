import HasalaModels
import SwiftUI

public struct MonthPaceBar: View {
  let spent: Money
  let plan: Money
  let tick: Money?
  let verdict: Verdict
  let overflow: CGFloat
  let hidden: Bool
  let live: Bool
  let onWash: Bool
  let phase: PaceFillPhase?

  public init(spent: Money, plan: Money, tick: Money?, verdict: Verdict, overflow: CGFloat = 18,
              hidden: Bool = false, live: Bool = true, onWash: Bool = true, phase: PaceFillPhase? = nil)
  {
    self.spent = spent
    self.plan = plan
    self.tick = tick
    self.verdict = verdict
    self.overflow = overflow
    self.hidden = hidden
    self.live = live
    self.onWash = onWash
    self.phase = phase
  }

  public var fraction: Double {
    plan.minor > 0 ? Double(max(0, spent.minor)) / Double(plan.minor) : 0
  }

  private var tickFraction: Double? {
    guard let tick, plan.minor > 0 else { return nil }
    return min(1, Double(max(0, tick.minor)) / Double(plan.minor))
  }

  public var body: some View {
    MonthBarCanvas(
      drawn: plan.minor > 0 ? (phase?.fill ?? fraction) : 0, tick: tickFraction,
      tickVisible: phase?.tickVisible ?? true, live: live, overflowRoom: overflow,
      track: PaceBarTick.track(onWash: onWash), halo: PaceBarTick.halo(onWash: onWash))
      .frame(height: HSpacing.paceMarkerHeight)
      .accessibilityHidden(true)
  }
}

struct MonthBarCanvas: View, Animatable {
  var drawn: Double
  let tick: Double?
  let tickVisible: Bool
  let live: Bool
  let overflowRoom: CGFloat
  let track: Color
  let halo: Color

  nonisolated var animatableData: Double {
    get { drawn }
    set { drawn = newValue }
  }

  var body: some View {
    GeometryReader { geo in
      let w = geo.size.width
      let bar = HSpacing.paceBarHeight
      let shape = RoundedRectangle(cornerRadius: HRadius.paceBar, style: .continuous)
      ZStack(alignment: .leading) {
        shape.fill(track).hContrastEdge(shape).frame(width: w, height: bar)
        if drawn > 1 {
          shape.fill(HColor.paceFillOverBudget).frame(width: w, height: bar)
          overflowPiece(width: w)
        } else if drawn > 0 {
          let spentX = max(bar, w * drawn)
          if live, let tick, drawn > tick {
            shape.fill(HColor.paceFillOverPace).frame(width: spentX, height: bar)
            shape.fill(HColor.paceFill).frame(width: max(bar, w * tick), height: bar)
          } else {
            shape.fill(HColor.paceFill).frame(width: spentX, height: bar)
          }
        }
        if let tick, live {
          PaceBarTick(x: w * tick, visible: tickVisible, halo: halo)
        }
      }
      .frame(height: HSpacing.paceMarkerHeight)
    }
  }

  @ViewBuilder private func overflowPiece(width w: CGFloat) -> some View {
    let length = max(8, w * (drawn - 1))
    let room = overflowRoom
    let capped = length > room
    let piece = UnevenRoundedRectangle(
      topLeadingRadius: HRadius.paceBar, bottomLeadingRadius: HRadius.paceBar,
      bottomTrailingRadius: capped ? 0 : HRadius.paceBar, topTrailingRadius: capped ? 0 : HRadius.paceBar,
      style: .continuous)
    Group {
      if capped {
        piece.fill(.linearGradient(
          Gradient(stops: [.init(color: HColor.paceFillOverBudget, location: 0),
                           .init(color: HColor.paceFillOverBudget, location: 0.45),
                           .init(color: HColor.paceFillOverBudget.opacity(0), location: 1)]).colorSpace(.perceptual),
          startPoint: .leading, endPoint: .trailing))
      } else {
        piece.fill(HColor.paceFillOverBudget)
      }
    }
    .frame(width: min(length, room), height: HSpacing.paceBarHeight)
    .offset(x: w + 2)
  }
}

struct TodayTick: View {
  let height: CGFloat
  let halo: Color?

  var body: some View {
    RoundedRectangle(cornerRadius: 1)
      .fill(halo == nil ? HColor.white : HColor.paceMarker)
      .frame(width: 2, height: height)
      .background {
        if let halo {
          RoundedRectangle(cornerRadius: 2.5).fill(halo).frame(width: 5, height: height + 3)
        }
      }
  }
}

struct PaceBarTick: View {
  let x: CGFloat
  let visible: Bool
  let halo: Color

  var body: some View {
    TodayTick(height: HSpacing.paceMarkerHeight, halo: halo)
      .offset(x: x - 1)
      .offset(y: visible ? 0 : -HMotion.markerDrop)
      .opacity(visible ? 1 : 0)
  }

  static func track(onWash: Bool) -> Color { onWash ? HColor.progressTrackOnHue : HColor.paceTrack }
  static func halo(onWash: Bool) -> Color { onWash ? HColor.white.opacity(0.85) : HColor.surfacePrimary }
}

public struct CategoryPaceBar: View {
  let spent: Permille
  let tick: Permille?
  let verdict: Verdict
  let onWash: Bool
  let phase: PaceFillPhase?

  public init(spent: Permille, tick: Permille?, verdict: Verdict, onWash: Bool = false,
              phase: PaceFillPhase? = nil)
  {
    self.spent = spent
    self.tick = tick
    self.verdict = verdict
    self.onWash = onWash
    self.phase = phase
  }

  public var body: some View {
    CategoryBarCanvas(
      drawn: min(1, phase?.fill ?? spent.fraction), tick: tick.map { min(1, $0.fraction) },
      tickVisible: phase?.tickVisible ?? true, fill: verdict.fill,
      track: PaceBarTick.track(onWash: onWash), halo: PaceBarTick.halo(onWash: onWash))
      .frame(height: HSpacing.paceMarkerHeight)
      .accessibilityHidden(true)
  }
}

struct CategoryBarCanvas: View, Animatable {
  var drawn: Double
  let tick: Double?
  let tickVisible: Bool
  let fill: Color
  let track: Color
  let halo: Color

  nonisolated var animatableData: Double {
    get { drawn }
    set { drawn = newValue }
  }

  var body: some View {
    GeometryReader { geo in
      let w = geo.size.width
      let bar = HSpacing.paceBarHeight
      let shape = RoundedRectangle(cornerRadius: HRadius.paceBar, style: .continuous)
      ZStack(alignment: .leading) {
        shape.fill(track).hContrastEdge(shape).frame(width: w, height: bar)
        if drawn > 0 {
          shape.fill(fill).frame(width: max(bar, w * drawn), height: bar)
        }
        if let tick {
          PaceBarTick(x: w * tick, visible: tickVisible, halo: halo)
        }
      }
      .frame(height: HSpacing.paceMarkerHeight)
    }
  }
}

public struct SlimProgressBar: View {
  let progress: Permille
  let fill: Color
  let track: Color
  let height: CGFloat

  public init(_ progress: Permille, fill: Color = HColor.paceFill, track: Color = HColor.paceTrack,
              height: CGFloat = HSpacing.progressHeight)
  {
    self.progress = progress
    self.fill = fill
    self.track = track
    self.height = height
  }

  public var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        Capsule().fill(track).hContrastEdge(Capsule())
        if progress.value > 0 {
          Capsule().fill(fill).frame(width: max(height, geo.size.width * min(1, progress.fraction)))
        }
      }
    }
    .frame(height: height)
    .accessibilityHidden(true)
  }
}

public struct WidgetPaceBar: View {
  let spent: Permille
  let tick: Permille?
  let verdict: Verdict
  let inverse: Bool

  public init(spent: Permille, tick: Permille?, verdict: Verdict, inverse: Bool = false) {
    self.spent = spent
    self.tick = tick
    self.verdict = verdict
    self.inverse = inverse
  }

  public var body: some View {
    GeometryReader { geo in
      let w = geo.size.width
      ZStack(alignment: .leading) {
        Capsule().fill(inverse ? HColor.widgetOnInverseTrack : HColor.paceTrack).frame(height: 6)
        if spent.value > 0 {
          Capsule().fill(inverse ? HColor.blue300 : verdict.fill)
            .frame(width: max(6, w * min(1, spent.fraction)), height: 6)
        }
        if let tick {
          TodayTick(height: HSpacing.paceMarkerHeightWidget, halo: inverse ? nil : HColor.white)
            .offset(x: w * min(1, tick.fraction) - 1)
        }
      }
      .frame(height: HSpacing.paceMarkerHeightWidget)
    }
    .frame(height: HSpacing.paceMarkerHeightWidget)
    .accessibilityHidden(true)
  }
}

public struct VerdictLine: View {
  public enum Size: Sendable { case hero, card }

  public enum Tone: Sendable, Hashable {
    case verdict(Verdict)
    case neutral
  }

  let tone: Tone
  let word: String
  let fact: MoneyPhrase?
  let hidden: Bool
  let size: Size
  let onWash: Bool
  let link: (title: String, action: () -> Void)?

  public init(verdict: Verdict, word: String? = nil, fact: MoneyPhrase? = nil, hidden: Bool = false,
              size: Size = .hero, onWash: Bool = true, link: (title: String, action: () -> Void)? = nil)
  {
    self.init(tone: .verdict(verdict), word: word ?? verdict.label, fact: fact, hidden: hidden, size: size,
              onWash: onWash, link: link)
  }

  public init(tone: Tone, word: String, fact: MoneyPhrase? = nil, hidden: Bool = false, size: Size = .hero,
              onWash: Bool = true, link: (title: String, action: () -> Void)? = nil)
  {
    self.tone = tone
    self.word = word
    self.fact = fact
    self.hidden = hidden
    self.size = size
    self.onWash = onWash
    self.link = link
  }

  public var body: some View {
    ReflowingRow(spacing: 12) {
      HStack(alignment: .top, spacing: 6) {
        Circle().fill(dotColor).frame(width: size == .hero ? 8 : 7, height: size == .hero ? 8 : 7)
          .frame(height: lane)
        Text("\(Text(word).font(wordType.font).foregroundStyle(wordColor))\(factText)")
          .hType(size == .hero ? .subheadline : .footnote)
          .foregroundStyle(factColor)
          .fixedSize(horizontal: false, vertical: true)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(spoken)
    } trailing: {
      if let link {
        Button(link.title, action: link.action)
          .buttonStyle(.plain)
          .hType(size == .hero ? .subheadline.weight(.medium) : .footnote.weight(.medium))
          .foregroundStyle(onWash ? HColor.textOnWashLink : HColor.textLink)
          .frame(minHeight: HSpacing.targetMinimum)
          .contentShape(Rectangle())
      }
    }
  }

  @ScaledMetric(relativeTo: .subheadline) private var heroLane: CGFloat = 20
  @ScaledMetric(relativeTo: .footnote) private var cardLane: CGFloat = 18
  private var lane: CGFloat { size == .hero ? heroLane : cardLane }

  private var wordType: HType { (size == .hero ? HType.subheadline : HType.footnote).weight(.semibold) }

  private var factText: Text {
    Text(verbatim: fact.map { " · " + $0.rendered(hidden: hidden) } ?? "")
  }

  private var spoken: String {
    [word, fact.map { $0.spoken(hidden: hidden) }].compactMap { $0 }.joined(separator: ", ")
  }

  private var dotColor: Color {
    switch tone {
    case .verdict(let v): v == .overPace ? HColor.paceFillOverPace : v.foreground
    case .neutral: onWash ? HColor.textOnWashSecondary : HColor.textSecondary
    }
  }

  private var wordColor: Color {
    switch tone {
    case .verdict(let v): v.foreground
    case .neutral: HColor.textPrimary
    }
  }

  private var factColor: Color { onWash ? HColor.textOnWashSecondary : HColor.textSecondary }
}

public struct PaceFillPhase: Sendable, Hashable {
  public var fill: Double
  public var tickVisible: Bool
  public var verdictVisible: Bool

  public init(fill: Double = 0, tickVisible: Bool = false, verdictVisible: Bool = false) {
    self.fill = fill
    self.tickVisible = tickVisible
    self.verdictVisible = verdictVisible
  }

  public static func settled(_ target: Double) -> PaceFillPhase {
    PaceFillPhase(fill: target, tickVisible: true, verdictVisible: true)
  }

  public var started: Bool { fill > 0 || tickVisible }

  public func figure(_ money: Money) -> Money {
    started ? money : Money(minor: 0, currency: money.currency)
  }
}

public enum PaceFillOnce: Sendable, Hashable {
  case perAppearance
  case perProcess(String)
}

@MainActor
final class PaceFillMemory {
  static let shared = PaceFillMemory()
  private var played: Set<String> = []

  func hasPlayed(_ key: String) -> Bool { played.contains(key) }
  func markPlayed(_ key: String) { played.insert(key) }
  func reset() { played.removeAll() }
}

struct PaceFillSequence: ViewModifier {
  @Binding var phase: PaceFillPhase
  let target: Double
  let given: MotionPolicy
  let once: PaceFillOnce
  @State private var played = false
  @ResolvedMotion private var resolved: MotionPolicy

  private var policy: MotionPolicy {
    MotionPolicy(reduceMotion: given.reduceMotion || resolved.reduceMotion, settled: given.settled || resolved.settled)
  }

  func body(content: Content) -> some View {
    content
      .onAppear(perform: start)
      .onChange(of: target) { _, new in
        guard played else { return }
        withAnimation(policy.animation(.fillUpdate)) { phase = .settled(new) }
      }
  }

  private func start() {
    guard !played else { return }
    played = true
    let shouldPlay: Bool
    switch once {
    case .perAppearance: shouldPlay = true
    case .perProcess(let key):
      shouldPlay = !PaceFillMemory.shared.hasPlayed(key)
      PaceFillMemory.shared.markPlayed(key)
    }
    guard shouldPlay, !policy.isStill, target > 0 else {
      phase = .settled(target)
      return
    }
    phase = PaceFillPhase()
    withAnimation(policy.animation(.fill)) { phase.fill = target }
    withAnimation(policy.animation(.marker)?.delay(HMotion.fill)) { phase.tickVisible = true }
    withAnimation(policy.animation(.verdict)?.delay(HMotion.fill + HMotion.marker)) {
      phase.verdictVisible = true
    }
  }
}

public extension View {
  func paceFillSequence(_ phase: Binding<PaceFillPhase>, target: Double, policy: MotionPolicy,
                        once: PaceFillOnce = .perAppearance) -> some View
  {
    modifier(PaceFillSequence(phase: phase, target: target, given: policy, once: once))
  }
}
