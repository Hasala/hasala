import HasalaDesign
import HasalaModels
import SwiftUI

#if HASALA_MOCKS
  import HasalaMocks
#endif

struct ReviewDeckView: View {
  @Bindable var app: AppModel
  let model: any ReviewDeckModel

  @State private var drag: CGSize = .zero
  @GestureState private var touched: TxnID?
  @State private var crossed: SwipeEdge?
  @State private var held: SwipeEdge?
  @State private var flights: [Flight] = []
  @State private var departures: [String: SwipeEdge] = [:]
  @State private var tap = 0
  @State private var pendingSort: PendingSort?
  @State private var reasonInfo: ReviewCardModel?
  @State private var pendingArchive: ReviewCardModel?
  @State private var pendingCopy: (card: ReviewCardModel, merge: Bool)?
  @State private var pendingMerge: ReviewCardModel?
  @State private var choosingRange = false
  @State private var openTxn: TxnRef?
  @State private var openedFromDone = false
  @State private var deckSize: CGSize = .zero
  @State private var idealRegular: CGFloat = 0
  @State private var idealCompact: CGFloat = 0

  struct TxnRef: Identifiable, Hashable {
    let id: TxnID
  }

  enum DeckFit: Equatable {
    case regular, compact, scroll
  }

  static let deckOverhead: CGFloat = 20 + pillSlot + 20 + peekDepth + 22 + pillSlot + 12 + HSpacing.targetMinimum + 2
  static let compactFloor: CGFloat = 240

  static func fit(height: CGFloat, regular: CGFloat, compact: CGFloat, accessibility: Bool) -> DeckFit {
    if accessibility { return .scroll }
    guard height > 0, regular > 0 else { return .regular }
    let room = min(height - deckOverhead, cardHeight)
    if room >= 300, regular <= room { return .regular }
    if room >= compactFloor, compact <= room { return .compact }
    return .scroll
  }

  private var deckFit: DeckFit {
    Self.fit(height: deckSize.height, regular: idealRegular, compact: idealCompact,
             accessibility: typeSize.isAccessibilitySize)
  }

  private struct PendingSort {
    enum Into {
      case category(CategoryID)
      case newCategory(name: String, glyph: Glyph)
    }

    let pick: ReviewPick
    let into: Into
    let alwaysUse: Bool
    let project: ProjectID?
  }

  @Environment(\.hMotion) private var policy
  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.dynamicTypeSize) private var typeSize

  private var motion: MotionPolicy {
    MotionPolicy(reduceMotion: policy.reduceMotion || systemReduceMotion, settled: policy.settled)
  }

  private var showsDeck: Bool { !model.cards.isEmpty || !flights.isEmpty }

  var body: some View {
    let top = model.cards.first
    VStack(spacing: 0) {
      header(done: !showsDeck)
      rangeRow
      progress
      Group {
        if showsDeck {
          deck(top)
            .transition(.opacity)
        } else {
          ReviewDoneView(model: model, toasts: openedFromDone ? app : nil) {
            openedFromDone = true
            openTxn = TxnRef(id: $0)
          }
          .transition(.opacity)
        }
      }
      .frame(maxHeight: .infinity)
      .animation(motion.animation(.stateSwap), value: showsDeck)
      .sheet(item: $reasonInfo, onDismiss: reasonInfoClosed) { card in
        if let reason = card.reviewReason {
          ReviewReasonSheet(
            reason: reason,
            sort: {
              keepText(card)
              reasonInfo = nil
            },
            archive: {
              pendingArchive = card
              reasonInfo = nil
            },
            merge: {
              pendingCopy = (card, true)
              reasonInfo = nil
            },
            keepBoth: {
              pendingCopy = (card, false)
              reasonInfo = nil
            })
        }
      }
    }
    .overlay(alignment: .bottom) {
      if showsDeck, deckFit == .scroll { ToastHost(app: app, placement: .bottom) }
    }
    .nestedTransactionSheet(item: $openTxn, app: app)
    .frame(minHeight: 0, maxHeight: .infinity)
    .ignoresSafeArea(.keyboard)
    .background(alignment: .top) { AmbientWash(.onTrack).ignoresSafeArea() }
    .background(HColor.surfaceSecondary)
    .hHaptic(.impactLight, trigger: tap)
    .sheet(item: pickBinding, onDismiss: pickClosed) { pick in
      ReviewPickSheet(
        model: model, pick: pick,
        sort: { category, alwaysUse, project in
          sortPicked(pick, into: category, alwaysUse: alwaysUse, project: project)
        },
        create: { name, glyph, alwaysUse, project in
          createPicked(pick, name: name, glyph: glyph, alwaysUse: alwaysUse, project: project)
        },
        merge: pick.card.copyLine == nil ? nil : {
          pendingMerge = pick.card
          model.picking = nil
        })
    }
    .onAppear {
      SortSound.shared.prepare()
      if let p = model.picking { holdToward(edge(for: p.choice), animated: false) }
    }
    .onDisappear { SortSound.shared.rest() }
    .onChange(of: touched) { _, now in
      if now == nil { released() }
    }
    .onChange(of: showsDeck) { _, now in
      if now { openedFromDone = false } else { app.dismissToast() }
    }
  }

  private var pickBinding: Binding<ReviewPick?> {
    Binding(get: { model.picking }, set: { model.picking = $0 })
  }

  private func header(done: Bool) -> some View {
    HStack {
      GlassIconButton(.close, label: "Close") { model.close(goToActivity: false) }
        .accessibilityIdentifier("review.close")
      Spacer()
      VStack(spacing: 0) {
        Text("Review")
          .hType(.headline.weight(.semibold))
          .foregroundStyle(HColor.textPrimary)
          .accessibilityAddTraits(.isHeader)
        if model.total > 0 {
          Text("\(model.position) of \(model.total)")
            .hFigure(HFigure(size: 13, leading: 18, weight: .medium, textStyle: .footnote, tabular: true))
            .foregroundStyle(HColor.textSecondary)
            .numberRoll(Double(model.position))
            .accessibilityIdentifier("review.position")
        }
      }
      Spacer()
      if hasMoreItems {
        moreMenu
          .opacity(done ? 0 : 1)
          .disabled(done)
      } else {
        Color.clear.frame(width: HSpacing.glassButton, height: HSpacing.glassButton)
          .accessibilityHidden(true)
      }
    }
    .padding(.horizontal, HSpacing.insetPage)
    .padding(.top, 6)
    .frame(minHeight: 54)
  }

  private var rangeRow: some View {
    PeriodPill(model.periodTitle, tinted: !model.isThisMonth) { choosingRange = true }
      .accessibilityIdentifier("review.period")
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, HSpacing.insetPage)
      .padding(.top, 8)
      .sheet(isPresented: $choosingRange) {
        PeriodSheet(app: app) { model.periodChanged() }
      }
  }

  private var hasMoreItems: Bool {
    BuildSurface.showsUnfinished || model.cards.first?.reviewReason != nil
  }

  private var moreMenu: some View {
    Menu {
      if let top = model.cards.first {
        Button("Skip for now") { skip(top) }
        if top.reviewReason != nil {
          Button("About this alert") { reasonInfo = top }
        }
        if BuildSurface.showsUnfinished, !top.fromText {
          Button("View bank email") { app.say("Coming in a later build", icon: .envelope) }
        }
      }
    } label: {
      HIconView(.more, size: HSpacing.iconGlass, color: HColor.iconGlass)
        .frame(width: HSpacing.glassButton, height: HSpacing.glassButton)
        .hGlass(in: Circle())
        .contentShape(Circle())
    }
    .accessibilityLabel("More")
    .accessibilityIdentifier("review.more")
  }

  private var progress: some View {
    let step = showsDeck ? model.position : model.total
    let share = model.total > 0 ? Double(step) / Double(model.total) : 1
    return GeometryReader { geo in
      ZStack(alignment: .leading) {
        Capsule().fill(HColor.paceTrack)
        Capsule().fill(HColor.actionAccent)
          .frame(width: geo.size.width * share)
          .hAnimation(.fillUpdate, value: step)
      }
    }
    .frame(height: HSpacing.progressHeight)
    .padding(.horizontal, HSpacing.insetPage)
    .padding(.top, 16)
    .accessibilityHidden(true)
  }

  @ViewBuilder
  private func deck(_ top: ReviewCardModel?) -> some View {
    layout(top, fit: deckFit)
      .onGeometryChange(for: CGSize.self) { $0.size } action: { deckSize = $0 }
      .background(alignment: .top) { measure(top) }
  }

  @ViewBuilder
  private func measure(_ top: ReviewCardModel?) -> some View {
    if let top, !typeSize.isAccessibilitySize, deckSize.width > 62 {
      let width = max(0, min(Self.cardWidth, deckSize.width - 62))
      ZStack(alignment: .top) {
        ReviewCardView(card: top, hidden: model.hidden, lean: nil, leanEdge: nil, strength: 0, use: {},
                       textKept: model.repeatAnswers.isKept(top.id))
          .frame(width: width)
          .fixedSize(horizontal: false, vertical: true)
          .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { idealRegular = $0 }
        ReviewCardView(card: top, hidden: model.hidden, lean: nil, leanEdge: nil, strength: 0, use: {},
                       textKept: model.repeatAnswers.isKept(top.id), compact: true)
          .frame(width: width)
          .fixedSize(horizontal: false, vertical: true)
          .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { idealCompact = $0 }
      }
      .hidden()
      .allowsHitTesting(false)
      .accessibilityHidden(true)
    }
  }

  @ViewBuilder
  private func layout(_ top: ReviewCardModel?, fit: DeckFit) -> some View {
    if fit == .scroll {
      ScrollView {
        VStack(spacing: 12) {
          pill(.up)
          stack(top, fit: fit)
          HStack(spacing: 12) {
            pill(.left)
            pill(.right)
          }
          pill(.down)
          footer(top)
        }
        .padding(.top, 20)
        .padding(.bottom, 24)
      }
    } else {
      VStack(spacing: 0) {
        pill(.up).frame(height: Self.pillSlot).padding(.top, 20)
        stack(top, fit: fit)
          .overlay {
            HStack {
              pill(.left)
              Spacer(minLength: 0)
              pill(.right)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, Self.peekDepth)
          }
          .padding(.top, 20)
          .layoutPriority(1)
        pill(.down).frame(height: Self.pillSlot).padding(.top, 22)
        Spacer(minLength: 12)
        footer(top)
          .padding(.bottom, 2)
          .overlay(alignment: .top) {
            ToastHost(app: app, placement: .bottom)
              .padding(.horizontal, -HSpacing.insetPage)
              .alignmentGuide(.top) { $0[.bottom] + 4 }
          }
      }
    }
  }

  private static let peekDepth: CGFloat = 20
  private static let pillSlot: CGFloat = 44

  private func stack(_ top: ReviewCardModel?, fit: DeckFit) -> some View {
    let count = model.cards.count
    let scrolls = fit == .scroll
    return ZStack(alignment: .top) {
      if count > 2 { peek(inset: 16, depth: 20, far: true) }
      if count > 1 { peek(inset: 8, depth: 10, far: false) }
      if let top {
        live(top, compact: fit == .compact)
          .id(top.id)
          .transition(arrival(for: top.id))
      }
      ForEach(flights) { flight in
        FlyingCard(flight: flight, hidden: model.hidden, motion: motion) {
          flights.removeAll { $0.id == flight.id }
        }
      }
    }
    .frame(maxWidth: Self.cardWidth,
           minHeight: scrolls ? (typeSize.isAccessibilitySize ? Self.cardHeight : nil) : (fit == .compact ? Self.compactFloor : 300),
           maxHeight: scrolls ? .infinity : Self.cardHeight)
    .fixedSize(horizontal: false, vertical: scrolls)
    .padding(.bottom, Self.peekDepth)
    .padding(.horizontal, 31)
    .animation(motion.animation(.cardNext), value: top?.id)
    .animation(motion.animation(.fade), value: count)
  }

  static let cardWidth: CGFloat = 340
  static let cardHeight: CGFloat = 430

  private func peek(inset: CGFloat, depth: CGFloat, far: Bool) -> some View {
    RoundedRectangle(cornerRadius: HRadius.reviewCard, style: .continuous)
      .fill(HColor.surfacePrimary)
      .shadow(color: .black.opacity(0.03), radius: 1, y: 1)
      .shadow(color: .black.opacity(far ? 0.04 : 0.05), radius: far ? 8 : 10, y: far ? 6 : 8)
      .padding(.horizontal, inset)
      .offset(y: depth)
      .accessibilityHidden(true)
      .transition(.opacity)
  }

  private func live(_ card: ReviewCardModel, compact: Bool) -> some View {
    let lean = leanEdge
    let asksText = model.repeatAnswers.asks(card)
    return ReviewCardView(
      card: card, hidden: model.hidden, lean: lean.map(choice(for:)), leanEdge: lean, strength: leanStrength,
      use: { use(card) },
      merge: { resolveCopy(card, merge: true) },
      keepBoth: { resolveCopy(card, merge: false) },
      reason: { reasonInfo = card },
      samePayment: { archive(card) },
      keepText: { keepText(card) },
      textKept: model.repeatAnswers.isKept(card.id),
      compact: compact,
      actions: {
        if card.copyLine != nil {
          Button(card.samePurchase ? "Same purchase" : "Merge") { resolveCopy(card, merge: true) }
          Button("Keep both") { resolveCopy(card, merge: false) }
        }
        if asksText {
          Button("Same payment, archive it") { archive(card) }
          Button("Keep both, sort it") { keepText(card) }
        }
        ForEach(ReviewChoice.allCases, id: \.self) { c in
          Button(c.label(isIncome: card.isIncome)) { send(card, c) }
        }
        if model.repeatAnswers.allowsUse(card), card.copyLine == nil, let s = card.suggestion {
          Button("Use \(s.name)") { use(card) }
        }
        Button("Skip for now") { skip(card) }
        if card.reviewReason != nil {
          Button("About this alert") { reasonInfo = card }
        }
      }
    )
    .modifier(LiveCard(drag: drag, tilt: tilt, gesture: dragGesture(card), passive: deckFit == .scroll || held != nil))
    .accessibilityIdentifier("review.card")
  }

  private var tilt: Double {
    if motion.isStill { return 0 }
    switch held {
    case .right: return HMotion.commitTilt
    case .left: return -HMotion.commitTilt
    case .up, .down: return 0
    case nil: return SwipePhysics.tilt(dx: drag.width, atCommit: HMotion.commitTilt)
    }
  }

  private var leanEdge: SwipeEdge? {
    if let held { return held }
    guard drag != .zero else { return nil }
    return SwipePhysics.preview(dx: drag.width, dy: drag.height)
  }

  private var leanStrength: Double {
    held != nil ? 1 : SwipePhysics.strength(dx: drag.width, dy: drag.height)
  }

  private func arrival(for id: String) -> AnyTransition {
    if motion.settled { return .identity }
    if motion.reduceMotion { return .asymmetric(insertion: .opacity, removal: .identity) }
    if let edge = departures[id] {
      let far = Flight.target(edge, width: Self.cardWidth, height: Self.cardHeight)
      return .asymmetric(insertion: .offset(far).combined(with: .opacity), removal: .identity)
    }
    return .asymmetric(insertion: motion.transition(.cardNext), removal: .identity)
  }

  private func choice(for edge: SwipeEdge) -> ReviewChoice {
    SwipePhysics.choice(for: edge, needOnRight: model.needOnRight)
  }

  private func edge(for choice: ReviewChoice) -> SwipeEdge {
    SwipePhysics.edge(for: choice, needOnRight: model.needOnRight)
  }

  @ViewBuilder
  private func pill(_ edge: SwipeEdge) -> some View {
    let top = model.cards.first
    if Self.hidesPill(asking: top.map(model.repeatAnswers.holdsPills) ?? false, leaning: leanEdge == edge || held == edge) {
      Color.clear.frame(width: 1, height: Self.pillSlot).accessibilityHidden(true)
    } else {
      livePill(edge)
    }
  }

  private func livePill(_ edge: SwipeEdge) -> some View {
    let choice = choice(for: edge)
    let active = crossed == edge || held == edge
    let waking = !active && leanEdge == edge ? leanStrength : 0
    let top = model.cards.first
    let label = choice.label(isIncome: top?.isIncome == true)
    return Button {
      if let top { send(top, choice) }
    } label: {
      DirectionPillLabel(choice: choice, label: label, edge: edge, active: active)
    }
    .buttonStyle(HPressStyle(in: Capsule()))
    .scaleEffect(motion.isStill ? 1 : 1 + 0.06 * waking)
    .hAnimation(.thumbSlide, value: active)
    .opacity(model.picking == nil ? 1 : 0)
    .hAnimation(.fade, value: model.picking == nil)
    .disabled(model.cards.isEmpty)
    .accessibilityLabel("Sort as \(label)")
    .accessibilityIdentifier("review.pill.\(choice.rawValue)")
  }

  static func hidesPill(asking: Bool, leaning: Bool) -> Bool { asking && !leaning }

  private func footer(_ top: ReviewCardModel?) -> some View {
    HStack(spacing: 0) {
      footerLink("Skip for now", id: "review.skip") {
        if let top { skip(top) }
      }
      if BuildSurface.showsUnfinished, top?.fromText != true {
        HColor.borderSubtle.frame(width: 1, height: 20)
        Button {
          app.say("Coming in a later build", icon: .envelope)
        } label: {
          HStack(spacing: 6) {
            PathGlyph(PathGlyph.envelope, size: 18, color: HColor.textLink, stroke: 1.9)
            Text("View bank email").hType(.callout.weight(.semibold)).foregroundStyle(HColor.textLink)
          }
          .frame(maxWidth: .infinity, minHeight: HSpacing.targetMinimum)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("review.viewEmail")
      }
    }
    .disabled(top == nil)
    .padding(.horizontal, HSpacing.insetPage)
    .opacity(model.picking == nil ? 1 : 0)
    .hAnimation(.fade, value: model.picking == nil)
  }

  private func footerLink(_ title: String, id: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .hType(.callout.weight(.semibold))
        .foregroundStyle(HColor.textLink)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, minHeight: HSpacing.targetMinimum)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier(id)
  }

  private func dragGesture(_ card: ReviewCardModel) -> some Gesture {
    DragGesture(minimumDistance: 6)
      .updating($touched) { _, state, _ in state = card.id }
      .onChanged { value in
        if model.holding != card.id { model.holding = card.id }
        drag = value.translation
        let past = SwipePhysics.pastCommit(dx: drag.width, dy: drag.height)
        if past != crossed {
          if past != nil { tap += 1 }
          crossed = past
        }
      }
      .onEnded { value in
        let edge = SwipePhysics.commit(
          dx: value.translation.width, dy: value.translation.height,
          vx: value.velocity.width, vy: value.velocity.height)
        guard let edge else {
          withAnimation(motion.animation(.cardReturn)) {
            drag = .zero
            crossed = nil
          }
          model.holding = nil
          return
        }
        if crossed != edge { tap += 1 }
        crossed = nil
        holdToward(edge, animated: true)
        model.pick(card.id, choice(for: edge))
      }
  }

  private func released() {
    guard model.picking == nil, held == nil else { return }
    model.holding = nil
    guard drag != .zero || crossed != nil else { return }
    withAnimation(motion.animation(.cardReturn)) {
      drag = .zero
      crossed = nil
    }
  }

  private func send(_ card: ReviewCardModel, _ choice: ReviewChoice) {
    tap += 1
    model.holding = card.id
    holdToward(edge(for: choice), animated: true)
    model.pick(card.id, choice)
  }

  private func holdToward(_ edge: SwipeEdge, animated: Bool) {
    let lean: CGFloat = motion.reduceMotion ? 0 : 40
    let pose: CGSize = switch edge {
    case .left: CGSize(width: -lean, height: 0)
    case .right: CGSize(width: lean, height: 0)
    case .up: CGSize(width: 0, height: -lean)
    case .down: CGSize(width: 0, height: lean)
    }
    withAnimation(animated ? motion.animation(.cardReturn) : nil) {
      held = edge
      drag = pose
    }
  }

  private func sortPicked(_ pick: ReviewPick, into category: CategoryID, alwaysUse: Bool, project: ProjectID?) {
    pendingSort = PendingSort(pick: pick, into: .category(category), alwaysUse: alwaysUse, project: project)
    model.picking = nil
  }

  private func createPicked(
    _ pick: ReviewPick, name: String, glyph: Glyph, alwaysUse: Bool, project: ProjectID?
  ) -> String? {
    if let why = model.newCategoryRefusal(pick.card.id, pick.choice, name: name, glyph: glyph) { return why }
    pendingSort = PendingSort(
      pick: pick, into: .newCategory(name: name, glyph: glyph), alwaysUse: alwaysUse, project: project)
    model.picking = nil
    return nil
  }

  private func pickClosed() {
    if let card = pendingMerge {
      pendingMerge = nil
      resolveCopy(card, merge: true)
      return
    }
    if let p = pendingSort {
      pendingSort = nil
      let edge = held ?? edge(for: p.pick.choice)
      file(p.pick.card, toward: edge, as: p.pick.choice.label, chime: true) {
        switch p.into {
        case .category(let category):
          model.sort(p.pick.card.id, into: category, alwaysUse: p.alwaysUse, project: p.project)
        case .newCategory(let name, let glyph):
          model.createAndSort(
            p.pick.card.id, p.pick.choice, name: name, glyph: glyph, alwaysUse: p.alwaysUse, project: p.project)
        }
      }
      return
    }
    model.holding = nil
    guard held != nil else { return }
    withAnimation(motion.animation(.cardReturn)) {
      drag = .zero
      held = nil
    }
  }

  private func use(_ card: ReviewCardModel) {
    guard model.repeatAnswers.allowsUse(card), let s = card.suggestion else { return }
    tap += 1
    file(card, toward: edge(for: ReviewChoice(filing: s.bucket)), as: s.name, chime: true) {
      model.useSuggestion(card.id, shown: s.id)
    }
  }

  private func resolveCopy(_ card: ReviewCardModel, merge: Bool) {
    tap += 1
    if card.samePurchase {
      file(card, toward: nil, as: merge ? "Same purchase" : "Kept both") {
        model.resolveSamePurchase(card.id, same: merge)
      }
      return
    }
    file(card, toward: nil, as: merge ? "Merged" : "Kept both") {
      model.resolveCopy(card.id, merge: merge)
    }
  }

  private func archive(_ card: ReviewCardModel) {
    tap += 1
    file(card, toward: nil, as: nil) { model.archive(card.id) }
  }

  private func keepText(_ card: ReviewCardModel) {
    model.keepText(card.id)
    announce("Kept both. Sort it as usual.")
  }

  private func reasonInfoClosed() {
    if let copy = pendingCopy {
      pendingCopy = nil
      resolveCopy(copy.card, merge: copy.merge)
      return
    }
    guard let card = pendingArchive else { return }
    pendingArchive = nil
    file(card, toward: nil, as: nil) { model.archive(card.id) }
  }

  private func skip(_ card: ReviewCardModel) {
    file(card, toward: nil, as: nil) {
      model.skip(card.id)
      return true
    }
  }

  private func file(
    _ card: ReviewCardModel, toward edge: SwipeEdge?, as filedAs: String?, chime: Bool = false, _ edit: () -> Bool
  ) {
    let from = drag
    let tilt = tilt
    var done = false
    withAnimation(motion.animation(.cardNext)) {
      done = edit()
      model.holding = nil
      if done {
        drag = .zero
        held = nil
        crossed = nil
      }
    }
    guard done else {
      withAnimation(motion.animation(.cardReturn)) {
        drag = .zero
        held = nil
      }
      return
    }
    if chime { SortSound.shared.play() }
    if let edge { departures[card.id] = edge }
    if !motion.settled {
      flights.append(Flight(card: card, from: from, tilt: tilt, edge: edge, compact: deckFit == .compact))
    }
    if let filedAs { announce(model.filedAnnouncement(filedAs)) }
  }

  private func announce(_ text: String) {
    var line = AttributedString(text)
    line.accessibilitySpeechAnnouncementPriority = .low
    AccessibilityNotification.Announcement(line).post()
  }
}

private struct LiveCard<G: Gesture>: ViewModifier {
  let drag: CGSize
  let tilt: Double
  let gesture: G
  let passive: Bool

  func body(content: Content) -> some View {
    content
      .offset(drag)
      .rotationEffect(.degrees(tilt))
      .gesture(gesture, including: passive ? .subviews : .all)
      .accessibilityElement(children: .contain)
  }
}

struct Flight: Identifiable {
  let id = UUID()
  let card: ReviewCardModel
  let from: CGSize
  let tilt: Double
  let edge: SwipeEdge?
  var compact = false

  static func target(_ edge: SwipeEdge, width: CGFloat, height: CGFloat) -> CGSize {
    switch edge {
    case .left: CGSize(width: -width * HMotion.cardFlyOut, height: 0)
    case .right: CGSize(width: width * HMotion.cardFlyOut, height: 0)
    case .up: CGSize(width: 0, height: -height * HMotion.cardFlyOut)
    case .down: CGSize(width: 0, height: height * HMotion.cardFlyOut)
    }
  }
}

private struct FlyingCard: View {
  let flight: Flight
  let hidden: Bool
  let motion: MotionPolicy
  let landed: () -> Void
  @State private var gone = false
  @State private var faded = false

  var body: some View {
    ReviewCardView(card: flight.card, hidden: hidden, lean: nil, leanEdge: nil, strength: 0, use: {},
                   compact: flight.compact)
      .scaleEffect(gone && flight.edge == nil && travels ? HMotion.nextCardScale : 1)
      .offset(gone && travels ? offset : flight.from)
      .rotationEffect(.degrees(gone && travels ? angle : flight.tilt))
      .opacity(faded ? 0 : 1)
      .allowsHitTesting(false)
      .accessibilityHidden(true)
      .onAppear(perform: fly)
  }

  private func fly() {
    guard flight.edge != nil, travels, let curve = motion.curve(.cardCommit) else {
      withAnimation(motion.animation(flight.edge == nil ? .fade : .cardCommit)) {
        gone = true
        faded = true
      } completion: {
        landed()
      }
      return
    }
    let length = curve.nominalDuration
    withAnimation(HMotion.Curve.linear(duration: length).animation) { gone = true }
    withAnimation(HMotion.easeInOut(length)) {
      faded = true
    } completion: {
      landed()
    }
  }

  private var travels: Bool { !motion.reduceMotion }

  private var offset: CGSize {
    guard let edge = flight.edge else { return flight.from }
    let t = Flight.target(edge, width: ReviewDeckView.cardWidth, height: ReviewDeckView.cardHeight)
    return CGSize(width: flight.from.width + t.width, height: flight.from.height + t.height)
  }

  private var angle: Double {
    switch flight.edge {
    case .left: -HMotion.cardFlyTilt
    case .right: HMotion.cardFlyTilt
    case .up, .down, nil: flight.tilt
    }
  }
}

private struct DirectionPillLabel: View {
  let choice: ReviewChoice
  let label: String
  let edge: SwipeEdge
  let active: Bool
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  var body: some View {
    let hue = choice.pillHue
    let arrowTrails = edge == .right
    HStack(spacing: 8) {
      if !arrowTrails { arrow(hue) }
      HStack(spacing: 6) {
        Circle().fill(hue.dotGradient).frame(width: 10, height: 10)
          .overlay { if active { Circle().strokeBorder(hue.ink.opacity(0.12), lineWidth: 1) } }
        Text(label)
          .hType(active ? .callout.weight(.bold) : .subheadline.weight(.semibold))
          .foregroundStyle(active ? hue.ink : HColor.textPrimary)
          .fixedSize()
      }
      if arrowTrails { arrow(hue) }
    }
    .padding(.leading, arrowTrails ? (active ? 18 : 16) : (active ? 18 : 12))
    .padding(.trailing, arrowTrails ? (active ? 14 : 12) : (active ? 14 : 16))
    .frame(minHeight: active ? 48 : 44)
    .background {
      if active {
        Capsule().fill(hue.start.opacity(reduceTransparency ? 1 : 0.9))
          .overlay { Capsule().strokeBorder(hue.end, lineWidth: 1) }
          .shadow(color: hue.ink.opacity(0.16), radius: 11, y: 8)
          .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
      }
    }
    .hGlass(in: Capsule(), interactive: false)
    .contentShape(Capsule())
  }

  private func arrow(_ hue: Hue) -> some View {
    PathGlyph(PathGlyph.arrow(edge), size: 18, color: active ? hue.ink : HColor.iconGlass, stroke: active ? 2.4 : 2.2)
  }
}

struct ReviewCardView<Actions: View>: View {
  let card: ReviewCardModel
  let hidden: Bool
  let lean: ReviewChoice?
  let leanEdge: SwipeEdge?
  let strength: Double
  let use: () -> Void
  var merge: () -> Void = {}
  var keepBoth: () -> Void = {}
  var reason: () -> Void = {}
  var samePayment: () -> Void = {}
  var keepText: () -> Void = {}
  var textKept = false
  var compact = false
  @ViewBuilder let actions: () -> Actions
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 0) {
        identity
        Spacer(minLength: compact ? 12 : 24)
        amount
      }
      .padding(.top, compact ? 16 : 24)
      .padding(.horizontal, 24)
      .padding(.bottom, compact ? 14 : 22)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(spoken)
      .accessibilityActions { actions() }
      .accessibilityIdentifier("review.merchant")
      Group {
        if let line = card.copyLine {
          copyStrip(line)
        } else if card.reviewReason == .mayRepeat, !textKept {
          sameTextStrip
        } else if let r = card.reviewReason, r != .mayRepeat {
          reasonStrip(r)
        } else if let s = card.suggestion {
          strip(s)
        }
      }
      .layoutPriority(1)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .background(HColor.surfacePrimary)
    .overlay { glow }
    .clipShape(RoundedRectangle(cornerRadius: HRadius.reviewCard, style: .continuous))
    .background {
      RoundedRectangle(cornerRadius: HRadius.reviewCard, style: .continuous)
        .fill(HColor.surfacePrimary)
        .shadow(color: .black.opacity(0.04), radius: 2, y: 2)
        .shadow(color: .black.opacity(0.11), radius: 22, y: 18)
        .shadow(color: (lean?.pillHue.end ?? .clear).opacity(0.9 * strength), radius: 20,
                x: glowShift.width, y: glowShift.height)
    }
  }

  private var identity: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top) {
        if card.copyLine == nil, !card.isNewMerchant, let s = card.suggestion {
          CategoryDisc(hue: s.hue, icon: s.glyph.icon, size: compact ? .s40 : .s56)
        } else {
          MerchantMonogram(letter: card.monogram, size: compact ? 40 : 56)
        }
        Spacer(minLength: 8)
        if let r = card.reviewReason {
          Button(action: reason) {
            InfoChip(r.label, style: ReviewReasonStyle.chip)
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("review.reason.\(r.rawValue)")
        } else if card.isNewMerchant {
          InfoChip("New merchant", style: .evidence)
        }
      }
      VStack(alignment: .leading, spacing: 8) {
        Text(card.merchant)
          .hType(.section)
          .foregroundStyle(HColor.textPrimary)
          .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
          .fixedSize(horizontal: false, vertical: true)
        if !compact, let raw = card.rawMerchant {
          InfoChip(raw, style: .rawText)
            .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
        }
      }
      .padding(.top, compact ? 12 : 16)
    }
  }

  private var amount: some View {
    VStack(alignment: .leading, spacing: 4) {
      MoneyText(card.amount, figure: compact ? .large : .hero, unit: .unit, hidden: hidden,
                color: card.isIncome ? HColor.moneyIn : HColor.moneyOut,
                unitColor: card.isIncome ? HColor.moneyIn : HColor.textPrimary, unitGap: 6,
                sign: card.isIncome ? .income : .none)
      Text(card.meta).hType(.footnote).foregroundStyle(HColor.textSecondary)
        .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
        .fixedSize(horizontal: false, vertical: typeSize.isAccessibilitySize)
    }
  }

  private func copyStrip(_ line: String) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(line)
        .hType(.subheadline.weight(.semibold))
        .foregroundStyle(HColor.textPrimary)
        .lineLimit(typeSize.isAccessibilitySize ? nil : 3)
        .truncationMode(.middle)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("review.copy")
      HStack(spacing: 12) {
        Button("Keep both", action: keepBoth)
          .buttonStyle(.pill(.secondary, size: .small))
          .accessibilityIdentifier("review.keepBoth")
        Button(card.samePurchase ? "Same purchase" : "Merge", action: merge)
          .buttonStyle(.pill(.primary, size: .small))
          .accessibilityIdentifier(card.samePurchase ? "review.same" : "review.merge")
      }
    }
    .padding(.top, 14)
    .padding(.bottom, 14)
    .padding(.leading, 24)
    .padding(.trailing, 16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(HColor.reviewSuggestionSurface)
    .overlay(alignment: .top) { HColor.borderSubtle.frame(height: 1) }
  }

  private var sameTextStrip: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(card.reasonLine ?? TxnReviewReason.mayRepeat.detail)
        .hType(.subheadline.weight(.semibold))
        .foregroundStyle(HColor.textPrimary)
        .lineLimit(typeSize.isAccessibilitySize ? nil : 3)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("review.sameText")
      ReflowingRow(spacing: 12) {
        Button("Keep both, sort it", action: keepText)
          .buttonStyle(.pill(.secondary, size: .small))
          .accessibilityIdentifier("review.keepText")
      } trailing: {
        Button("Same payment, archive it", action: samePayment)
          .buttonStyle(.pill(.primary, size: .small))
          .accessibilityIdentifier("review.samePayment")
      }
    }
    .padding(.top, 14)
    .padding(.bottom, 14)
    .padding(.leading, 24)
    .padding(.trailing, 16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(HColor.reviewSuggestionSurface)
    .overlay(alignment: .top) { HColor.borderSubtle.frame(height: 1) }
  }

  private func reasonStrip(_ r: TxnReviewReason) -> some View {
    let ink = ReviewReasonStyle.ink
    return Button(action: reason) {
      HStack(spacing: 12) {
        Circle().fill(HColor.surfacePrimary).frame(width: 32, height: 32)
          .overlay { HIconView(ReviewReasonStyle.icon(r), size: 16, color: ink, strokeWidth: 2) }
        Text(card.reasonLine ?? r.detail)
          .hType(.footnote.weight(.medium))
          .foregroundStyle(ink)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
        HIconView(.chevronRight, size: 16, color: ink)
      }
      .padding(.vertical, 14)
      .padding(.leading, 24)
      .padding(.trailing, 16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(ReviewReasonStyle.surface)
      .overlay(alignment: .top) { HColor.borderSubtle.frame(height: 1) }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(r.title). \(card.reasonLine ?? r.detail)")
    .accessibilityHint("Explains this and your choices")
    .accessibilityAddTraits(.isButton)
    .accessibilityIdentifier("review.reasonStrip.\(r.rawValue)")
  }

  private func strip(_ s: CategoryOption) -> some View {
    let layout = typeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
      : AnyLayout(HStackLayout(spacing: 12))
    return layout {
      HStack(spacing: 12) {
        CategoryDisc(hue: s.hue, icon: s.glyph.icon, size: .s32)
        VStack(alignment: .leading, spacing: 2) {
          Text("Looks like \(s.name)")
            .hType(.subheadline.weight(.semibold))
            .foregroundStyle(HColor.textPrimary)
          if let by = card.suggestedBy {
            Text(by)
              .hType(.footnote)
              .foregroundStyle(HColor.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("review.suggestedBy")
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .accessibilityElement(children: .combine)
      Button("Use", action: use)
        .buttonStyle(.pill(.primary, size: .small))
        .accessibilityLabel("Use \(s.name)")
        .accessibilityIdentifier("review.use")
    }
    .padding(.top, 14)
    .padding(.bottom, 14)
    .padding(.leading, 24)
    .padding(.trailing, 16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(HColor.reviewSuggestionSurface)
    .overlay(alignment: .top) { HColor.borderSubtle.frame(height: 1) }
  }

  @ViewBuilder private var glow: some View {
    if let lean, let leanEdge, strength > 0 {
      let hue = lean.pillHue
      let stops = Gradient(stops: [
        .init(color: hue.end.opacity(0.58), location: 0),
        .init(color: hue.start.opacity(0.26), location: 0.5),
        .init(color: hue.start.opacity(0), location: 1),
      ])
      let (from, to, alignment): (UnitPoint, UnitPoint, Alignment) = switch leanEdge {
      case .right: (.trailing, .leading, .trailing)
      case .left: (.leading, .trailing, .leading)
      case .up: (.top, .bottom, .top)
      case .down: (.bottom, .top, .bottom)
      }
      let horizontal = leanEdge == .left || leanEdge == .right
      Rectangle().fill(.linearGradient(stops.colorSpace(.perceptual), startPoint: from, endPoint: to))
        .frame(width: horizontal ? 170 : nil, height: horizontal ? nil : 170)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .opacity(strength)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
  }

  private var glowShift: CGSize {
    switch leanEdge {
    case .right: CGSize(width: 18, height: 4)
    case .left: CGSize(width: -18, height: 4)
    case .up: CGSize(width: 0, height: -14)
    case .down: CGSize(width: 0, height: 22)
    case nil: .zero
    }
  }

  private var spoken: String {
    let amount = hidden
      ? "Amount hidden"
      : (card.isIncome ? "plus " : "") + "\(card.amount.currency) \(MoneyFormat.string(card.amount.minor))"
    var line = "\(card.merchant), \(amount), \(card.spokenWhen)."
    if let copy = card.copyLine {
      line += " \(copy)."
    } else if let r = card.reviewReason {
      line += " \(card.reasonLine ?? r.title)."
    }
    if card.isNewMerchant { line += " New merchant." }
    if let raw = card.rawMerchant { line += " Bank text: \(raw)." }
    if card.copyLine == nil, let s = card.suggestion {
      line += " Looks like \(s.name)."
      if card.reviewReason == nil, let by = card.suggestedBy { line += " \(by)." }
    }
    return line
  }
}

extension ReviewCardView where Actions == EmptyView {
  init(card: ReviewCardModel, hidden: Bool, lean: ReviewChoice?, leanEdge: SwipeEdge?, strength: Double,
       use: @escaping () -> Void, textKept: Bool = false, compact: Bool = false)
  {
    self.init(card: card, hidden: hidden, lean: lean, leanEdge: leanEdge, strength: strength, use: use,
              textKept: textKept, compact: compact, actions: { EmptyView() })
  }
}

#if HASALA_MOCKS
  #Preview("Review · Deck") {
    let app = AppModel(store: InMemoryLedger())
    ReviewDeckView(app: app, model: ReviewViewModel(app: app))
  }
#endif
