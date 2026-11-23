import SwiftUI

struct BillsScreen: View {
  @Bindable var app: AppModel
  var showsToast = true
  @State private var model: BillsViewModel

  init(app: AppModel, showsToast: Bool = true) {
    self.app = app
    self.showsToast = showsToast
    _model = State(initialValue: BillsViewModel(app: app))
  }

  var body: some View { BillsView(app: app, model: model, showsToast: showsToast) }
}
