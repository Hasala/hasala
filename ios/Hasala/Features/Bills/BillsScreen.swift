import SwiftUI

struct BillsScreen: View {
  @Bindable var app: AppModel
  @State private var model: BillsViewModel

  init(app: AppModel) {
    self.app = app
    _model = State(initialValue: BillsViewModel(app: app))
  }

  var body: some View { BillsView(app: app, model: model) }
}
