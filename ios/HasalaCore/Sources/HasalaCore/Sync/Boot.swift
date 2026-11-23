import CoreAuth
import CorePrimitives
import CoreStore
import CoreWire
import Foundation

public enum BootState: Sendable, Hashable {
  case waitingForUnlock
  case signedOut
  case onboardingKeys
  case foreignData
  case needsUnlock
  case unenrolled
  case signedOutBound
  case restoring
  case opening(AccountBinding)
}

public struct BootFacts: Sendable, Hashable {
  public var binding: AccountBinding?
  public var session: SessionRecord?
  public var storeUserID: UserID?
  public var storeExists: Bool
  public var epochKeyPresent: Bool
  public var writerKeyPresent: Bool
  public var unreadable: Bool

  public init(
    binding: AccountBinding?, session: SessionRecord?, storeUserID: UserID?, storeExists: Bool,
    epochKeyPresent: Bool, writerKeyPresent: Bool, unreadable: Bool = false
  ) {
    self.binding = binding
    self.session = session
    self.storeUserID = storeUserID
    self.storeExists = storeExists
    self.epochKeyPresent = epochKeyPresent
    self.writerKeyPresent = writerKeyPresent
    self.unreadable = unreadable
  }
}

public enum Boot {
  public static func decide(_ f: BootFacts) -> BootState {
    if f.unreadable { return .waitingForUnlock }
    let liveSession = f.session.flatMap { $0.pending_logout ? nil : $0 }
    guard let binding = f.binding else {
      if liveSession != nil { return .onboardingKeys }
      return f.storeExists ? .foreignData : .signedOut
    }
    if let s = f.storeUserID, s.string != binding.user_id { return .foreignData }
    if let s = liveSession, s.user_id != binding.user_id { return .foreignData }
    guard binding.userID != nil, binding.writerID != nil else { return .foreignData }
    if !f.epochKeyPresent { return .needsUnlock }
    if !f.writerKeyPresent { return .unenrolled }
    if liveSession == nil { return .signedOutBound }
    if !f.storeExists { return .restoring }
    return .opening(binding)
  }

  public static func gather(_ env: AccountEnvironment) -> BootFacts {
    var f = BootFacts(
      binding: nil, session: nil, storeUserID: nil, storeExists: false, epochKeyPresent: false,
      writerKeyPresent: false)
    do {
      f.binding = try env.secrets.binding()
      f.session = try env.secrets.session()
      if let b = f.binding, let u = b.userID, let w = b.writerID {
        f.epochKeyPresent = try env.secrets.epochKey(userID: u, epoch: b.key_epoch) != nil
        f.writerKeyPresent = try env.secrets.writerSeed(userID: u, writerID: w) != nil
        if let dir = env.storeDirectory(for: u) {
          f.storeExists = FileManager.default.fileExists(atPath: dir.appendingPathComponent("ledger.sqlite").path)
          if f.storeExists { f.storeUserID = LedgerStore.owner(directory: dir) }
        }
      }
      if f.binding == nil { f.storeExists = holdsAccountFiles(env) }
    } catch {
      f.unreadable = true
    }
    return f
  }

  private static func holdsAccountFiles(_ env: AccountEnvironment) -> Bool {
    guard let root = env.accountsDirectory,
      let items = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    else { return false }
    return items.contains { UserID($0.lastPathComponent) != nil }
  }
}

public enum LaunchProbe: Sendable, Hashable {
  case ok
  case unbound
  case frozen
  case updateRequired
  case stop(SyncStop)

  public static func run(_ ctx: SyncContext, build: Int) async -> LaunchProbe {
    do {
      let meta = try await ctx.client.meta()
      if let min = meta.min_ios_build, min > build { return .updateRequired }
      let token = try ctx.bearer()
      let s = try await ctx.client.session(bearer: token)
      if s.restricted == true { return .frozen }
      guard let w = s.writer_id else { return .unbound }
      return w == ctx.writerID.string ? .ok : .unbound
    } catch let e as APIError {
      let stop = await ctx.settled(SyncStop.read(e))
      return stop == .frozen ? .frozen : stop == .halted(.updateRequired) ? .updateRequired : .stop(stop)
    } catch let e as SyncStop {
      return .stop(e)
    } catch {
      return .stop(.offline)
    }
  }
}
