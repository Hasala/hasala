import Foundation
import Testing

@testable import Hasala

@MainActor
@Suite("BuildInfo")
struct BuildInfoTests {
  private let good: [String: Any] = [
    "CFBundleShortVersionString": "0.1.0",
    "CFBundleVersion": "261011.11530",
    "HasalaGitCommit": "0123456789ab",
    "HasalaEnvironment": "qa",
    "HasalaAPIBaseURL": "https://api.hasala.app",
    "HasalaGoogleClientID": "unset",
    "HasalaGoogleRedirectScheme": "unset",
    "HasalaGmailPubSubTopic": "projects/example-project/topics/example-topic",
    "HasalaOutlookClientID": "unset",
    "HasalaOutlookRedirectScheme": "msauth.app.hasala.ios",
  ]

  @Test func parsesAndFormatsTheFooter() throws {
    let info = try BuildInfo(infoDictionary: good)
    #expect(info.apiBaseURL.absoluteString == "https://api.hasala.app")
    #expect(info.footer == "Hasala QA · 0.1.0 (261011.11530) · 0123456789ab")
  }

  @Test func aMissingKeyIsAnError() {
    var d = good
    d["HasalaEnvironment"] = nil
    #expect(throws: BuildInfo.Problem.missing("HasalaEnvironment")) { try BuildInfo(infoDictionary: d) }
  }

  @Test func anUnexpandedSettingIsAnError() {
    var d = good
    d["HasalaGitCommit"] = "$(HASALA_GIT_COMMIT)"
    #expect(throws: BuildInfo.Problem.malformed("HasalaGitCommit")) { try BuildInfo(infoDictionary: d) }
  }

  @Test func theAPIMustBeHTTPS() {
    var d = good
    d["HasalaAPIBaseURL"] = "http://api.hasala.app"
    #expect(throws: BuildInfo.Problem.malformed("HasalaAPIBaseURL")) { try BuildInfo(infoDictionary: d) }
  }

  #if DEBUG
    @Test func theDebugOverrideAcceptsHTTPAndHTTPS() throws {
      #expect(try BuildInfo.debugAPIBaseURLOverride([:]) == nil)
      #expect(try BuildInfo.debugAPIBaseURLOverride(["HASALA_API_BASE_URL": "  "]) == nil)
      let local = try BuildInfo.debugAPIBaseURLOverride(["HASALA_API_BASE_URL": "http://localhost:8080"])
      #expect(local?.absoluteString == "http://localhost:8080")
      let tls = try BuildInfo.debugAPIBaseURLOverride(["HASALA_API_BASE_URL": "https://api.hasala.app"])
      #expect(tls?.host() == "api.hasala.app")
    }

    @Test func theDebugOverrideRejectsAnythingElse() {
      for bad in ["localhost:8080", "ftp://example.com", "http://", "not a url"] {
        #expect(throws: BuildInfo.Problem.malformed("HASALA_API_BASE_URL")) {
          try BuildInfo.debugAPIBaseURLOverride(["HASALA_API_BASE_URL": bad])
        }
      }
    }
  #endif

  @Test func theAPIBaseURLDefaultsToTheBundle() {
    if ProcessInfo.processInfo.environment["HASALA_API_BASE_URL"] == nil {
      #expect(BuildInfo.apiBaseURL() == BuildInfo.current.apiBaseURL)
    }
  }

  @Test nonisolated func isReadableOffTheMainActor() async {
    let footer = await Task.detached { BuildInfo.current.footer }.value
    #expect(footer.hasPrefix("Hasala QA · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") ("))
  }

  @Test func theBundleIsComplete() throws {
    let info = try BuildInfo(infoDictionary: Bundle.main.infoDictionary ?? [:])
    #expect(info.environment == "qa")
    #expect(Bundle.main.object(forInfoDictionaryKey: "HasalaAPIBaseURL") as? String == "https://api.hasala.app")
    #expect(info.apiBaseURL.absoluteString == "https://api.hasala.app")
    #expect(info.marketingVersion.wholeMatch(of: /\d+\.\d+\.\d+/) != nil)
    #expect(Bundle.main.object(forInfoDictionaryKey: "ITSAppUsesNonExemptEncryption") as? Bool == false)
    #expect(Bundle.main.bundleIdentifier == "app.hasala.ios")
    #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String == "Hasala")
    #expect(Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") == nil)
    #expect(Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") == nil)
    #expect(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy") != nil)
  }

  @Test func theBundleCarriesTheGoogleClient() throws {
    let info = try BuildInfo(infoDictionary: Bundle.main.infoDictionary ?? [:])
    let suffix = ".apps.googleusercontent.com"
    #expect(info.googleClientID.hasSuffix(suffix))
    let id = info.googleClientID.dropLast(suffix.count)
    #expect(!id.isEmpty)
    #expect(info.googleRedirectScheme == "com.googleusercontent.apps.\(id)")
    #expect(info.gmailPubSubTopic == "unset")
  }

  @Test func theBundleCarriesTheOutlookSettings() throws {
    let info = try BuildInfo(infoDictionary: Bundle.main.infoDictionary ?? [:])
    #expect(info.outlookRedirectScheme == "msauth.app.hasala.ios")
    #expect(info.outlookClientID == "unset" || UUID(uuidString: info.outlookClientID) != nil)
  }

  @Test func theOutlookKeysAreRequired() {
    var d = good
    d["HasalaOutlookClientID"] = nil
    #expect(throws: BuildInfo.Problem.missing("HasalaOutlookClientID")) { try BuildInfo(infoDictionary: d) }
  }
}
