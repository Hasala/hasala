import CoreAuth
import CoreMailbox
import CorePrimitives
import CoreStore
import CoreSync
import CoreTime
import Foundation
import Synchronization
import Testing

@testable import Hasala

@MainActor
@Suite("Live mailbox disconnect against stubs")
struct LiveMailboxDisconnectTests {
  static let refreshToken = "synthetic-refresh"
  static let address = "maya.alerts@gmail.com"
  static let reason = "Confirm it's you to disconnect this mailbox"

  nonisolated final class Calls: Sendable {
    private let lines = Mutex<[String]>([])
    var all: [String] { lines.withLock { $0 } }
    func add(_ line: String) { lines.withLock { $0.append(line) } }
    func first(_ line: String) -> Int? { all.firstIndex(of: line) }
  }

  nonisolated final class LoggedHasalad: Transport {
    let inner: MiniHasalad
    let calls: Calls

    init(inner: MiniHasalad, calls: Calls) {
      self.inner = inner
      self.calls = calls
    }

    func send(_ request: APIRequest) async throws(TransportError) -> APIResponse {
      let response = try await inner.send(request)
      calls.add("hasalad \(request.method.rawValue) \(request.path) \(response.status)")
      return response
    }
  }

  nonisolated final class StubGoogle: HTTPExchange {
    let calls: Calls
    private let tokens = Mutex<[String]>([])

    init(calls: Calls) { self.calls = calls }

    var revoked: [String] { tokens.withLock { $0 } }

    func send(_ request: HTTPRequest) async throws(HTTPExchangeError) -> HTTPResponse {
      let route = "\(request.method.rawValue) \(request.url.host() ?? "")\(request.url.path())"
      calls.add("google \(route)")
      switch route {
      case "POST oauth2.googleapis.com/token":
        return HTTPResponse(status: 200, body: Data(#"{"access_token":"synthetic-access","expires_in":3600}"#.utf8))
      case "POST oauth2.googleapis.com/revoke":
        let form = request.body.map { String(decoding: $0, as: UTF8.self) } ?? ""
        tokens.withLock { $0.append(form) }
        return HTTPResponse(status: 200, body: Data("{}".utf8))
      case "POST gmail.googleapis.com/gmail/v1/users/me/stop":
        return HTTPResponse(status: 204)
      default:
        return HTTPResponse(status: 404, body: Data(#"{"error":{"code":404}}"#.utf8))
      }
    }
  }

  nonisolated final class Password: Sendable {
    private let held: Mutex<String>
    init(_ password: String) { held = Mutex(password) }
    var value: String {
      get { held.withLock { $0 } }
      set { held.withLock { $0 = newValue } }
    }
  }

  struct Linked {
    let rt: AccountRuntime
    let mailbox: LiveMailboxConnecting
    let server: MiniHasalad
    let google: StubGoogle
    let calls: Calls
    let asked: Calls
    let password: Password
    let grant: SecretsMailRefreshTokenStore
    let facts: BankTextsFacts
    let directory: URL
    let suite: String

    func end() async {
      await rt.close()
      UserDefaults().removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
  }

  func linked(passkey: Bool) async throws -> Linked {
    let server = MiniHasalad(invite: LiveAccountServiceTests.invite)
    let calls = Calls()
    let env = AccountEnvironment(
      client: AuthClient(transport: LoggedHasalad(inner: server, calls: calls)),
      secrets: Secrets(store: MemorySecretStore(), apiHost: "api.hasala.app"), approvalKeys: SoftDAK(),
      passkeys: passkey ? SamePRFPasskeys() : nil, clock: SystemClock(), random: SystemRandom(),
      apiBase: "https://api.hasala.app", accountsDirectory: nil)
    let (account, _) = try await LiveAccountServiceTests.signUp(server, env)
    if passkey { try await account.perform(.addPasskey, password: LiveAccountServiceTests.password) }
    #expect(await account.usesPasskey() == passkey)
    let enrolled = try #require(account.enrolled)
    let binding = try #require(try env.secrets.binding())

    let grant = SecretsMailRefreshTokenStore(secrets: env.secrets, userID: enrolled.userID, provider: .gmail)
    try grant.write(Self.refreshToken)
    var row = MailboxStateRow(phase: MailboxPhase.active.rawValue)
    row.provider = MailProviderID.gmail.rawValue
    row.address = Self.address
    var write = MailboxWrite()
    write.state = row
    try MailboxTableStore(writer: enrolled.store.db).commit(write)
    server.mailboxLink = (thisDevice: true, provider: "gmail")

    let suite = "mailbox-disconnect-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    LocalAccountData.setMailboxProvider(.gmail, defaults)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    let facts = BankTextsFacts(directory: directory.appendingPathComponent("facts"))
    let google = StubGoogle(calls: calls)
    let asked = Calls()
    let password = Password(LiveAccountServiceTests.password)
    let rt = try await AccountRuntime.open(
      env: env, binding: binding, enrolled: enrolled, build: try BankTextsIntakeTests.bothProviders(),
      profile: BootController.profileInfo(nil, binding: binding), usesPasskey: { await account.usesPasskey() },
      stopped: { _ in }, bankTextFacts: facts, mailHTTP: google, providerDefaults: defaults,
      askPassword: { reason in
        asked.add(reason)
        return password.value
      })
    await rt.refreshMailbox()
    let mailbox = LiveMailboxConnecting(runtime: { rt })
    #expect(mailbox.linkedProvider == .gmail)
    #expect(mailbox.mailboxes.map(\.address) == [Self.address])
    #expect(facts.read(nowMs: rt.context.clock.nowMs()).link?.linked == true)
    return Linked(
      rt: rt, mailbox: mailbox, server: server, google: google, calls: calls, asked: asked, password: password,
      grant: grant, facts: facts, directory: directory, suite: suite)
  }

  func expectDisconnected(_ l: Linked, proof: String) async throws {
    #expect(l.server.mailboxLink == nil)
    #expect(l.server.lastStepUpAction == "mailbox.unlink")
    #expect(l.server.mailboxUnlinkProofs == [proof])
    #expect(l.google.revoked == ["token=\(Self.refreshToken)"])
    #expect(try l.grant.read() == nil)
    #expect(await l.rt.lane?.status().phase == .unlinked)
    #expect(l.mailbox.linkedProvider == nil)
    #expect(l.mailbox.mailboxes.isEmpty)
    #expect(l.facts.read(nowMs: l.rt.context.clock.nowMs()).link?.linked == false)

    let begun = try #require(l.calls.first("hasalad POST /api/v1/auth/step-up/begin 200"))
    let stopped = try #require(l.calls.first("google POST gmail.googleapis.com/gmail/v1/users/me/stop"))
    let revoked = try #require(l.calls.first("google POST oauth2.googleapis.com/revoke"))
    let deleted = try #require(l.calls.first("hasalad DELETE /api/v1/mailbox/link 204"))
    #expect(begun < stopped && stopped < revoked && revoked < deleted)
  }

  @Test(arguments: [false, true])
  func aPasskeyAccountDisconnectsWithItsPasskey(removeTransactions: Bool) async throws {
    let l = try await linked(passkey: true)
    try await l.mailbox.disconnect(LiveMailboxConnecting.mailboxID(.gmail), removeTransactions: removeTransactions)
    #expect(l.asked.all.isEmpty)
    try await expectDisconnected(l, proof: "passkey")
    await l.end()
  }

  @Test(arguments: [false, true])
  func aPasswordOnlyAccountDisconnectsWithItsPassword(removeTransactions: Bool) async throws {
    let l = try await linked(passkey: false)
    try await l.mailbox.disconnect(LiveMailboxConnecting.mailboxID(.gmail), removeTransactions: removeTransactions)
    #expect(l.asked.all == [Self.reason])
    try await expectDisconnected(l, proof: "device")
    await l.end()
  }

  @Test func aWrongPasswordKeepsTheLinkAndTheRightOneEndsItOnTheNextTry() async throws {
    let l = try await linked(passkey: false)
    l.password.value = "not the password of this account"
    await #expect(throws: MailConnectFailure.failed("Couldn't disconnect Gmail. Try again.")) {
      try await l.mailbox.disconnect(LiveMailboxConnecting.mailboxID(.gmail), removeTransactions: false)
    }
    #expect(l.calls.all.contains("hasalad DELETE /api/v1/mailbox/link 403"))
    #expect(l.server.mailboxLink?.thisDevice == true)
    #expect(l.server.mailboxUnlinkProofs.isEmpty)
    #expect(try l.grant.read() == Self.refreshToken)
    #expect(l.mailbox.linkedProvider == .gmail)

    l.password.value = LiveAccountServiceTests.password
    try await l.mailbox.disconnect(LiveMailboxConnecting.mailboxID(.gmail), removeTransactions: false)
    #expect(l.asked.all == [Self.reason, Self.reason])
    #expect(l.server.mailboxLink == nil)
    #expect(l.server.mailboxUnlinkProofs == ["device"])
    #expect(try l.grant.read() == nil)
    #expect(l.mailbox.linkedProvider == nil)
    await l.end()
  }
}
