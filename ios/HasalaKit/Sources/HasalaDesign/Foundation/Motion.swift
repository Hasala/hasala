import SwiftUI

public enum HMotion {
  public static func easeOutSoft(_ duration: Double) -> Animation {
    .timingCurve(0.22, 1, 0.36, 1, duration: duration)
  }

  public static func easeInOut(_ duration: Double) -> Animation {
    .timingCurve(0.65, 0, 0.35, 1, duration: duration)
  }

  public static let snappyResponse = 0.28
  public static let snappyDamping = 0.86
  public static let snappy = Animation.spring(response: snappyResponse, dampingFraction: snappyDamping)

  public static let dropStiffness = 420.0
  public static let dropDamping = 26.0
  public static let springDrop = Animation.interpolatingSpring(stiffness: dropStiffness, damping: dropDamping)

  public static let cardReturnResponse = 0.3
  public static let cardReturnDamping = 0.8
  public static let cardReturn = Animation.spring(response: cardReturnResponse, dampingFraction: cardReturnDamping)

  public static let dealResponse = 0.5
  public static let dealDamping = 0.78
  public static let springDeal = Animation.spring(response: dealResponse, dampingFraction: dealDamping)

  public static let bouncy = Animation.bouncy

  public static let celebrateResponse = 0.42
  public static let celebrateDamping = 0.72
  public static let celebrate = Animation.spring(response: celebrateResponse, dampingFraction: celebrateDamping)
  public static let celebrateLimit = 0.6

  public static let pressBack = 0.12
  public static let highlight = 0.10
  public static let fade = 0.18
  public static let rise = 0.22
  public static let toastIn = 0.22
  public static let toastOut = 0.18
  public static let count = 0.30
  public static let fill = 0.30
  public static let marker = 0.12
  public static let verdict = 0.15
  public static let fillUpdate = 0.25
  public static let cardCommit = 0.20
  public static let sheetContent = 0.25
  public static let hideAmounts = 0.15
  public static let reduceMotionFade = 0.15
  public static let stagger = 0.08
  public static let staggerLimit = 4
  public static let storyDuration = 6.0
  public static let toastDwell = 4.0
  public static let toastDwellVoiceOver = 8.0
  public static let undoLineDwell = 6.0

  public static let travelRise: CGFloat = 12
  public static let travelDeal: CGFloat = 40
  public static let pressScale: CGFloat = 0.97
  public static let dealScale: CGFloat = 0.94
  public static let chipPopScale: CGFloat = 0.8
  public static let nextCardScale: CGFloat = 0.96
  public static let nextCardLift: CGFloat = 8
  public static let cardFlyOut: CGFloat = 1.4
  public static let cardFlyTilt = 16.0
  public static let commitTilt = 3.0
  public static let markerDrop: CGFloat = 4
  public static let idleFloat: CGFloat = 4
  public static let idlePeriod = 4.0
}

public struct ToastWindow: Sendable, Equatable {
  public private(set) var left: Duration
  private let dwell: Duration
  private var since: ContinuousClock.Instant?
  private var held = false
  private var away: Bool

  public init(dwell: Duration, away: Bool, now: ContinuousClock.Instant) {
    self.dwell = dwell
    left = dwell
    self.away = away
    since = away ? nil : now
  }

  public var counting: Bool { since != nil }

  public mutating func hold(_ on: Bool, now: ContinuousClock.Instant) {
    held = on
    left = dwell
    since = held || away ? nil : now
  }

  @discardableResult
  public mutating func setAway(_ on: Bool, now: ContinuousClock.Instant) -> Bool {
    guard on != away else { return false }
    away = on
    if on {
      if let since { left = max(.zero, left - since.duration(to: now)) }
      since = nil
      held = false
    } else {
      since = now
    }
    return true
  }
}

public extension HMotion {
  enum Kind: Sendable, Hashable {
    case press
    case highlight
    case fade
    case rise
    case toastIn
    case toastOut
    case fill
    case fillUpdate
    case marker
    case verdict
    case count
    case deal(index: Int)
    case chipPop
    case pagerSettle
    case cardSettle
    case cardCommit
    case cardNext
    case cardReturn
    case thumbSlide
    case stateSwap
    case idleFloat
    case sheetContent
    case celebrate
    case hideAmounts

    public static let allKinds: [Kind] = [
      .press, .highlight, .fade, .rise, .toastIn, .toastOut, .fill, .fillUpdate, .marker, .verdict, .count,
      .deal(index: 0), .chipPop, .pagerSettle, .cardSettle, .cardCommit, .cardNext, .cardReturn, .thumbSlide,
      .stateSwap, .idleFloat, .sheetContent, .celebrate, .hideAmounts,
    ]
  }

  enum Curve: Sendable, Hashable {
    case easeOutSoft(duration: Double)
    case easeInOut(duration: Double)
    case linear(duration: Double)
    case spring(response: Double, damping: Double)
    case interpolatingSpring(stiffness: Double, damping: Double)
    case bouncy
    case loop(period: Double)

    public var animation: Animation {
      switch self {
      case .easeOutSoft(let d): HMotion.easeOutSoft(d)
      case .easeInOut(let d): HMotion.easeInOut(d)
      case .linear(let d): .linear(duration: d)
      case .spring(let r, let z): .spring(response: r, dampingFraction: z)
      case .interpolatingSpring(let k, let c): .interpolatingSpring(stiffness: k, damping: c)
      case .bouncy: .bouncy
      case .loop(let period): .easeInOut(duration: period / 2).repeatForever(autoreverses: true)
      }
    }

    public var nominalDuration: Double {
      switch self {
      case .easeOutSoft(let d), .easeInOut(let d), .linear(let d): d
      case .spring(let response, _): response
      case .interpolatingSpring: 0.25
      case .bouncy: 0.5
      case .loop(let period): period
      }
    }
  }

  static let reduceMotionCurve = Curve.easeOutSoft(duration: reduceMotionFade)

  static func normal(_ kind: Kind) -> Curve {
    switch kind {
    case .press: .easeOutSoft(duration: pressBack)
    case .highlight: .easeOutSoft(duration: highlight)
    case .fade, .stateSwap: .easeOutSoft(duration: fade)
    case .rise: .easeOutSoft(duration: rise)
    case .toastIn: .easeOutSoft(duration: toastIn)
    case .toastOut: .easeOutSoft(duration: toastOut)
    case .fill: .easeInOut(duration: fill)
    case .fillUpdate: .easeInOut(duration: fillUpdate)
    case .marker: .easeOutSoft(duration: marker)
    case .verdict: .easeOutSoft(duration: verdict)
    case .count: .easeInOut(duration: count)
    case .deal: .spring(response: dealResponse, damping: dealDamping)
    case .chipPop: .bouncy
    case .pagerSettle, .thumbSlide: .spring(response: snappyResponse, damping: snappyDamping)
    case .cardSettle, .cardNext: .interpolatingSpring(stiffness: dropStiffness, damping: dropDamping)
    case .cardCommit: .easeOutSoft(duration: cardCommit)
    case .cardReturn: .spring(response: cardReturnResponse, damping: cardReturnDamping)
    case .idleFloat: .loop(period: idlePeriod)
    case .sheetContent: .easeOutSoft(duration: sheetContent)
    case .celebrate: .spring(response: celebrateResponse, damping: celebrateDamping)
    case .hideAmounts: .easeOutSoft(duration: hideAmounts)
    }
  }

  static func reduced(_ kind: Kind) -> Curve? {
    switch kind {
    case .press, .highlight, .fade, .stateSwap, .hideAmounts: normal(kind)
    case .rise, .toastIn, .toastOut, .deal, .chipPop, .pagerSettle, .cardCommit, .cardNext, .celebrate,
         .sheetContent:
      reduceMotionCurve
    case .fill, .fillUpdate, .marker, .verdict, .count, .cardSettle, .cardReturn, .thumbSlide, .idleFloat: nil
    }
  }

  static func dealDelay(index: Int) -> Double {
    stagger * Double(min(max(index, 0), staggerLimit - 1))
  }
}

public struct MotionPolicy: Sendable, Equatable {
  public var reduceMotion: Bool
  public var settled: Bool

  public init(reduceMotion: Bool = false, settled: Bool = false) {
    self.reduceMotion = reduceMotion
    self.settled = settled
  }

  public var isStill: Bool { reduceMotion || settled }

  public func curve(_ kind: HMotion.Kind) -> HMotion.Curve? {
    if settled { return nil }
    return reduceMotion ? HMotion.reduced(kind) : HMotion.normal(kind)
  }

  public func animation(_ kind: HMotion.Kind) -> Animation? {
    guard let curve = curve(kind) else { return nil }
    if case .deal(let index) = kind, !reduceMotion {
      return curve.animation.delay(HMotion.dealDelay(index: index))
    }
    return curve.animation
  }

  public func transition(_ kind: HMotion.Kind) -> AnyTransition {
    if settled { return .identity }
    if reduceMotion { return .opacity }
    switch kind {
    case .rise:
      return .offset(y: HMotion.travelRise).combined(with: .opacity)
    case .toastIn, .toastOut:
      return .asymmetric(
        insertion: AnyTransition.offset(y: HMotion.travelRise).combined(with: .opacity)
          .animation(HMotion.normal(.toastIn).animation),
        removal: AnyTransition.opacity.animation(HMotion.normal(.toastOut).animation))
    case .deal:
      return AnyTransition.offset(y: HMotion.travelDeal)
        .combined(with: .scale(scale: HMotion.dealScale)).combined(with: .opacity)
    case .chipPop, .celebrate:
      return AnyTransition.scale(scale: HMotion.chipPopScale).combined(with: .opacity)
    case .cardNext:
      return AnyTransition.scale(scale: HMotion.nextCardScale)
        .combined(with: .offset(y: HMotion.nextCardLift)).combined(with: .opacity)
    case .marker:
      return AnyTransition.offset(y: -HMotion.markerDrop).combined(with: .opacity)
    default:
      return .opacity
    }
  }
}

public extension EnvironmentValues {
  @Entry var hMotion = MotionPolicy()
}

@MainActor @propertyWrapper
struct ResolvedMotion: DynamicProperty {
  @Environment(\.hMotion) private var policy
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

  init() {}

  var wrappedValue: MotionPolicy {
    var p = policy
    p.reduceMotion = p.reduceMotion || systemReduceMotion
    return p
  }
}

struct MotionPolicyRoot: ViewModifier {
  let settled: Bool
  let forceReduceMotion: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    content.environment(\.hMotion, MotionPolicy(reduceMotion: reduceMotion || forceReduceMotion, settled: settled))
  }
}

struct HAnimationModifier<V: Equatable>: ViewModifier {
  let kind: HMotion.Kind
  let value: V
  @ResolvedMotion private var motion: MotionPolicy

  func body(content: Content) -> some View {
    content.animation(motion.animation(kind), value: value)
  }
}

struct HTransitionModifier: ViewModifier {
  let kind: HMotion.Kind
  @ResolvedMotion private var motion: MotionPolicy

  func body(content: Content) -> some View {
    content.transition(motion.transition(kind))
  }
}

struct NumberRollModifier: ViewModifier {
  let value: Double
  @ResolvedMotion private var motion: MotionPolicy

  func body(content: Content) -> some View {
    content.contentTransition(motion.isStill ? .identity : .numericText(value: value))
  }
}

public extension View {
  func hMotionPolicy(settled: Bool = false, forceReduceMotion: Bool = false) -> some View {
    modifier(MotionPolicyRoot(settled: settled, forceReduceMotion: forceReduceMotion))
  }

  func hAnimation<V: Equatable>(_ kind: HMotion.Kind, value: V) -> some View {
    modifier(HAnimationModifier(kind: kind, value: value))
  }

  func hTransition(_ kind: HMotion.Kind) -> some View {
    modifier(HTransitionModifier(kind: kind))
  }

  func numberRoll(_ value: Double) -> some View {
    modifier(NumberRollModifier(value: value))
  }
}

@MainActor
public func withHMotion<Result>(_ kind: HMotion.Kind, _ policy: MotionPolicy, _ body: () throws -> Result) rethrows
  -> Result
{
  try withAnimation(policy.animation(kind), body)
}
