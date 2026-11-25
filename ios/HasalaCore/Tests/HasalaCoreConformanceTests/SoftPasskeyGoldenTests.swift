import CoreAuth
import CoreJSON
import CorePrimitives
import CoreSoftAuth
import CryptoKit
import Foundation
import Testing

enum SoftPasskeyGolden {
  static let file = "soft-passkey.json"
  static let rpID = "hasala.app"
  static let origin = "https://hasala.app"
  static let privateScalar = Data(0x01...0x20)
  static let credentialID = Data(0xa0...0xb3)
  static let aaguid = Data(count: 16)
  static let userHandle = Data(0x10...0x1f)
  static let prfSecret = Data(0xc0...0xdf)
  static let prfSalt = Data(0x40...0x5f)
  static let registrationChallenge = Data(0x60...0x7f)
  static let assertionChallenge = Data(0x80...0x9f)
  static let attestationHead = "a363666d74646e6f6e656761747453746d74a068617574684461746158"

  struct Output {
    let registration: RawRegistration
    let assertion: RawAssertion
    let publicKey: Data
  }

  static func run() async throws -> Output {
    let p = SoftPasskey(rpID: rpID, origin: origin)
    p.setBackup(eligible: true, backedUp: true)
    try p.fixNext(privateScalar: privateScalar, credentialID: credentialID, prfSecret: prfSecret)
    let reg = try await p.register(
      CreationOptions(challenge: registrationChallenge, rpID: rpID, userID: userHandle, userName: "golden"),
      prfSalt: prfSalt)
    let ass = try await p.assert(challenge: assertionChallenge, allowCredentialIDs: [credentialID], prfSalt: prfSalt)
    let pub = try P256.Signing.PrivateKey(rawRepresentation: privateScalar).publicKey.x963Representation
    return Output(registration: reg, assertion: ass, publicKey: pub)
  }

  static func authenticatorData(attestationObject att: Data) throws -> Data {
    let head = try Hex.decode(attestationHead)
    guard att.count > head.count + 1, att.prefix(head.count) == head, Int(att[att.startIndex + head.count]) == att.count - head.count - 1
    else { throw FixtureError.missing("attestation object head") }
    return Data(att.dropFirst(head.count + 1))
  }

  static func bytes(_ s: SecureBytes?) -> Data { s.map { $0.withUnsafeBytes { Data($0) } } ?? Data() }

  static func build() async throws -> JSONValue {
    let o = try await run()
    func h(_ d: Data) -> JSONValue { .string(Hex.encode(d)) }
    return obj([
      (
        "note",
        .string(
          "CoreSoftAuth's SoftPasskey on fixed inputs: P-256 scalar 01..20, a 20-byte credential id, a zero AAGUID, flags UP|UV|BE|BS, sign count 0 at registration and 1 at the assertion. server/internal/authtest (softauth_test.go) builds the same attestation object, authenticator data and PRF output with its Authenticator and compares bytes, and go-webauthn verifies the registration and the assertion of this file. The signature is random per run: verify it under public_key_x963_hex, never compare its bytes. PRF output is HMAC-SHA-256(prf_secret, SHA-256(\"WebAuthn PRF\" ‖ 00 ‖ prf_salt))."
        )
      ),
      ("rp_id", .string(rpID)), ("origin", .string(origin)),
      ("private_scalar_hex", h(privateScalar)), ("public_key_x963_hex", h(o.publicKey)),
      ("credential_id_hex", h(credentialID)), ("aaguid_hex", h(aaguid)), ("user_handle_hex", h(userHandle)),
      ("prf_secret_hex", h(prfSecret)), ("prf_salt_hex", h(prfSalt)),
      ("prf_output_hex", h(bytes(o.registration.prfFirst))),
      (
        "registration",
        obj([
          ("challenge_hex", h(registrationChallenge)), ("sign_count", .number(JSONNumber(Int64(0)))),
          ("client_data_json_hex", h(o.registration.rawClientDataJSON)),
          ("authenticator_data_hex", h(try authenticatorData(attestationObject: o.registration.rawAttestationObject))),
          ("attestation_object_hex", h(o.registration.rawAttestationObject)),
        ])
      ),
      (
        "assertion",
        obj([
          ("challenge_hex", h(assertionChallenge)), ("sign_count", .number(JSONNumber(Int64(1)))),
          ("client_data_json_hex", h(o.assertion.rawClientDataJSON)),
          ("authenticator_data_hex", h(o.assertion.authenticatorData)),
          ("signature_der_hex", h(o.assertion.signature)),
        ])
      ),
    ])
  }
}

@Suite("conformance/swift/soft-passkey.json")
struct SoftPasskeyGoldenTests {
  typealias G = SoftPasskeyGolden

  @Test("the fixed inputs are the ones in the file")
  func inputs() throws {
    let m = try Fixtures.json("swift/" + G.file)
    #expect(try m.string("rp_id") == G.rpID)
    #expect(try m.string("origin") == G.origin)
    #expect(try m.string("private_scalar_hex") == Hex.encode(G.privateScalar))
    #expect(try m.string("credential_id_hex") == Hex.encode(G.credentialID))
    #expect(try m.string("aaguid_hex") == Hex.encode(G.aaguid))
    #expect(try m.string("user_handle_hex") == Hex.encode(G.userHandle))
    #expect(try m.string("prf_secret_hex") == Hex.encode(G.prfSecret))
    #expect(try m.string("prf_salt_hex") == Hex.encode(G.prfSalt))
    #expect(try #require(m["registration"]).string("challenge_hex") == Hex.encode(G.registrationChallenge))
    #expect(try #require(m["assertion"]).string("challenge_hex") == Hex.encode(G.assertionChallenge))
  }

  @Test("SoftPasskey gives the bytes of the file, and the signature of the file verifies")
  func bytes() async throws {
    let m = try Fixtures.json("swift/" + G.file)
    let reg = try #require(m["registration"])
    let ass = try #require(m["assertion"])
    let o = try await G.run()

    #expect(Hex.encode(o.publicKey) == (try m.string("public_key_x963_hex")))
    #expect(o.registration.credentialID == G.credentialID)
    #expect(Hex.encode(o.registration.rawClientDataJSON) == (try reg.string("client_data_json_hex")))
    #expect(Hex.encode(o.registration.rawAttestationObject) == (try reg.string("attestation_object_hex")))
    let regAuthData = try G.authenticatorData(attestationObject: o.registration.rawAttestationObject)
    #expect(Hex.encode(regAuthData) == (try reg.string("authenticator_data_hex")))
    #expect(regAuthData[regAuthData.startIndex + 32] == 0x5d)
    #expect(Array(regAuthData.dropFirst(33).prefix(4)) == [0, 0, 0, UInt8(try reg.int("sign_count"))])
    #expect(regAuthData.dropFirst(37).prefix(16) == G.aaguid)

    #expect(o.assertion.credentialID == G.credentialID)
    #expect(o.assertion.userHandle == G.userHandle)
    #expect(Hex.encode(o.assertion.rawClientDataJSON) == (try ass.string("client_data_json_hex")))
    #expect(Hex.encode(o.assertion.authenticatorData) == (try ass.string("authenticator_data_hex")))
    #expect(o.assertion.authenticatorData.count == 37)
    #expect(o.assertion.authenticatorData[o.assertion.authenticatorData.startIndex + 32] == 0x1d)
    #expect(Array(o.assertion.authenticatorData.suffix(4)) == [0, 0, 0, UInt8(try ass.int("sign_count"))])

    let prf = try m.string("prf_output_hex")
    #expect(Hex.encode(G.bytes(o.registration.prfFirst)) == prf)
    #expect(Hex.encode(G.bytes(o.assertion.prfFirst)) == prf)
    #expect(Hex.encode(SoftPasskey.prf(secret: G.prfSecret, salt: G.prfSalt)) == prf)

    let key = try P256.Signing.PublicKey(x963Representation: o.publicKey)
    func verifies(_ signature: Data, _ authData: Data, _ clientData: Data) throws -> Bool {
      key.isValidSignature(
        try P256.Signing.ECDSASignature(derRepresentation: signature),
        for: authData + Data(SHA256.hash(data: clientData)))
    }
    #expect(
      try verifies(
        try Hex.decode(try ass.string("signature_der_hex")), try Hex.decode(try ass.string("authenticator_data_hex")),
        try Hex.decode(try ass.string("client_data_json_hex"))))
    #expect(try verifies(o.assertion.signature, o.assertion.authenticatorData, o.assertion.rawClientDataJSON))
  }

  @Test("with nothing fixed, a registration still draws a new key and a 16-byte id each time")
  func randomByDefault() async throws {
    let p = SoftPasskey(rpID: G.rpID, origin: G.origin)
    try p.fixNext(privateScalar: G.privateScalar, credentialID: G.credentialID, prfSecret: G.prfSecret)
    let options = CreationOptions(challenge: G.registrationChallenge, rpID: G.rpID, userID: G.userHandle, userName: "golden")
    let first = try await p.register(options, prfSalt: nil)
    let second = try await p.register(options, prfSalt: nil)
    let third = try await p.register(options, prfSalt: nil)
    #expect(first.credentialID == G.credentialID)
    #expect(second.credentialID.count == 16 && third.credentialID.count == 16)
    #expect(second.credentialID != third.credentialID)
    #expect(throws: PasskeyError.self) {
      try p.fixNext(privateScalar: Data(count: 32), credentialID: G.credentialID, prfSecret: G.prfSecret)
    }
  }
}
