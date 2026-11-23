import HasalaDesign
import SwiftUI

@main
struct HasalaApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

  init() {
    HasalaFonts.register()
    BackgroundScheduler.shared.register()
  }

  var body: some Scene {
    WindowGroup {
      RootView()
        .preferredColorScheme(.light)
        .tint(HColor.actionAccent)
        .environment(\.hIncreasedContrast, BuildSurface.forcesIncreasedContrast)
    }
  }
}
