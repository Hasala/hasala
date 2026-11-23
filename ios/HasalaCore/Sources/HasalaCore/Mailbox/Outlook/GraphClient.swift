import CoreJSON
import CorePrimitives
import CoreStore
import CoreTime
import Foundation

public struct OutlookLinkState: Sendable, Equatable {
  public var clientState: String
  public var subscriptionID: String?
  public var subscriptionResource: String?

  public init(clientState: String, subscriptionID: String? = nil, subscriptionResource: String? = nil) {
    self.clientState = clientState
    self.subscriptionID = subscriptionID
    self.subscriptionResource = subscriptionResource
  }

  var bytes: [UInt8] {
    var o = JSONObject([("client_state", .string(clientState))])
    if let subscriptionID { o["subscription_id"] = .string(subscriptionID) }
    if let subscriptionResource { o["subscription_resource"] = .string(subscriptionResource) }
    return JSONWriter().bytes(.object(o))
  }

  init?(bytes: [UInt8]) {
    guard let o = (try? JSONParser.parse(bytes))?.objectValue, let cs = o["client_state"]?.stringValue, !cs.isEmpty
    else { return nil }
    clientState = cs
    subscriptionID = o["subscription_id"]?.stringValue
    subscriptionResource = o["subscription_resource"]?.stringValue
  }
}

public protocol OutlookLinkStore: Sendable {
  func read() throws(SecretUnavailable) -> OutlookLinkState?
  func write(_ state: OutlookLinkState) throws(SecretUnavailable)
  func delete() throws(SecretUnavailable)
}

public struct SecretsOutlookLinkStore: OutlookLinkStore {
  let store: any SecretStore
  let item: SecretItem

  public init(secrets: Secrets, userID: UserID) {
    store = secrets.store
    item = .outlookClientState(userID: userID)
  }

  public func read() throws(SecretUnavailable) -> OutlookLinkState? {
    let d: Data?
    do { d = try store.read(item) } catch { throw SecretUnavailable() }
    guard let d else { return nil }
    guard let s = OutlookLinkState(bytes: [UInt8](d)) else {
      do { try store.delete(item) } catch { throw SecretUnavailable() }
      return nil
    }
    return s
  }

  public func write(_ state: OutlookLinkState) throws(SecretUnavailable) {
    let bytes = Data(state.bytes)
    do {
      try store.write(item, bytes)
      guard try store.read(item) == bytes else { throw SecretUnavailable() }
    } catch {
      throw SecretUnavailable()
    }
  }

  public func delete() throws(SecretUnavailable) {
    do { try store.delete(item) } catch { throw SecretUnavailable() }
  }
}

public final class MemoryOutlookLinkStore: OutlookLinkStore, @unchecked Sendable {
  private let lock = NSLock()
  private var state: OutlookLinkState?
  public var locked = false
  public var writesFail = false

  public init(_ state: OutlookLinkState? = nil) { self.state = state }

  public func read() throws(SecretUnavailable) -> OutlookLinkState? {
    lock.lock()
    defer { lock.unlock() }
    if locked { throw SecretUnavailable() }
    return state
  }
  public func write(_ s: OutlookLinkState) throws(SecretUnavailable) {
    lock.lock()
    defer { lock.unlock() }
    if locked || writesFail { throw SecretUnavailable() }
    state = s
  }
  public func delete() throws(SecretUnavailable) {
    lock.lock()
    defer { lock.unlock() }
    if locked { throw SecretUnavailable() }
    state = nil
  }
}

final class GraphListingCache: @unchecked Sendable {
  private let lock = NSLock()
  private var entries: [String: (address: String, receivedMs: Int64, folder: String?, junk: Bool)] = [:]
  private var folders: GraphClient.SpecialFolders?
  private var inbox: String?

  func put(_ id: String, address: String, receivedMs: Int64, folder: String?, junk: Bool) {
    lock.withLock { entries[id] = (address, receivedMs, folder, junk) }
  }
  func get(_ id: String) -> (address: String, receivedMs: Int64, folder: String?, junk: Bool)? { lock.withLock { entries[id] } }
  func special() -> GraphClient.SpecialFolders? { lock.withLock { folders } }
  func setSpecial(_ f: GraphClient.SpecialFolders) { lock.withLock { folders = f } }
  var inboxID: String? {
    get { lock.withLock { inbox } }
    set { lock.withLock { inbox = newValue } }
  }
}

public struct GraphClient: Sendable {
  public static let defaultBase = "https://graph.microsoft.com/v1.0"
  public static let maxDomainsPerList = 20
  public static let subscriptionLifetimeMs: Int64 = (6 * 24 + 23) * 3_600_000
  public static let pageSize = 100
  public static let immutableIDs = ("Prefer", "IdType=\"ImmutableId\"")
  public static let noMailboxCode = "MailboxNotEnabledForRESTAPI"
  public static let subscriptionResource = "me/mailFolders('inbox')/messages"
  static let subscriptionResources: Set<String> = ["me/messages", subscriptionResource.lowercased()]
  static let messageFields = "id,receivedDateTime,from,parentFolderId"

  struct SpecialFolders: Sendable, Equatable {
    var junk: String?
    var deleted: String?
  }

  let http: any HTTPExchange
  let accessToken: String
  let base: String
  let link: any OutlookLinkStore
  let nowMs: @Sendable () -> Int64
  let knownSenders: [String]
  let cache = GraphListingCache()
  static let log = CoreLog(category: "CoreMailbox")

  public init(
    http: any HTTPExchange, accessToken: String, link: any OutlookLinkStore, base: String = GraphClient.defaultBase,
    knownSenders: [String] = OutlookSenders.known, nowMs: @escaping @Sendable () -> Int64
  ) {
    self.http = http
    self.knownSenders = knownSenders
    self.accessToken = accessToken
    self.link = link
    self.base = base
    self.nowMs = nowMs
  }

  func url(_ path: String, _ query: [(String, String)] = []) -> URL {
    let q = query.map { "\($0.0)=\(FormEncoding.escape($0.1))" }.joined(separator: "&")
    return URL(string: base + path + (q.isEmpty ? "" : "?" + q))!
  }

  func call(_ method: HTTPRequest.Method, _ url: URL, body: JSONValue? = nil, json: Bool = true, op: String)
    async throws(MailAPIError) -> HTTPResponse
  {
    var headers = [("Authorization", "Bearer \(accessToken)"), Self.immutableIDs]
    if json { headers.append(("Accept", "application/json")) }
    if body != nil { headers.append(("Content-Type", "application/json")) }
    let req = HTTPRequest(method: method, url: url, headers: headers, body: body.map { Data(JSONWriter().bytes($0)) })
    let res: HTTPResponse
    do { res = try await http.send(req) } catch .tooLarge { throw .tooLarge(op: op) } catch { throw .offline }
    guard res.ok else { throw Self.failure(res, op: op) }
    return res
  }

  func object(_ method: HTTPRequest.Method, _ url: URL, body: JSONValue? = nil, op: String)
    async throws(MailAPIError) -> JSONObject
  {
    let res = try await call(method, url, body: body, op: op)
    if res.body.isEmpty { return JSONObject() }
    guard let o = (try? JSONParser.parse([UInt8](res.body)))?.objectValue else { throw .status(res.status, op: op) }
    return o
  }

  public static func failure(_ res: HTTPResponse, op: String) -> MailAPIError {
    let code = (try? JSONParser.parse([UInt8](res.body)))?["error"]?["code"]?.stringValue
    log.notice("graph.failure", .count("status", res.status), .redacted("code", code ?? ""))
    if code == noMailboxCode { return .noMailbox }
    if res.status == 429 || res.status == 503,
      let ra = res.header("Retry-After").flatMap({ Int64($0.trimmingCharacters(in: .whitespaces)) }), ra >= 0
    {
      return .throttled(retryAfterSec: ra, op: op)
    }
    if code == "ErrorItemNotFound" { return .status(404, op: op) }
    return .status(res.status, op: op)
  }

  public static func listQuery(_ addresses: [String], sinceSec: Int64, top: Int = pageSize) -> [(String, String)] {
    let clauses = addresses.map { "from/emailAddress/address eq '\($0)'" }
    let filter = "receivedDateTime ge \(isoSeconds(sinceSec)) and (\(clauses.joined(separator: " or ")))"
    return [("$filter", filter), ("$select", messageFields), ("$top", String(top))]
  }

  static func isoSeconds(_ sec: Int64) -> String {
    let s = Instant.iso(max(0, sec) * 1000) ?? "1970-01-01T00:00:00.000Z"
    return s.hasSuffix(".000Z") ? String(s.dropLast(5)) + "Z" : s
  }

  public func listMessages(senders: [String], sinceSec: Int64, pageToken: String?) async throws(MailAPIError)
    -> MailListPage
  {
    guard !senders.isEmpty, senders.count <= Self.maxDomainsPerList, senders.allSatisfy(BankDomains.isQuerySafe)
    else { throw .unfilteredListing }
    let addresses = OutlookSenders.addresses(for: senders, known: knownSenders)
    guard !addresses.isEmpty else { return MailListPage(ids: [], nextPageToken: nil) }
    let wanted = Set(addresses.map { $0.lowercased() })
    let o: JSONObject
    if let pageToken {
      guard pageToken.hasPrefix(base + "/me/messages?"), let u = URL(string: pageToken) else {
        throw .status(200, op: "list")
      }
      o = try await object(.get, u, op: "list")
    } else {
      _ = try await inboxFolderID()
      do {
        o = try await object(.get, url("/me/messages", Self.listQuery(addresses, sinceSec: sinceSec)), op: "list")
      } catch .status(504, _) {
        o = try await object(.get, url("/me/messages", Self.listQuery(addresses, sinceSec: sinceSec, top: 50)), op: "list")
      }
    }
    var ids: [String] = []
    var seen: [(String, String, Int64, String?, Bool)] = []
    let values = o["value"]?.arrayValue ?? []
    let folders = values.isEmpty ? SpecialFolders() : try await specialFolders()
    for m in values {
      guard let id = m["id"]?.stringValue, !id.isEmpty else { throw .status(200, op: "list") }
      let address = m["from"]?["emailAddress"]?["address"]?.stringValue ?? ""
      let received = m["receivedDateTime"]?.stringValue.flatMap { try? parseInstantMs($0) }
      guard wanted.contains(address.lowercased()), BankDomains.isMember(BankDomains.domainOf(address), of: senders),
        let received,
        received >= sinceSec * 1000
      else { throw .filterNotApplied }
      let parent = m["parentFolderId"]?.stringValue
      if let deleted = folders.deleted, parent == deleted { continue }
      ids.append(id)
      seen.append((id, address, received, parent, folders.junk != nil && parent == folders.junk))
    }
    for (id, address, received, folder, junk) in seen {
      cache.put(id, address: address, receivedMs: received, folder: folder, junk: junk)
    }
    let next = o["@odata.nextLink"]?.stringValue
    return MailListPage(ids: ids, nextPageToken: (next?.isEmpty ?? true) ? nil : next)
  }

  func path(_ id: String) -> String { "/me/messages/\(FormEncoding.escape(id))" }

  func specialFolders() async throws(MailAPIError) -> SpecialFolders {
    if let f = cache.special() { return f }
    let f = SpecialFolders(junk: try await folderID("junkemail"), deleted: try await folderID("deleteditems"))
    cache.setSpecial(f)
    return f
  }

  func folderID(_ wellKnownName: String) async throws(MailAPIError) -> String? {
    do {
      let o = try await object(.get, url("/me/mailFolders/\(wellKnownName)", [("$select", "id")]), op: "folder")
      return o["id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    } catch .status(404, _) {
      return nil
    }
  }

  public func messageMetadata(id: String) async throws(MailAPIError) -> MailMessageMetadata {
    if let c = cache.get(id) { return Self.metadata(id, c.address, c.receivedMs) }
    let o = try await object(.get, url(path(id), [("$select", Self.messageFields)]), op: "metadata")
    let address = o["from"]?["emailAddress"]?["address"]?.stringValue ?? ""
    guard let received = o["receivedDateTime"]?.stringValue.flatMap({ try? parseInstantMs($0) }) else {
      throw .status(200, op: "metadata")
    }
    var junk = false
    let parent = o["parentFolderId"]?.stringValue
    if let parent { junk = try await specialFolders().junk == parent }
    cache.put(id, address: address, receivedMs: received, folder: parent, junk: junk)
    return Self.metadata(id, address, received)
  }

  static func metadata(_ id: String, _ address: String, _ receivedMs: Int64) -> MailMessageMetadata {
    MailMessageMetadata(id: id, internalDate: String(receivedMs), sizeEstimate: nil, headers: [("From", address)])
  }

  public func messageRaw(id: String) async throws(MailAPIError) -> MailRawMessage {
    let received = try await messageMetadata(id: id).internalDate
    let inbox = try await inboxFolderID()
    let body = try await messageValue(id: id)
    let entry = cache.get(id)
    return MailRawMessage(
      id: id, rawBase64URL: Base64.encodeURL(body), internalDate: received, spam: entry?.junk ?? false,
      inInbox: entry?.folder == inbox)
  }

  public func inboxFolderID() async throws(MailAPIError) -> String {
    if let id = cache.inboxID { return id }
    let o = try await object(.get, url("/me/mailFolders/inbox", [("$select", "id")]), op: "mailbox")
    guard let id = o["id"]?.stringValue, !id.isEmpty else { throw .status(200, op: "mailbox") }
    cache.inboxID = id
    return id
  }

  public func messageValue(id: String) async throws(MailAPIError) -> Data {
    let res = try await call(.get, url(path(id) + "/$value"), json: false, op: "raw")
    guard !res.body.isEmpty else { throw .status(res.status, op: "raw") }
    return res.body
  }

  public func messageHeaderList(id: String) async throws(MailAPIError) -> [(name: String, value: String)] {
    let o = try await object(.get, url(path(id), [("$select", "internetMessageHeaders")]), op: "headers")
    return (o["internetMessageHeaders"]?.arrayValue ?? []).compactMap { h in
      guard let n = h["name"]?.stringValue, let v = h["value"]?.stringValue else { return nil }
      return (n, v)
    }
  }

  func subscriptionBody(_ notificationURL: String, _ lifecycleURL: String, clientState: String, expiresAtMs: Int64)
    -> JSONValue
  {
    .object(
      JSONObject([
        ("changeType", .string("created")), ("notificationUrl", .string(notificationURL)),
        ("lifecycleNotificationUrl", .string(lifecycleURL)), ("resource", .string(Self.subscriptionResource)),
        ("expirationDateTime", .string(Instant.iso(expiresAtMs) ?? "")), ("clientState", .string(clientState)),
      ]))
  }

  static func expiry(_ o: JSONObject, asked: Int64) -> Int64 {
    o["expirationDateTime"]?.stringValue.flatMap { try? parseInstantMs($0) } ?? asked
  }

  func createSubscription(_ n: String, _ l: String, state: OutlookLinkState) async throws(MailAPIError)
    -> MailSubscription
  {
    let asked = nowMs() + Self.subscriptionLifetimeMs
    let body = subscriptionBody(n, l, clientState: state.clientState, expiresAtMs: asked)
    let o: JSONObject
    do {
      o = try await object(.post, url("/subscriptions"), body: body, op: "subscribe")
    } catch .status(409, _) {
      try await deleteMailboxSubscriptions()
      o = try await object(.post, url("/subscriptions"), body: body, op: "subscribe")
    }
    guard let id = o["id"]?.stringValue, !id.isEmpty else { throw .status(200, op: "subscribe") }
    var kept = state
    kept.subscriptionID = id
    kept.subscriptionResource = Self.subscriptionResource
    do throws(SecretUnavailable) {
      try link.write(kept)
    } catch {
      try? await deleteSubscription(id: id)
      throw .offline
    }
    return MailSubscription(expiresAtMs: Self.expiry(o, asked: asked))
  }

  func deleteMailboxSubscriptions() async throws(MailAPIError) {
    let o = try await object(.get, url("/subscriptions"), op: "subscriptions")
    for s in o["value"]?.arrayValue ?? [] {
      guard let id = s["id"]?.stringValue, !id.isEmpty else { continue }
      var resource = (s["resource"]?.stringValue ?? "").lowercased()
      if resource.hasPrefix("/") { resource.removeFirst() }
      guard Self.subscriptionResources.contains(resource) else { continue }
      try await deleteSubscription(id: id)
    }
  }

  public func deleteSubscription(id: String) async throws(MailAPIError) {
    do {
      _ = try await call(.delete, url("/subscriptions/\(FormEncoding.escape(id))"), op: "unsubscribe")
    } catch .status(404, _) {}
  }
}

extension GraphClient: MailSource {
  public var maxSendersPerList: Int { Self.maxDomainsPerList }

  public func changeToken() async throws(MailAPIError) -> String? { nil }

  public func list(senders: [String], since: Int64, pageToken: String?) async throws(MailAPIError) -> MailListPage {
    try await listMessages(senders: senders, sinceSec: since, pageToken: pageToken)
  }

  public func metadata(id: String) async throws(MailAPIError) -> MailMessageMetadata { try await messageMetadata(id: id) }

  public func raw(id: String) async throws(MailAPIError) -> MailRawMessage { try await messageRaw(id: id) }

  public func subscribe(_ push: MailboxPushConfig) async throws(MailAPIError) -> MailSubscription? {
    guard case .outlook(let n, let l) = push, let state = try? link.read() else { return nil }
    if state.subscriptionID != nil { return try await renew(push) }
    return try await createSubscription(n, l, state: state)
  }

  public func renew(_ push: MailboxPushConfig) async throws(MailAPIError) -> MailSubscription? {
    guard case .outlook(let n, let l) = push, var state = try? link.read() else { return nil }
    guard let id = state.subscriptionID else { return try await createSubscription(n, l, state: state) }
    if state.subscriptionResource != Self.subscriptionResource {
      try await deleteSubscription(id: id)
      state.subscriptionID = nil
      try? link.write(state)
      return try await createSubscription(n, l, state: state)
    }
    let asked = nowMs() + Self.subscriptionLifetimeMs
    let body = JSONValue.object(
      JSONObject([("expirationDateTime", .string(Instant.iso(asked) ?? "")), ("notificationUrl", .string(n))]))
    do {
      let o = try await object(.patch, url("/subscriptions/\(FormEncoding.escape(id))"), body: body, op: "renew")
      return MailSubscription(expiresAtMs: Self.expiry(o, asked: asked))
    } catch .status(404, _) {
      state.subscriptionID = nil
      try? link.write(state)
      return try await createSubscription(n, l, state: state)
    }
  }

  public func stop() async throws(MailAPIError) {
    guard var state = try? link.read(), let id = state.subscriptionID else { return }
    try await deleteSubscription(id: id)
    state.subscriptionID = nil
    state.subscriptionResource = nil
    try? link.write(state)
  }

  public func checkMailbox() async throws(MailAPIError) {
    _ = try await object(.get, url("/me/mailFolders/inbox", [("$select", "id")]), op: "mailbox")
  }
}
