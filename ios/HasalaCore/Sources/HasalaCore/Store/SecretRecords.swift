import CorePrimitives
import CoreWire
import Foundation

public struct SessionRecord: Codable, Sendable, Hashable {
  public var token: String
  public var user_id: String
  public var pending_logout: Bool
  public var expires_at: Int64
  public var tag: String
  public var signup_email_norm: String?

  public init(token: String, userID: String, expiresAt: Int64, tag: String, pendingLogout: Bool = false) {
    self.token = token
    user_id = userID
    self.expires_at = expiresAt
    self.tag = tag
    pending_logout = pendingLogout
  }

  public static func minted(
    token: String, userID: String, expiresAt: Int64, random: some RandomSource, signupEmailNorm: String? = nil
  ) throws(PrimitivesError) -> SessionRecord {
    var record = SessionRecord(token: token, userID: userID, expiresAt: expiresAt, tag: Hex.encode(try random.bytes(8)))
    record.signup_email_norm = signupEmailNorm
    return record
  }
}

public struct AccountBinding: Codable, Sendable, Hashable {
  public var user_id: String
  public var writer_id: String
  public var api_base: String
  public var key_epoch: UInt32
  public var email_norm: String
  public var s_srv: String
  public var display_name: String?

  public init(
    userID: UserID, writerID: WriterID, apiBase: String, keyEpoch: UInt32, emailNorm: String, serverSalt: Data,
    displayName: String?
  ) {
    user_id = userID.string
    writer_id = writerID.string
    api_base = apiBase
    key_epoch = keyEpoch
    email_norm = emailNorm
    s_srv = Base64.encode(serverSalt)
    display_name = displayName
  }

  public var userID: UserID? { UserID(user_id) }
  public var writerID: WriterID? { WriterID(writer_id) }
  public var serverSalt: Data? { try? Base64.decode(s_srv) }
}

public struct Secrets: Sendable {
  public let store: any SecretStore
  public let apiHost: String

  public init(store: any SecretStore, apiHost: String) {
    self.store = store
    self.apiHost = apiHost
  }

  static func decode<T: Decodable>(_ d: Data) throws(SecretStoreError) -> T {
    do { return try JSONDecoder().decode(T.self, from: d) } catch { throw .failed(status: -1) }
  }

  static func encode(_ v: some Encodable) throws(SecretStoreError) -> Data {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys]
    do { return try e.encode(v) } catch { throw .failed(status: -1) }
  }

  public func session() throws(SecretStoreError) -> SessionRecord? {
    guard let d = try store.read(.session(apiHost: apiHost)) else { return nil }
    return try Self.decode(d)
  }

  public func activeSession() throws(SecretStoreError) -> SessionRecord? {
    guard let s = try session(), !s.pending_logout else { return nil }
    return s
  }

  public func writeSession(_ s: SessionRecord) throws(SecretStoreError) {
    try store.write(.session(apiHost: apiHost), try Self.encode(s))
  }

  public func deleteSession() throws(SecretStoreError) { try store.delete(.session(apiHost: apiHost)) }

  public func binding() throws(SecretStoreError) -> AccountBinding? {
    guard let d = try store.read(.accountBinding) else { return nil }
    return try Self.decode(d)
  }

  public func writeBinding(_ b: AccountBinding) throws(SecretStoreError) {
    try store.write(.accountBinding, try Self.encode(b))
  }

  public func epochKey(userID: UserID, epoch: UInt32) throws(SecretStoreError) -> Data? {
    try store.read(.epochKey(userID: userID, epoch: epoch))
  }

  public func writeEpochKey(_ key: some ContiguousBytes, userID: UserID, epoch: UInt32) throws(SecretStoreError) {
    try store.write(.epochKey(userID: userID, epoch: epoch), key.withUnsafeBytes { Data($0) })
  }

  public func writerSeed(userID: UserID, writerID: WriterID) throws(SecretStoreError) -> SecureBytes? {
    guard let d = try store.read(.writerKey(userID: userID, writerID: writerID)) else { return nil }
    guard d.count == 33, d.first == 0x01 else { throw .failed(status: -2) }
    return SecureBytes(copying: d.dropFirst())
  }

  public func writeWriterSeed(_ seed: some ContiguousBytes, userID: UserID, writerID: WriterID)
    throws(SecretStoreError)
  {
    var v = Data([0x01])
    seed.withUnsafeBytes { v.append(contentsOf: $0) }
    defer { v.resetBytes(in: 0..<v.count) }
    guard v.count == 33 else { throw .failed(status: -2) }
    try store.write(.writerKey(userID: userID, writerID: writerID), v)
  }

  public func wipeAccount(userID: UserID, writerID: WriterID?, epochs: ClosedRange<UInt32> = 1...1)
    throws(SecretStoreError)
  {
    var first: SecretStoreError?
    func delete(_ item: SecretItem) {
      do { try store.delete(item) } catch { first = first ?? error }
    }
    delete(.session(apiHost: apiHost))
    delete(.accountBinding)
    for e in epochs { delete(.epochKey(userID: userID, epoch: e)) }
    var writers = Set([writerID].compactMap { $0 })
    let prefix = "\(userID.string):"
    for service in SecretItem.writerServices {
      do {
        for account in try store.accounts(service: service) where account.hasPrefix(prefix) {
          if let w = WriterID(String(account.dropFirst(prefix.count))) { writers.insert(w) }
        }
      } catch {
        first = first ?? error
      }
    }
    for w in writers {
      delete(.writerKey(userID: userID, writerID: w))
      delete(.approvalKey(userID: userID, writerID: w))
    }
    for p in MailSecretProvider.allCases { delete(.mailRefresh(provider: p, userID: userID)) }
    delete(.outlookClientState(userID: userID))
    delete(.textKeySecret)
    delete(.readerWordKey)
    if let first { throw first }
  }
}
