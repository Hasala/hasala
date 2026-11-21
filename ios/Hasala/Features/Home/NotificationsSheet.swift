import HasalaDesign
import HasalaModels
import SwiftUI

struct NotificationsSheet: View {
  @Bindable var app: AppModel
  @State private var model: HomeViewModel
  @State private var afterClose: (@MainActor () -> Void)?
  @Environment(\.dismiss) private var dismiss

  init(app: AppModel) {
    self.app = app
    _model = State(initialValue: HomeViewModel(app: app))
  }

  private var bell: Bell { model.bell }
  private var hidden: Bool { app.amountsHidden }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 28) {
          if bell.needsALook.isEmpty {
            NothingNeedsYou()
              .accessibilityIdentifier("bell.allClear")
          } else {
            section("Needs a look", bell.needsALook)
          }
          if !bell.earlier.isEmpty {
            section("Earlier", bell.earlier)
          }
          if BuildSurface.showsUnfinished {
            Button { app.router.open(.profile, profile: [.notifications]) } label: {
              Text("Notification settings")
                .hType(.subheadline.weight(.medium))
                .foregroundStyle(HColor.textLink)
                .frame(maxWidth: .infinity, minHeight: HSpacing.targetMinimum)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, -6)
            .accessibilityIdentifier("bell.settings")
          }
        }
        .padding(.horizontal, HSpacing.insetPage)
        .padding(.top, 15)
        .padding(.bottom, 40)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bell.sheet")
      }
      .background(HColor.sheetSurfaceLarge)
      .navigationTitle("Notifications")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        SheetCloseButton(identifier: "bell.close") { dismiss() }
        ToolbarItem(placement: .principal) {
          Text("Notifications").hType(.headline).foregroundStyle(HColor.textPrimary)
            .accessibilityAddTraits(.isHeader)
        }
      }
      .overlay(alignment: .bottom) { ToastHost(app: app, placement: .bottom) }
    }
    .presentationDetents([.large])
    .presentationDragIndicator(.visible)
    .presentationCornerRadius(HRadius.sheetLarge)
    .presentationBackground(HColor.sheetSurfaceLarge)
    .onAppear { model.markAllRead() }
    .onDisappear {
      let next = afterClose
      afterClose = nil
      next?()
    }
  }

  private func section(_ title: String, _ items: [NotificationItem]) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      heading(title)
      HListCard {
        ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
          if i > 0 { HDivider(inset: .disc68) }
          Button { open(item) } label: { NotificationRow(item, hidden: hidden) }
            .buttonStyle(HRowPressStyle())
            .accessibilityIdentifier("bell.row.\(item.id)")
        }
      }
    }
  }

  private func heading(_ title: String) -> some View {
    Text(title).hType(.section).foregroundStyle(HColor.textPrimary)
      .accessibilityAddTraits(.isHeader)
  }

  private func open(_ item: NotificationItem) {
    afterClose = model.openNotification(item.destination)
  }
}
