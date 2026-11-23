import HasalaDesign
import SwiftUI

struct SupportLink: View {
  var lead: String
  var identifier: String
  var web = true

  var body: some View {
    VStack(spacing: 0) {
      Link(destination: BuildSurface.supportMail) {
        VStack(spacing: 2) {
          Text(lead).foregroundStyle(HColor.textSecondary)
          Text("Email \(BuildSurface.supportEmail)").foregroundStyle(HColor.textLink)
        }
        .hType(.subheadline)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(Rectangle())
      }
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(.isLink)
      .accessibilityIdentifier(identifier)
      if web {
        Link(destination: BuildSurface.supportPage) {
          Text("Or visit hasala.app/support")
            .hType(.subheadline)
            .foregroundStyle(HColor.textLink)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("\(identifier).web")
      }
    }
    .dockLink()
  }
}
