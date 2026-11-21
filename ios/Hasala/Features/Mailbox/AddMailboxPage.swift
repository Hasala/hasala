import HasalaDesign
import HasalaModels
import SwiftUI

struct AddMailboxPage: View {
  @Bindable var app: AppModel

  var body: some View {
    if let mailbox = app.mailbox {
      if mailbox.connectable.count == 1, let only = mailbox.connectable.first {
        ConnectMailPage(app: app, provider: only)
      } else {
        let change = mailbox.holdsOneLink && mailbox.mailboxes.contains { $0.state != .disconnected }
        ChooseEmailSheet(mailbox: mailbox, title: change ? .change : .addMailbox) {
          app.router.profile.append(.connectMail($0))
        }
      }
    }
  }
}
