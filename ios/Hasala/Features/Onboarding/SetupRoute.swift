import HasalaModels

enum SetupRoute: Hashable {
  case connectError(MailProviderKind)
  case textsSetUp
  case textsTest
}
