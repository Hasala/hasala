import CoreAuth
import CorePrimitives
import CoreStore
import CoreSync
import CoreTime
import Foundation
import Testing

@testable import Hasala

@Suite("APNs environment")
struct APNsEnvironmentTests {
  private final class Marker {}

  private func fixture(_ name: String) throws -> URL {
    let bundle = Bundle(for: Marker.self)
    let url = bundle.url(forResource: "\(name).mobileprovision", withExtension: "fixture")
      ?? bundle.url(forResource: "\(name).mobileprovision", withExtension: "fixture", subdirectory: "Fixtures/apns")
    return try #require(url, "Fixtures/apns/\(name).mobileprovision.fixture is not in the test bundle")
  }

  @Test func noProfileIsProduction() {
    #expect(APNsProfile.resolve(profileAt: nil) == .resolved("production"))
    let missing = FileManager.default.temporaryDirectory.appending(path: "no-such-\(UUID().uuidString).mobileprovision")
    #expect(APNsProfile.resolve(profileAt: missing) == .resolved("production"))
  }

  @Test func aDevelopmentProfileIsSandbox() throws {
    #expect(APNsProfile.resolve(profileAt: try fixture("dev")) == .resolved("sandbox"))
  }

  @Test func anAdHocProfileIsProduction() throws {
    #expect(APNsProfile.resolve(profileAt: try fixture("adhoc")) == .resolved("production"))
  }

  @Test(arguments: ["noaps", "garbage", "truncated"])
  func anythingElseIsUnknown(_ name: String) throws {
    #expect(APNsProfile.resolve(profileAt: try fixture(name)) == .unknown)
  }

  @Test func anUnreadableFileIsUnknown() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "apns-\(UUID().uuidString).mobileprovision")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(APNsProfile.resolve(profileAt: dir) == .unknown)
  }

  @Test func onlyTheTwoKnownValuesResolve() {
    func profile(_ aps: String) -> Data {
      Data("""
        \u{30}\u{82}<?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>Entitlements</key><dict>
        <key>aps-environment</key><string>\(aps)</string>
        </dict></dict></plist>\u{00}\u{01}
        """.utf8)
    }
    #expect(APNsProfile.resolve(profile: profile("development")) == .resolved("sandbox"))
    #expect(APNsProfile.resolve(profile: profile("production")) == .resolved("production"))
    #expect(APNsProfile.resolve(profile: profile("Production")) == .unknown)
    #expect(APNsProfile.resolve(profile: profile("")) == .unknown)
    #expect(APNsProfile.resolve(profile: Data("<?xml version=\"1.0\"?><plist version=\"1.0\"><dict/></plist>".utf8)) == .unknown)
    #expect(APNsProfile.resolve(profile: Data()) == .unknown)
  }

  @Test func thePlistIsCutAtTheFirstClosingTag() throws {
    let data = Data("junk<?xml version=\"1.0\"?><plist version=\"1.0\"><dict/></plist>tail</plist>".utf8)
    let plist = try #require(APNsProfile.embeddedPlist(data))
    #expect(String(decoding: plist, as: UTF8.self) == "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict/></plist>")
    #expect(APNsProfile.embeddedPlist(Data("<plist></plist>".utf8)) == nil)
  }

  @Test func theSimulatorNeverRegisters() {
    #if targetEnvironment(simulator)
      #expect(resolveAPNsEnvironment() == .unknown)
    #endif
  }
}

nonisolated private final class HeldPut: Transport, @unchecked Sendable {
  private let arrivals = AsyncStream.makeStream(of: Void.self)
  private let releases = AsyncStream.makeStream(of: Void.self)
  private let lock = NSLock()
  private var sent = 0

  var count: Int {
    lock.withLock { sent }
  }

  func send(_ request: APIRequest) async throws(TransportError) -> APIResponse {
    lock.withLock { sent += 1 }
    arrivals.continuation.yield()
    for await _ in releases.stream { break }
    return APIResponse(status: 204)
  }

  func arrived() async {
    for await _ in arrivals.stream { break }
  }

  func release() {
    releases.continuation.yield()
  }
}

@MainActor
@Suite("APNs registration")
struct PushRegistrarTests {
  private static let user = "00000000-0000-4000-8000-000000000001"
  private static let lastKey = "push.apns.registered.v2"
  private static let token = Data(repeating: 0x5c, count: 32)

  private func defaults() -> UserDefaults {
    let name = "test.push.\(UUID().uuidString)"
    UserDefaults(suiteName: name)!.removePersistentDomain(forName: name)
    return UserDefaults(suiteName: name)!
  }

  private func registrar(_ d: UserDefaults) -> PushRegistrar {
    PushRegistrar(defaults: d, resolveEnvironment: { .resolved("sandbox") }, askForToken: {})
  }

  private func account(_ put: HeldPut) throws -> AccountEnvironment {
    let secrets = Secrets(store: MemorySecretStore(), apiHost: "api.hasala.app")
    try secrets.writeSession(
      SessionRecord(token: "synthetic-token", userID: Self.user, expiresAt: 4_000_000_000, tag: "0011223344556677"))
    return AccountEnvironment(
      client: AuthClient(transport: put), secrets: secrets, approvalKeys: SoftDAK(), passkeys: nil, clock: SystemClock(),
      random: SystemRandom(), apiBase: "https://api.hasala.app", accountsDirectory: nil)
  }

  private func send(_ subject: PushRegistrar, _ put: HeldPut) async {
    let running = Task { await subject.didRegister(token: Self.token) }
    await put.arrived()
    put.release()
    await running.value
  }

  @Test func aFinishedRegistrationIsNotSentAgain() async throws {
    let d = defaults()
    let put = HeldPut()
    let subject = registrar(d)
    subject.register(env: try account(put), userID: Self.user)
    await send(subject, put)
    #expect(d.string(forKey: Self.lastKey) != nil)
    await subject.didRegister(token: Self.token)
    #expect(put.count == 1)
  }

  @Test func aRegistrationThatFinishesAfterForgetIsNotRemembered() async throws {
    let d = defaults()
    let put = HeldPut()
    let env = try account(put)
    let subject = registrar(d)
    subject.register(env: env, userID: Self.user)
    let running = Task { await subject.didRegister(token: Self.token) }
    await put.arrived()
    subject.forget()
    put.release()
    await running.value
    #expect(d.object(forKey: Self.lastKey) == nil)

    subject.register(env: env, userID: Self.user)
    await send(subject, put)
    #expect(put.count == 2)
    #expect(d.string(forKey: Self.lastKey) != nil)
  }
}
