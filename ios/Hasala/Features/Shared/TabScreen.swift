import HasalaDesign
import HasalaModels
import SwiftUI

struct TabScreen<Header: View, Content: View>: View {
  @Bindable var app: AppModel
  let title: String?
  var wash: HWash
  var spacing: CGFloat
  var titleGap: CGFloat
  @ViewBuilder let header: () -> Header
  @ViewBuilder let content: () -> Content
  @State private var titleInBar = false

  init(
    app: AppModel, title: String?,
    wash: HWash = .onTrack, spacing: CGFloat = HSpacing.gapScreenSection, titleGap: CGFloat = 10,
    @ViewBuilder header: @escaping () -> Header, @ViewBuilder content: @escaping () -> Content
  ) {
    self.app = app
    self.title = title
    self.wash = wash
    self.spacing = spacing
    self.titleGap = titleGap
    self.header = header
    self.content = content
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: spacing) {
        if let title {
          VStack(alignment: .leading, spacing: titleGap) {
            HStack(alignment: .center, spacing: 8) {
              Text(title)
                .hType(.largeTitle)
                .foregroundStyle(HColor.textPrimary)
                .accessibilityAddTraits(.isHeader)
              Spacer(minLength: 0)
              SyncStatus(syncing: app.sync.isSyncing)
            }
            header()
          }
          .padding(.horizontal, HSpacing.insetPage)
        }
        content()
          .environment(\.periodRowSyncing, title == nil ? app.sync.isSyncing : nil)
      }
      .padding(.top, 20)
      .padding(.bottom, HSpacing.scrollContentBottom)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .washBehind(wash)
    .settlesAfterRefresh()
    .onScrollGeometryChange(for: Bool.self) { geo in
      TabTitle.isInBar(contentOffset: geo.contentOffset.y, insetTop: geo.contentInsets.top)
    } action: { _, value in
      titleInBar = value
    }
    .refreshable { [app] in await app.pull() }
    .scrollEdgeEffectStyle(.soft, for: .bottom)
    .background(HColor.surfaceSecondary)
    .navigationTitle(title ?? "")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      MainHeader(
        barTitle: titleInBar ? title : nil,
        amountsHidden: app.amountsHidden,
        unread: app.bellCount,
        avatarInitial: app.avatarInitial,
        avatarEmail: app.avatarEmail,
        onToggleAmounts: { app.toggleAmountsHidden() },
        onSearch: { app.router.open(.search) },
        onNotifications: { app.router.open(.notifications) },
        onProfile: { app.showingProfile = true }
      )
    }
    .overlay(alignment: .bottom) { ToastHost(app: app) }
  }
}

nonisolated enum TabTitle {
  static let scrolledPast: CGFloat = 60

  static func isInBar(contentOffset: CGFloat, insetTop: CGFloat) -> Bool {
    contentOffset + insetTop > scrolledPast
  }
}

nonisolated enum RefreshSettle {
  static func isStuck(contentOffset: CGFloat, insetTop: CGFloat) -> Bool {
    contentOffset < -insetTop - 0.5
  }
}

private struct SettlesAfterRefresh: ViewModifier {
  @State private var position = ScrollPosition(edge: .top)
  @State private var stuck = false
  @State private var phase = ScrollPhase.idle
  @State private var settling = false
  @Environment(\.hMotion) private var policy
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    content
      .scrollPosition($position)
      .onScrollGeometryChange(for: Bool.self) { geo in
        RefreshSettle.isStuck(contentOffset: geo.contentOffset.y, insetTop: geo.contentInsets.top)
      } action: { _, value in
        stuck = value
        if !value { settling = false }
        settle()
      }
      .onScrollPhaseChange { _, value in
        phase = value
        settle()
      }
  }

  private func settle() {
    guard stuck, phase == .idle, !settling else { return }
    settling = true
    let still = policy.isStill || reduceMotion
    Task { @MainActor in
      guard stuck, phase == .idle else {
        settling = false
        return
      }
      withAnimation(still ? nil : HMotion.easeOutSoft(HMotion.sheetContent)) {
        position.scrollTo(edge: .top)
      }
    }
  }
}

extension View {
  fileprivate func settlesAfterRefresh() -> some View {
    modifier(SettlesAfterRefresh())
  }
}

struct SyncStatus: View {
  let syncing: Bool

  var body: some View {
    ZStack(alignment: .trailing) {
      if syncing {
        SyncStatusLabel()
          .hTransition(.fade)
      }
    }
    .hAnimation(.fade, value: syncing)
  }
}

private struct SyncStatusLabel: View {
  var compact = false

  var body: some View {
    HStack(spacing: 6) {
      ProgressView().controlSize(.mini)
      if !compact {
        Text("Updating…").hType(.footnote).foregroundStyle(HColor.textSecondary)
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(SyncActivity.startedMessage)
    .accessibilityIdentifier("sync.status")
  }
}

extension EnvironmentValues {
  @Entry var periodRowSyncing: Bool? = nil
}

struct BackToThisMonthLink: View {
  var tint: Color = HColor.textLink
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text("Back to this month")
    }
    .buttonStyle(.inlineLink(color: tint))
  }
}

struct PeriodRowTrailing<Link: View>: View {
  var hasLink: Bool
  @ViewBuilder let link: () -> Link
  @Environment(\.periodRowSyncing) private var syncing

  var body: some View {
    HStack(spacing: 12) {
      if syncing == true {
        SyncStatusLabel(compact: hasLink)
          .frame(minHeight: HSpacing.targetMinimum)
          .hTransition(.fade)
      }
      if hasLink { link() }
    }
    .hAnimation(.fade, value: syncing)
  }
}

extension TabScreen where Header == EmptyView {
  init(
    app: AppModel, title: String?,
    wash: HWash = .onTrack, spacing: CGFloat = HSpacing.gapScreenSection, titleGap: CGFloat = 10,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.init(app: app, title: title, wash: wash, spacing: spacing,
              titleGap: titleGap, header: { EmptyView() }, content: content)
  }
}

extension HWash {
  init(_ hue: Hue) {
    switch hue {
    case .sky: self = .onTrack
    case .sand: self = .overPace
    case .rose: self = .overBudget
    default: self = .hue(hue)
    }
  }
}
