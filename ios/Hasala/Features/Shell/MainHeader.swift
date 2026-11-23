import HasalaDesign
import HasalaModels
import SwiftUI

struct MainHeader: ToolbarContent {
  static let iconColor = HColor.iconGlass

  var barTitle: String? = nil
  let amountsHidden: Bool
  let unread: Int
  let avatarInitial: String
  let avatarEmail: String?
  let onToggleAmounts: () -> Void
  let onSearch: () -> Void
  let onNotifications: () -> Void
  let onProfile: () -> Void

  var body: some ToolbarContent {
    ToolbarItem(placement: .topBarLeading) {
      GlassAvatarButton(initial: avatarInitial, email: avatarEmail, label: "Your profile", action: onProfile)
        .accessibilityIdentifier("header.profile")
    }
    .sharedBackgroundVisibility(.hidden)
    ToolbarItem(placement: .principal) {
      BarCentre(title: barTitle)
    }
    .sharedBackgroundVisibility(.hidden)
    ToolbarItem(placement: .topBarTrailing) {
      GlassButtonPair {
        GlassIconButton(amountsHidden ? .eyeSlash : .eye, label: amountsHidden ? "Show amounts" : "Hide amounts",
                        action: onToggleAmounts)
          .accessibilityIdentifier("header.hideAmounts")
        GlassIconButton(.magnifier, label: "Search", action: onSearch)
          .accessibilityIdentifier("header.search")
        GlassIconButton(.bell, label: Bell.label(unread),
                        badge: unread, action: onNotifications)
          .accessibilityIdentifier("header.notifications")
      }
    }
    .sharedBackgroundVisibility(.hidden)
  }
}

struct BarCentre: View {
  let title: String?

  var body: some View {
    ZStack {
      if let title {
        Text(title)
          .hType(.headline)
          .foregroundStyle(HColor.textPrimary)
          .lineLimit(1)
          .accessibilityAddTraits(.isHeader)
          .accessibilityIdentifier("header.title")
          .hTransition(.fade)
      } else {
        HeaderMark()
          .hTransition(.fade)
      }
    }
    .hAnimation(.fade, value: title)
  }
}
