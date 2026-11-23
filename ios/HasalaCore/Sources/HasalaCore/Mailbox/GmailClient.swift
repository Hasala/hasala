import CoreJSON
import Foundation

public typealias GmailAPIError = MailAPIError

public struct GmailWatchResponse: Sendable, Equatable {
  public let historyID: String
  public let expirationMs: Int64
}

public struct GmailClient: Sendable {
  public static let defaultBase = "https://gmail.googleapis.com/gmail/v1/users/me"
  let http: any HTTPExchange
  let accessToken: String
  let base: String

  public init(http: any HTTPExchange, accessToken: String, base: String = GmailClient.defaultBase) {
    self.http = http
    self.accessToken = accessToken
    self.base = base
  }

  func get(_ path: String, _ query: [(String, String)], op: String) async throws(GmailAPIError) -> JSONObject {
    try await call(.get, path, query, body: nil, op: op)
  }

  func call(
    _ method: HTTPRequest.Method, _ path: String, _ query: [(String, String)], body: JSONValue?, op: String
  ) async throws(GmailAPIError) -> JSONObject {
    var headers = [("Authorization", "Bearer \(accessToken)"), ("Accept", "application/json")]
    if body != nil { headers.append(("Content-Type", "application/json")) }
    let req = HTTPRequest(
      method: method, url: URL.build(base, path, query), headers: headers,
      body: body.map { Data(JSONWriter().bytes($0)) })
    let res: HTTPResponse
    do { res = try await http.send(req) } catch .tooLarge { throw .tooLarge(op: op) } catch { throw .offline }
    guard res.ok else {
      if res.status == 403, Self.isRateLimit(errorBody: res.body) { throw .status(429, op: op) }
      if res.status == 400, Self.isMailServiceNotEnabled(errorBody: res.body) { throw .noMailbox }
      throw .status(res.status, op: op)
    }
    if res.body.isEmpty { return JSONObject() }
    guard let o = (try? JSONParser.parse([UInt8](res.body)))?.objectValue else {
      throw .status(res.status, op: op)
    }
    return o
  }

  public func profileHistoryID() async throws(GmailAPIError) -> String {
    let o = try await get("/profile", [("fields", "historyId")], op: "profile")
    if let s = o["historyId"]?.stringValue, !s.isEmpty { return s }
    if let n = o["historyId"]?.numberValue { return n.literal }
    throw .status(200, op: "profile")
  }

  public func messagesList(query: String, pageToken: String?, maxResults: Int = 100)
    async throws(GmailAPIError) -> MailListPage
  {
    guard query.contains("from:") else { throw .unfilteredListing }
    var q: [(String, String)] = [
      ("q", query), ("includeSpamTrash", "true"), ("maxResults", String(maxResults)),
      ("fields", "messages(id),nextPageToken"),
    ]
    if let pageToken { q.append(("pageToken", pageToken)) }
    let o = try await get("/messages", q, op: "list")
    var ids: [String] = []
    for m in o["messages"]?.arrayValue ?? [] {
      if let id = m["id"]?.stringValue, !id.isEmpty { ids.append(id) }
    }
    let next = o["nextPageToken"]?.stringValue
    return MailListPage(ids: ids, nextPageToken: (next?.isEmpty ?? true) ? nil : next)
  }

  public func messageMetadata(id: String) async throws(GmailAPIError) -> MailMessageMetadata {
    let o = try await get(
      "/messages/\(FormEncoding.escape(id))",
      [
        ("format", "metadata"), ("metadataHeaders", "From"), ("metadataHeaders", "Authentication-Results"),
        ("fields", "id,internalDate,sizeEstimate,payload/headers"),
      ], op: "metadata")
    var headers: [(name: String, value: String)] = []
    for h in o["payload"]?["headers"]?.arrayValue ?? [] {
      if let n = h["name"]?.stringValue, let v = h["value"]?.stringValue { headers.append((n, v)) }
    }
    return MailMessageMetadata(
      id: id, internalDate: Self.decimal(o["internalDate"]),
      sizeEstimate: o["sizeEstimate"]?.numberValue?.int64Value, headers: headers)
  }

  public func messageRaw(id: String) async throws(GmailAPIError) -> MailRawMessage {
    let o = try await get("/messages/\(FormEncoding.escape(id))", [("format", "raw")], op: "raw")
    guard let raw = o["raw"]?.stringValue, !raw.isEmpty else { throw .status(200, op: "raw") }
    let spam = (o["labelIds"]?.arrayValue ?? []).contains { $0.stringValue == "SPAM" }
    return MailRawMessage(id: id, rawBase64URL: raw, internalDate: Self.decimal(o["internalDate"]), spam: spam)
  }

  public func watch(topicName: String) async throws(GmailAPIError) -> GmailWatchResponse {
    let body = JSONValue.object(
      JSONObject([
        ("topicName", .string(topicName)), ("labelIds", .array([.string("INBOX")])),
        ("labelFilterBehavior", .string("include")),
      ]))
    let o = try await call(.post, "/watch", [], body: body, op: "watch")
    let exp = Self.decimal(o["expiration"])
    guard let ms = Int64(exp) else { throw .status(200, op: "watch") }
    return GmailWatchResponse(historyID: Self.decimal(o["historyId"]), expirationMs: ms)
  }

  public func stop() async throws(GmailAPIError) {
    _ = try await call(.post, "/stop", [], body: nil, op: "stop")
  }

  public static func senderQuery(_ group: [String], sinceSec: Int64) -> String {
    "{" + group.map { "from:" + $0 }.joined(separator: " ") + "} after:\(sinceSec) -in:trash"
  }

  static let rateLimitReasons: Set<String> = [
    "ratelimitexceeded", "userratelimitexceeded", "dailylimitexceeded", "quotaexceeded",
    "rate_limit_exceeded", "resource_exhausted",
  ]

  public static func isRateLimit(errorBody: Data) -> Bool {
    guard !errorBody.isEmpty, let e = (try? JSONParser.parse([UInt8](errorBody)))?["error"] else { return false }
    var reasons: [String] = []
    for x in e["errors"]?.arrayValue ?? [] { if let r = x["reason"]?.stringValue { reasons.append(r) } }
    for x in e["details"]?.arrayValue ?? [] { if let r = x["reason"]?.stringValue { reasons.append(r) } }
    if let st = e["status"]?.stringValue { reasons.append(st) }
    return reasons.contains { rateLimitReasons.contains($0.lowercased()) }
  }

  static let mailServiceNotEnabled = "Mail service not enabled"

  public static func isMailServiceNotEnabled(errorBody: Data) -> Bool {
    guard !errorBody.isEmpty, let e = (try? JSONParser.parse([UInt8](errorBody)))?["error"] else { return false }
    var messages: [String] = []
    var precondition = e["status"]?.stringValue == "FAILED_PRECONDITION"
    if let m = e["message"]?.stringValue { messages.append(m) }
    for x in e["errors"]?.arrayValue ?? [] {
      if x["reason"]?.stringValue == "failedPrecondition" { precondition = true }
      if let m = x["message"]?.stringValue { messages.append(m) }
    }
    return precondition && messages.contains(mailServiceNotEnabled)
  }

  static func decimal(_ v: JSONValue?) -> String {
    if let s = v?.stringValue { return s }
    if let n = v?.numberValue, n.isIntegerLiteral { return n.literal }
    return ""
  }
}

extension GmailClient: MailSource {
  public var maxSendersPerList: Int { BankDomains.maxTermsPerQuery }

  public func changeToken() async throws(MailAPIError) -> String? { try await profileHistoryID() }

  public func list(senders: [String], since: Int64, pageToken: String?) async throws(MailAPIError) -> MailListPage {
    guard !senders.isEmpty else { throw .unfilteredListing }
    return try await messagesList(query: Self.senderQuery(senders, sinceSec: since), pageToken: pageToken)
  }

  public func metadata(id: String) async throws(MailAPIError) -> MailMessageMetadata { try await messageMetadata(id: id) }

  public func raw(id: String) async throws(MailAPIError) -> MailRawMessage { try await messageRaw(id: id) }

  public func checkMailbox() async throws(MailAPIError) {
    _ = try await get("/profile", [("fields", "historyId")], op: "mailbox")
  }

  public func subscribe(_ push: MailboxPushConfig) async throws(MailAPIError) -> MailSubscription? {
    guard case .gmail(let topic) = push else { return nil }
    return MailSubscription(expiresAtMs: try await watch(topicName: topic).expirationMs)
  }

  public func renew(_ push: MailboxPushConfig) async throws(MailAPIError) -> MailSubscription? {
    try await subscribe(push)
  }
}
