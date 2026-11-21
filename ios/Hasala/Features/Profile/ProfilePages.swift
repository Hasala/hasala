import HasalaDesign
import HasalaModels
import SwiftUI

struct HelpPage: View {
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        HListCard {
          ProfileInfoRow(icon: .phone, title: "Send feedback from TestFlight",
                         text: "Screenshot, then tap Share Beta Feedback. Or in TestFlight \u{203A} Hasala, tap Send Beta Feedback.")
          HDivider(inset: .icon52)
          ProfileInfoRow(icon: .chat, title: "Talk to a person",
                         text: "Tell us what isn't working or what you'd change. A person reads every email.")
        }
        SupportLink(lead: "Questions, or something not working?", identifier: "help.email", web: false)
        WebLink(title: "Help and support", url: "https://hasala.app/support", identifier: "help.support")
        WebLink(title: "Privacy policy", url: "https://hasala.app/privacy", identifier: "help.privacy")
      }
      .padding(.horizontal, HSpacing.sheetPadding)
      .padding(.top, 8)
      .padding(.bottom, 48)
    }
    .background(HColor.sheetSurfaceLarge)
    .navigationTitle("Get help")
    .navigationBarTitleDisplayMode(.inline)
  }
}

struct NotificationSettingsPage: View {
  let model: any ProfileModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        HListCard {
          ForEach(Array(DevicePrefs.NotificationLevel.allCases.enumerated()), id: \.element) { index, level in
            if index > 0 { HDivider(inset: .text16) }
            let selected = model.snapshot.prefs.notifications == level
            Button { model.setNotifications(level) } label: {
              HListRow(title: level.label, trailing: .check(selected))
            }
            .buttonStyle(HRowPressStyle())
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("notifications.\(level.rawValue)")
          }
        }
        Text("Important only skips new transactions under AED 100 and the daily sorting nudge.")
          .hType(.footnote).foregroundStyle(HColor.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
          .infoTip("The Lock Screen stays generic unless you change it.", about: "the Lock Screen")
          .padding(.horizontal, 4)
      }
      .padding(.horizontal, HSpacing.sheetPadding)
      .padding(.top, 8)
      .padding(.bottom, 48)
    }
    .background(HColor.sheetSurfaceLarge)
    .navigationTitle("Notifications")
    .navigationBarTitleDisplayMode(.inline)
  }
}
