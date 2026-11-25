import CorePrimitives
import CoreStore
import Foundation
import HasalaKeychain
import Security
import Testing

@testable import Hasala

@Suite("KeychainSecretStore on the system Keychain", .serialized)
struct KeychainSystemTests {
  private nonisolated static let userID = UserID(UUID().uuidString.lowercased())!
  private nonisolated static let writerID = WriterID("ios-" + UUID().uuidString.lowercased())!

  nonisolated static let items: [SecretItem] = [
    .session(apiHost: "keychain-system-test.invalid"),
    .accountBinding,
    .epochKey(userID: userID, epoch: 7),
    .writerKey(userID: userID, writerID: writerID),
    .approvalKey(userID: userID, writerID: writerID),
    .mailRefresh(provider: .gmail, userID: userID),
    .mailRefresh(provider: .outlook, userID: userID),
    .outlookClientState(userID: userID),
    .textKeySecret,
    .readerWordKey,
  ]

  private let store = KeychainSecretStore(accessGroup: AppEnvironment.keychainGroup)

  private func attributes(_ item: SecretItem) -> (OSStatus, [String: Any]) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: item.service,
      kSecAttrAccount as String: item.account,
      kSecUseDataProtectionKeychain as String: true,
      kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
      kSecReturnAttributes as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var out: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &out)
    return (status, out as? [String: Any] ?? [:])
  }

  private func accessible(_ item: SecretItem) -> String {
    switch item.accessibility {
    case .afterFirstUnlockThisDeviceOnly: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
    case .whenPasscodeSetThisDeviceOnly: kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly as String
    }
  }

  private func putBack(_ item: SecretItem, _ held: Data?) {
    do {
      if let held { try store.write(item, held) } else { try store.delete(item) }
    } catch {
      Issue.record("\(item.service) was not put back: \(error)")
    }
  }

  @Test("the test covers each service once")
  func coversEachService() {
    #expect(Self.items.map(\.service).sorted() == SecretItem.allServices.sorted())
  }

  @Test("write, read, update and delete through SecItem", arguments: items)
  func roundTrip(_ item: SecretItem) throws {
    let held = try store.read(item)
    defer { putBack(item, held) }
    try store.delete(item)
    #expect(try store.read(item) == nil)

    let first = Data("first-\(item.service)".utf8)
    try store.write(item, first)
    #expect(try store.read(item) == first)
    #expect(try store.accounts(service: item.service).contains(item.account))

    let (status, found) = attributes(item)
    #expect(status == errSecSuccess)
    #expect(found[kSecAttrAccessGroup as String] as? String == AppEnvironment.keychainGroup)
    #expect(found[kSecAttrAccessible as String] as? String == accessible(item))
    #expect(found[kSecAttrSynchronizable as String] as? Bool == false)

    let second = Data("second-\(item.service)-longer".utf8)
    try store.write(item, second)
    #expect(try store.read(item) == second)
    #expect(try store.accounts(service: item.service).filter { $0 == item.account }.count == 1)

    try store.delete(item)
    #expect(try store.read(item) == nil)
    #expect(attributes(item).0 == errSecItemNotFound)
    try store.delete(item)
  }
}
