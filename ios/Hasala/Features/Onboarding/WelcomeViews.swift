import HasalaDesign
import HasalaModels
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct Story: Identifiable {
  let id: Int
  let kicker: String
  let headline: [String]
  let accentSecondLine: Bool
  let body: String
  let whoSees: Bool
}

enum Stories {
  static let all: [Story] = [
    Story(id: 0, kicker: "Welcome to Hasala", headline: ["Know what's left.", "Keep it to yourself."],
          accentSecondLine: true,
          body: "Your budget, worked out on your iPhone. Rent counts when due, not when paid.",
          whoSees: false),
    Story(id: 1, kicker: "On your iPhone", headline: ["Your bank emails do the typing."], accentSecondLine: false,
          body: "Hasala reads the alerts your bank already sends. No bank logins.",
          whoSees: false),
    Story(id: 2, kicker: "Private by design", headline: ["Your phone", "holds the key."], accentSecondLine: false,
          body: "Your data is end-to-end encrypted before it leaves your iPhone. Our server can't open it.",
          whoSees: true),
    Story(id: 3, kicker: "Review", headline: ["Sort a week in a minute."], accentSecondLine: false,
          body: "Swipe transactions into Needs, Wants or Savings. Next time, Hasala suggests your pick.",
          whoSees: false),
  ]
}

@MainActor
@Observable
final class StoryPagerMotion {
  var position: Double

  init(position: Double) {
    self.position = position
  }
}

struct StoriesView: View {
  @Binding var page: Int
  @Binding var whoSeesOpen: Bool
  var outlook: Bool
  var onGetStarted: () -> Void
  var onPasteInvite: (String) -> Void
  var onSignIn: () -> Void

  init(
    page: Binding<Int>, whoSeesOpen: Binding<Bool>, outlook: Bool, onGetStarted: @escaping () -> Void,
    onPasteInvite: @escaping (String) -> Void, onSignIn: @escaping () -> Void
  ) {
    _page = page
    _whoSeesOpen = whoSeesOpen
    self.outlook = outlook
    self.onGetStarted = onGetStarted
    self.onPasteInvite = onPasteInvite
    self.onSignIn = onSignIn
    let start = min(max(page.wrappedValue, 0), Stories.all.count - 1)
    _position = State(initialValue: ScrollPosition(id: start))
    _pager = State(initialValue: StoryPagerMotion(position: Double(start)))
  }

  @State private var position: ScrollPosition
  @State private var pager: StoryPagerMotion
  @State private var clock = StoryClock()
  @State private var runs: [StoryRun?] = Array(repeating: nil, count: Stories.all.count)
  @State private var runCount = 0
  @State private var copyHeights: [CGFloat] = Array(repeating: 0, count: Stories.all.count)
  @State private var dragging = false
  @State private var onScreen = false
  @State private var placed = false
  @State private var copyIn = false
  @State private var fading = false
  @State private var settles = 0
  @State private var linkCopied = false
  @State private var pasteboardChecks = 0
  @State private var handStopped = false

  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
  @Environment(\.dynamicTypeSize) private var typeSize
  @StageMotion private var motion: MotionPolicy

  private var count: Int { Stories.all.count }

  private var visible: Bool { onScreen && !whoSeesOpen && scenePhase == .active }

  private var handPaced: Bool {
    Self.handPaced(voiceOver: voiceOver, accessibilitySize: typeSize.isAccessibilitySize,
                   reduceMotion: motion.reduceMotion, handStopped: handStopped)
  }

  static func handPaced(voiceOver: Bool, accessibilitySize: Bool, reduceMotion: Bool, handStopped: Bool) -> Bool {
    voiceOver || accessibilitySize || reduceMotion || handStopped
  }

  static func stopsAutoAdvance(_ phase: ScrollPhase) -> Bool {
    phase == .tracking || phase == .interacting
  }

  private var shouldRun: Bool { visible && !handPaced && !dragging }

  var body: some View {
    Group {
      if typeSize.isAccessibilitySize {
        largeTextLayout
      } else {
        GeometryReader { geo in
          VStack(spacing: 0) {
            progress
            header
            pagerArea
            startPanel(bottom: max(30, geo.safeAreaInsets.bottom - 4))
          }
        }
        .ignoresSafeArea(.container, edges: .bottom)
      }
    }
    .background { StoryBackground().ignoresSafeArea() }
    .toolbar(.hidden, for: .navigationBar)
    .sheet(isPresented: $whoSeesOpen) { WhoCanSeeSheet(outlook: outlook) }
    .hHaptic(.selection, trigger: settles)
    .onAppear { appeared() }
    .task(id: pasteboardChecks) { await lookForCopiedLink() }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { pasteboardChecks += 1 }
    }
    .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
      pasteboardChecks += 1
    }
    .onDisappear {
      onScreen = false
      clock.pause(at: .now)
    }
    .onChange(of: shouldRun) { _, run in
      if run { clock.resume(at: .now) } else { clock.pause(at: .now) }
    }
    .task(id: AdvanceKey(page: page, running: clock.isRunning)) { await advanceWhenDone() }
    .onChange(of: typeSize.isAccessibilitySize) { placed = false }
  }

  private var largeTextLayout: some View {
    ScrollView(.vertical) {
      VStack(spacing: 0) {
        progress
        header
        paged(
          ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 0) {
              ForEach(Stories.all) { story in
                StoryCopy(story: story, shown: copyIn, still: motion.isStill) { whoSeesOpen = true }
                  .fixedSize(horizontal: false, vertical: true)
                  .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { copyHeights[story.id] = $0 }
                  .frame(maxHeight: .infinity, alignment: .top)
                  .containerRelativeFrame(.horizontal)
                  .id(story.id)
              }
            }
            .scrollTargetLayout()
          }
        )
        .frame(height: max(1, copyHeights.max() ?? 0))
        .padding(.top, 16)
        startPanel(bottom: 30)
      }
    }
    .scrollBounceBehavior(.basedOnSize)
    .scrollIndicators(.hidden)
  }

  private var progress: some View {
    TimelineView(.animation(minimumInterval: nil, paused: !clock.isRunning)) { context in
      StoryProgress(count: count, current: page, fill: handPaced ? 1 : clock.progress(at: context.date))
    }
    .frame(height: 3)
    .padding(.top, 4)
    .padding(.horizontal, 16)
    .frame(minHeight: 7)
    .accessibilityHidden(true)
    .overlay {
      Color.clear
        .frame(height: 44)
        .contentShape(Rectangle())
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel("Page \(page + 1) of \(count)")
        .accessibilityAdjustableAction { direction in
          switch direction {
          case .increment: go(to: page + 1, byUser: true)
          case .decrement: go(to: page - 1, byUser: true)
          @unknown default: break
          }
        }
        .accessibilityIdentifier("stories.progress")
    }
  }

  private var header: some View {
    HStack(spacing: 10) {
      AppIconTile(size: 32, radius: 8)
        .shadow(color: HColor.blue950.opacity(0.14), radius: 5, y: 4)
        .shadow(color: HColor.blue950.opacity(0.18), radius: 1, y: 1)
      Text("Hasala")
        .hType(.subheadline.weight(.semibold))
        .foregroundStyle(HColor.textPrimary)
      if !typeSize.isAccessibilitySize {
        Text("Welcome")
          .hType(.subheadline)
          .foregroundStyle(HColor.textOnWashSecondary)
      }
      Spacer(minLength: 0)
    }
    .frame(minHeight: 36)
    .padding(.top, 12)
    .padding(.horizontal, 16)
    .accessibilityElement(children: .combine)
  }

  private func startPanel(bottom: CGFloat) -> some View {
    VStack(spacing: 12) {
      if linkCopied {
        CopiedInviteCard(stacked: typeSize.isAccessibilitySize, onPaste: onPasteInvite)
          .hTransition(.fade)
      }
      Button("Get started", action: onGetStarted)
        .buttonStyle(.pill(.primary, fill: true))
        .accessibilityIdentifier("stories.getStarted")
      Button(action: onSignIn) {
        Text("I already have an account").foregroundStyle(HColor.textPrimary)
      }
      .buttonStyle(.pill(.onGrouped, fill: true))
      .accessibilityIdentifier("stories.signIn")
      Menu {
        Link("Terms", destination: URL(string: "https://hasala.app/terms")!)
        Link("Privacy Policy", destination: URL(string: "https://hasala.app/privacy")!)
      } label: {
        Self.termsLine
          .hType(.footnote.weight(.medium))
          .fixedSize(horizontal: false, vertical: true)
          .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(Rectangle())
      }
      .padding(.vertical, -10)
      .accessibilityHint("Opens the Terms or the Privacy Policy.")
      .accessibilityIdentifier("stories.legal")
    }
    .hAnimation(.fade, value: linkCopied)
    .padding(.horizontal, HSpacing.insetPage)
    .padding(.bottom, bottom)
  }

  static let termsWording = "By continuing, you agree to our Terms and Privacy Policy."

  private static var termsLine: Text {
    let secondary = { (s: String) in Text(s).foregroundStyle(HColor.textOnWashSecondary) }
    let link = { (s: String) in Text(s).foregroundStyle(HColor.textOnWashLink) }
    return Text("\(secondary("By continuing, you agree to our "))\(link("Terms"))\(secondary(" and "))\(link("Privacy Policy"))\(secondary("."))")
  }

  private func lookForCopiedLink() async {
    let pasteboard = UIPasteboard.general
    guard pasteboard.hasStrings || pasteboard.hasURLs else {
      linkCopied = false
      return
    }
    let found = await Self.webURLCopied(pasteboard)
    guard !Task.isCancelled else { return }
    linkCopied = found
  }

  private nonisolated static func webURLCopied(_ pasteboard: UIPasteboard) async -> Bool {
    let found = try? await pasteboard.detectedPatterns(for: [\.probableWebURL])
    return found?.contains(\.probableWebURL) == true
  }

  private var pagerArea: some View {
    GeometryReader { area in
      let metrics = (0..<count).map { stageMetrics($0, in: area.size) }
      ZStack(alignment: .top) {
        SharedOrbit(pager: pager, metrics: metrics, clock: clock, still: motion.isStill)
        paged(
          ScrollView(.horizontal) {
            HStack(spacing: 0) {
              ForEach(Stories.all) { story in
                storyPage(story, metrics: metrics[story.id], width: area.size.width)
                  .containerRelativeFrame(.horizontal)
                  .id(story.id)
              }
            }
            .scrollTargetLayout()
          }
        )
      }
    }
  }

  private func paged(_ scroller: some View) -> some View {
    scroller
      .scrollTargetBehavior(.paging)
      .scrollPosition($position)
      .onScrollGeometryChange(for: Bool.self) { g in
        g.containerSize.width > 0 && g.contentSize.width > g.containerSize.width
      } action: { _, laidOut in
        guard laidOut, !placed else { return }
        placed = true
        guard page != 0 else { return }
        Task { @MainActor in
          instantly { position.scrollTo(id: page) }
        }
      }
      .scrollIndicators(.hidden)
      .onScrollGeometryChange(for: Double.self) { g in
        Double(g.contentOffset.x / max(1, g.containerSize.width))
      } action: { _, x in
        pager.position = x
      }
      .onScrollPhaseChange { _, phase in scrollPhaseChanged(phase) }
      .opacity(fading ? 0 : 1)
      .accessibilityIdentifier("stories.pager")
  }

  private func storyPage(_ story: Story, metrics: StageMetrics, width: CGFloat) -> some View {
    ScrollView(.vertical) {
      VStack(spacing: 0) {
        if metrics.shown {
          stage(story, metrics: metrics, width: width)
        }
        StoryCopy(story: story, shown: copyIn, still: motion.isStill) { whoSeesOpen = true }
          .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { copyHeights[story.id] = $0 }
      }
    }
    .scrollBounceBehavior(.basedOnSize)
    .scrollIndicators(.hidden)
  }

  private func stage(_ story: Story, metrics: StageMetrics, width: CGFloat) -> some View {
    let still = motion.isStill
    return StoryArt(
      index: story.id, run: runs[story.id],
      floating: !still && visible && story.id == page && runs[story.id] != nil)
      .scaleEffect(metrics.scale, anchor: .top)
      .frame(width: width, height: metrics.height, alignment: .top)
      .visualEffect { content, proxy in
        content.offset(x: still ? 0 : proxy.frame(in: .scrollView(axis: .horizontal)).minX * 0.25)
      }
      .contentShape(Rectangle())
      .onTapGesture { location in
        go(to: location.x < width / 3 ? page - 1 : page + 1, byUser: true)
      }
  }

  private func stageMetrics(_ index: Int, in size: CGSize) -> StageMetrics {
    let room = max(0, size.height - copyHeights[index])
    let scale = min(1, size.width / 402, room / StoryArt.heights[index])
    let shown = room >= 150 && scale >= 0.45
    return StageMetrics(height: shown ? room : 0, scale: shown ? scale : 0, shown: shown)
  }

  private func appeared() {
    onScreen = true
    guard runs.allSatisfy({ $0 == nil }) else {
      if shouldRun { clock.resume(at: .now) }
      return
    }
    start(page, byUser: false)
    resetOthers(except: page)
    if motion.isStill {
      withAnimation(motion.settled ? nil : HMotion.reduceMotionCurve.animation) { copyIn = true }
    } else {
      withAnimation(HMotion.easeOutSoft(HMotion.rise).delay(0.16)) { copyIn = true }
    }
  }

  private func scrollPhaseChanged(_ phase: ScrollPhase) {
    if Self.stopsAutoAdvance(phase) { handStopped = true }
    switch phase {
    case .tracking, .interacting, .decelerating:
      dragging = true
    case .animating:
      break
    case .idle:
      dragging = false
      let landed = min(max(Int(pager.position.rounded()), 0), count - 1)
      if landed != page {
        start(landed, byUser: true)
        resetOthers(except: landed)
        settles += 1
      }
    @unknown default:
      dragging = false
    }
  }

  private func go(to target: Int, byUser: Bool) {
    if byUser { handStopped = true }
    guard (0..<count).contains(target), target != page else { return }
    let m = motion
    if m.settled {
      position.scrollTo(id: target)
      start(target, byUser: byUser)
      resetOthers(except: target)
      if byUser { settles += 1 }
      return
    }
    if m.reduceMotion {
      withAnimation(HMotion.easeOutSoft(HMotion.reduceMotionFade / 2)) {
        fading = true
      } completion: {
        position.scrollTo(id: target)
        pager.position = Double(target)
        start(target, byUser: byUser)
        resetOthers(except: target)
        withAnimation(HMotion.easeOutSoft(HMotion.reduceMotionFade)) {
          fading = false
        } completion: {
          if byUser { settles += 1 }
        }
      }
      return
    }
    start(target, byUser: byUser)
    withAnimation(HMotion.snappy) {
      position.scrollTo(id: target)
    } completion: {
      resetOthers(except: target)
      if byUser { settles += 1 }
    }
  }

  private func start(_ index: Int, byUser: Bool) {
    page = index
    clock.restart(at: .now, running: shouldRun)
    runCount += 1
    runs[index] = StoryRun(id: runCount, byUser: byUser)
  }

  private func resetOthers(except index: Int) {
    for i in 0..<count where i != index { runs[i] = nil }
  }

  private func advanceWhenDone() async {
    guard clock.isRunning else { return }
    try? await Task.sleep(for: .seconds(clock.remaining(at: .now)))
    guard !Task.isCancelled, clock.isRunning, shouldRun else { return }
    if page < count - 1 {
      go(to: page + 1, byUser: false)
    } else {
      clock.finish()
    }
  }

  private struct AdvanceKey: Equatable {
    let page: Int
    let running: Bool
  }
}

private struct WidePasteButton: UIViewRepresentable {
  var identifier: String
  var fill: Bool
  var onPaste: (String) -> Void

  func makeUIView(context: Context) -> PasteTarget {
    let target = PasteTarget()
    target.onPaste = onPaste
    let config = UIPasteControl.Configuration()
    config.displayMode = .iconAndLabel
    config.cornerStyle = .capsule
    config.baseBackgroundColor = UIColor(HColor.actionAccentSubtle)
    config.baseForegroundColor = UIColor(HColor.textLink)
    let control = UIPasteControl(configuration: config)
    control.target = target
    control.accessibilityIdentifier = identifier
    control.accessibilityHint = "Uses the invite link you copied."
    control.translatesAutoresizingMaskIntoConstraints = false
    target.addSubview(control)
    NSLayoutConstraint.activate([
      control.leadingAnchor.constraint(equalTo: target.leadingAnchor),
      control.trailingAnchor.constraint(equalTo: target.trailingAnchor),
      control.topAnchor.constraint(equalTo: target.topAnchor),
      control.bottomAnchor.constraint(equalTo: target.bottomAnchor),
    ])
    return target
  }

  func updateUIView(_ target: PasteTarget, context: Context) {
    target.onPaste = onPaste
  }

  func sizeThatFits(_ proposal: ProposedViewSize, uiView target: PasteTarget, context: Context) -> CGSize? {
    guard let control = target.subviews.first else { return nil }
    let limit = CGSize(width: proposal.width ?? UIView.layoutFittingExpandedSize.width, height: UIView.layoutFittingExpandedSize.height)
    let fitted = control.sizeThatFits(limit)
    let laid = control.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
    let intrinsic = control.intrinsicContentSize
    let natural = CGSize(
      width: max(fitted.width, laid.width, intrinsic.width), height: max(fitted.height, laid.height, intrinsic.height))
    let width = fill ? (proposal.width ?? natural.width) : min(natural.width, proposal.width ?? natural.width)
    return CGSize(width: max(width, 88), height: max(natural.height, 44))
  }

  final class PasteTarget: UIView {
    var onPaste: (String) -> Void = { _ in }

    override init(frame: CGRect) {
      super.init(frame: frame)
      pasteConfiguration = UIPasteConfiguration(
        acceptableTypeIdentifiers: [UTType.utf8PlainText.identifier, UTType.plainText.identifier, UTType.url.identifier])
    }

    required init?(coder: NSCoder) { nil }

    override func canPaste(_ itemProviders: [NSItemProvider]) -> Bool { true }

    override func paste(itemProviders: [NSItemProvider]) {
      guard let provider = itemProviders.first else { return }
      let deliver: @Sendable (String) -> Void = { [weak self] text in
        Task { @MainActor in self?.onPaste(text) }
      }
      if provider.canLoadObject(ofClass: NSString.self) {
        _ = provider.loadObject(ofClass: NSString.self) { value, _ in deliver((value as? NSString as String?) ?? "") }
      } else {
        _ = provider.loadObject(ofClass: NSURL.self) { value, _ in deliver((value as? NSURL)?.absoluteString ?? "") }
      }
    }
  }
}

struct CopiedInviteCard: View {
  var stacked: Bool
  var onPaste: (String) -> Void

  static let title = "Have an invite link?"

  var body: some View {
    Group {
      if stacked {
        VStack(alignment: .leading, spacing: 10) {
          message
          paste(fill: true)
        }
      } else {
        HStack(spacing: 10) {
          message
          Spacer(minLength: 0)
          paste(fill: false)
        }
      }
    }
    .padding(.vertical, 10)
    .padding(.horizontal, 14)
    .background(HColor.surfacePrimary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(HColor.blue200, lineWidth: 1)
    }
  }

  private var message: some View {
    HStack(alignment: .top, spacing: 10) {
      VStack(alignment: .leading, spacing: 1) {
        Text(Self.title)
          .hType(.subheadline.weight(.semibold))
          .foregroundStyle(HColor.textPrimary)
        Text("Paste it here. No code to type.")
          .hType(.footnote)
          .foregroundStyle(HColor.textSecondary)
      }
      .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("stories.inviteFound")
  }

  private func paste(fill: Bool) -> some View {
    WidePasteButton(identifier: "stories.useInvite", fill: fill, onPaste: onPaste)
      .frame(maxWidth: fill ? .infinity : nil, minHeight: 44)
      .fixedSize(horizontal: !fill, vertical: true)
  }
}

struct StageMetrics: Equatable {
  var height: CGFloat
  var scale: CGFloat
  var shown: Bool
}

private struct SharedOrbit: View {
  let pager: StoryPagerMotion
  let metrics: [StageMetrics]
  let clock: StoryClock
  let still: Bool

  var body: some View {
    let x = min(max(pager.position, 0), Double(metrics.count - 1))
    let i0 = Int(x.rounded(.down))
    let i1 = min(i0 + 1, metrics.count - 1)
    let f = x - Double(i0)
    let scale = lerp(metrics[i0].scale, metrics[i1].scale, f)
    let top = lerp(StoryArt.orbitTop[i0], StoryArt.orbitTop[i1], f)
    let shown = lerp(metrics[i0].shown ? 1 : 0, metrics[i1].shown ? 1 : 0, f)
    ZStack(alignment: .topLeading) {
      OrbitGlow().offset(x: 41, y: top + 6)
      TimelineView(.animation(minimumInterval: nil, paused: still || !clock.isRunning)) { context in
        OrbitRings(turn: still ? 0 : x * 20, dot: still ? 0 : clock.progress(at: context.date) * 360)
      }
      .offset(y: top)
    }
    .frame(width: 402, height: 420, alignment: .topLeading)
    .scaleEffect(max(scale, 0.01), anchor: .top)
    .opacity(shown)
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }

  private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }
}

private struct StoryCopy: View {
  let story: Story
  let shown: Bool
  let still: Bool
  let onWhoSees: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(story.kicker)
        .hType(.overline)
        .foregroundStyle(HColor.hueSkyInk)
      headline
        .hType(.largeTitle)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)
      Text(story.body)
        .hType(.body)
        .foregroundStyle(HColor.textOnWashSecondary)
        .fixedSize(horizontal: false, vertical: true)
      if story.whoSees {
        Button(action: onWhoSees) {
          HStack(spacing: 4) {
            Text("Who can see what")
              .hType(.subheadline.weight(.semibold))
            HIconView(.chevronRight, size: 16, color: HColor.textOnWashLink, strokeWidth: 2.4)
          }
          .foregroundStyle(HColor.textOnWashLink)
          .frame(minHeight: 44)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, -8)
        .accessibilityIdentifier("stories.whoSees")
      }
    }
    .padding(.horizontal, 24)
    .padding(.bottom, 24)
    .frame(maxWidth: .infinity, alignment: .leading)
    .offset(y: shown || still ? 0 : HMotion.travelRise)
    .opacity(shown ? 1 : 0)
  }

  private var headline: Text {
    let lines = story.headline
    let first = Text(lines[0]).foregroundStyle(HColor.textPrimary)
    guard lines.count > 1 else { return first }
    let second = Text(lines[1]).foregroundStyle(story.accentSecondLine ? HColor.blue700 : HColor.textPrimary)
    return Text("\(first)\n\(second)")
  }
}
