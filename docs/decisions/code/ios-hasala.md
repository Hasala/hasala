# iOS platform adapters, package layout, API client and categorization: decisions from the code (2026-11-21)

These decisions were code comments under `ios/Hasala/Platform/`, `ios/HasalaCore/Package.swift`,
`ios/HasalaCore/Sources/HasalaCore/Auth/` and `ios/HasalaCore/Sources/HasalaCore/Categorize/`. Code
comments are not permitted (`scripts/comment-lint.ts`), thus the decisions are here.

## The approval key needs a device passcode, and the simulator uses a software key

The device approval key (spec 04 §6.1.3; spec 01 §4.9) is a Secure Enclave key. It exists only
while the iPhone has a passcode. Data protection needs a passcode too. Thus onboarding step 0
(spec 04 §6.6) requires a device passcode for both sign-in methods. Do not remove this step for
one sign-in method. Without a passcode, the approval key cannot be made.

The simulator has no Secure Enclave and no passcode. Debug simulator runs use a software P-256
key. It has the formats of the Secure Enclave key (a 65-byte X9.63 public key, 64-byte raw
signatures), so the server cannot tell the two apart. This key is in the UserDefaults domain of
the app, readable after the first unlock, and it signs with no prompt. It is not in the
Keychain, because the Keychain class of the approval key needs a device passcode.

The software key is compiled only for `DEBUG && targetEnvironment(simulator)`. Do not make this
condition wider. A device build or a Release build with this key has an approval key with no
Secure Enclave and no user presence.

Applies to: `ios/Hasala/Platform/ApprovalKey/SimulatorApprovalKey.swift` (`SimulatorApprovalKey`),
`ios/Hasala/Platform/Notifications/SystemNotificationPermission.swift` (`DevicePasscode`).

## Background tasks register before launch ends, and a refused request is not an error

The app has two BGTaskScheduler tasks (spec 04 §7.9). Their identifiers are in
`BGTaskSchedulerPermittedIdentifiers` of Info.plist. The refresh task is the floor that keeps
mail catch-up going when silent pushes are throttled. It is submitted again on every run. The
processing task (network required) does the first-connect scan and the backfill pages.

- BGTaskScheduler accepts launch handlers only before the app finishes launching. Thus
  `register()` runs one time, from the `init` of the App. A later call is a crash.
- The work is installed later, when an account runtime exists. A task that fires with no work
  installed (signed out, or before the first unlock) completes at once with success. It must
  not report a failure.
- BGTaskScheduler refuses a request in the simulator and when Background App Refresh is off.
  The refusal is only logged. Foreground runs still catch up. Do not show it as an error.
- `BGTask` is not Sendable, but the system permits its completion from any thread. Thus the
  box that carries it into the work task is `@unchecked Sendable`.

Applies to: `ios/Hasala/Platform/Background/BackgroundScheduler.swift` (`register`, `submit`,
`handle`, `TaskBox`), `ios/Hasala/App/HasalaApp.swift`.

## The APNs environment comes from the provisioning profile, and an unknown one registers no token

The server stores each device token with its APNs environment (`PUT /push/apns`, spec 06 §11).
A token registered in the wrong environment makes every wake fail. Thus the app sends no token
while it cannot tell the environment. Foreground refresh and background catch-up read mail
without push, so nothing depends on the token.

The environment is the `aps-environment` entitlement of the embedded provisioning profile
(spec 06 §11.3):

- No profile file means `production`. The App Store and TestFlight remove the profile.
- A profile that cannot be read, or that has no usable value, is unknown.
- The simulator is always unknown. Its tokens are not used for QA (spec 06 §11.1; wakes there
  are tested with `xcrun simctl push`, which needs no registered token). An unsigned simulator
  build has no profile, and without this rule it would read as `production`.
- A profile is a CMS envelope with an XML property list in the clear. The app does not verify
  the signature. The answer only selects the gateway for a token, so a forged profile gains
  nothing.

The app remembers a digest of the last account, token and environment that it sent, never the
values (spec 04 §4.5). A launch with the same token sends nothing. Do not store the token or
the account id in UserDefaults.

Applies to: `ios/Hasala/Platform/Delivery/APNsEnvironment.swift` (`APNsEnvironmentResolution`,
`resolveAPNsEnvironment`, `APNsProfile`), `ios/Hasala/Platform/Push/PushRegistrar.swift`
(`PushRegistrar`).

## OAuth redirect schemes are not registered URL types

The mailbox sign-in uses `ASWebAuthenticationSession` with a custom callback scheme: the
reversed client id for Google, `msauth.app.hasala.ios` for Microsoft. These schemes are not in
`CFBundleURLTypes` (spec 06 DV-2). The session captures the redirect itself. Thus no other app
and no web page can open Hasala with a forged authorization code.

Do not add a URL type for these schemes. `ios/scripts/inspect-ipa.sh` check I4 refuses an
`.ipa` that has `CFBundleURLTypes`.

Google shares the session of Safari, because the person is usually signed in there already
(PO-4), and Google always shows its account chooser. Microsoft gets a private session
(`MailProviderID.prefersEphemeralSession`).

Applies to: `ios/Hasala/Platform/GmailAuth/WebAuthenticationPresenter.swift`
(`WebAuthenticationPresenter`), `ios/Hasala/Platform/Delivery/BuildInfo.swift`
(`googleRedirectScheme`, `outlookRedirectScheme`).

## HasalaCore package: layers, the HasalaText name and pinned packages

`ios/HasalaCore/Package.swift` declares every module of the spec 04 §2.2 map, one time. The
layers are the target graph: a module depends only on modules in a lower layer, or on the
modules that §2.2 lists for it.

- The compiler enforces only a part of this. SwiftPM lets a target import each module that its
  dependencies link (for example, a `Sync/` file could `import GRDB`). `ios/HasalaCore/imports.allow`
  and `ios/scripts/check-imports.sh` close this hole. Each directory imports only its declared
  dependencies and its §2.3 system modules. When you add a dependency to a target, add it to
  `imports.allow` too.
- The `CoreText` module of §2.2 (`Text/`) has the name `HasalaText`. A package module with the
  name `CoreText` shadows Apple's CoreText framework. Then the package does not build for iOS
  (the dependency scan of GRDB resolves `CoreText` to this module), and a client that links
  the two cannot get `CTFont*`. Do not rename it back.
- There are two third-party packages, each pinned with `exact:` (spec 04 §2.1; recorded in
  `NOTICE`): GRDB (MIT), which only CoreStore and CoreProjection link (R6), and
  swift-collections (Apache-2.0) for OrderedCollections. Do not add a third package without a
  decision.
- `HasalaKeychain` is an adapter outside layers L0 to L4, as `HasalaModel` is. It needs
  Security, which §2.3 keeps out of L0 to L4 (spec 04 §4.4). It is in the package, not in the
  app target, so that its query logic runs under `swift test`. Only the app links it.

Applies to: `ios/HasalaCore/Package.swift`.

## A test target links only what its files import

A `<Module>Tests` target links its own module. It links CoreTestSupport, or a module outside
the dependencies of its own module, only when its files use it (`testDependencies`). The
conformance target also declares only the modules that its files import.

The reason is the build time. CoreTestSupport depends on every layer, GRDB included. A test
target that declares it cannot start to compile until the full graph is built, and it compiles
again when something in L3 or L4 changes. Do not give CoreTestSupport to all test targets.

Applies to: `ios/HasalaCore/Package.swift` (`testDependencies`, `HasalaCoreConformanceTests`).

## The session token goes only to the API origin, in the Authorization header

- A credential never goes in the path or the query of a request (`02` §6.1). The session token
  goes only in `Authorization: Bearer` (spec 04 §6.4).
- A request path must stay on the origin of the API base URL. The path must be absolute and
  must not start with `//`, because a URL resolver reads `//` as a new host. The resolved URL
  must keep the scheme, the host and the port. A path that fails gives no request. Without
  this check, a path from data could send the bearer token to a different host.
- The URLSession is ephemeral: no cookies, no URL cache, no credential storage. Thus Foundation
  writes nothing about a call to disk. Do not change it to the default or shared session.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Auth/Transport.swift` (`APIRequest`),
`ios/HasalaCore/Sources/HasalaCore/Auth/URLSessionTransport.swift` (`URLSessionTransport`,
`urlRequest(for:)`).

## WebAuthn bytes go to the server as the authenticator returned them

The app keeps the raw `clientDataJSON` and `attestationObject` of a passkey ceremony and sends
them unparsed (base64url, no padding; spec 04 §6.1.1). It does not decode them and encode them
again.

The reason: the `auth_hash` of BootstrapPayload (D17, R-01), RecoverySigninMessage (D18) and
PasskeyAddMessage (D33) hash these exact bytes. A second encoding can change a byte, and then
the server refuses the signature.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Auth/WebAuthn.swift` (`RawRegistration`,
`RawAssertion`, `PublicKeyCredentialJSON`).

## The PRF output of a passkey result has one owner

`RawRegistration` and `RawAssertion` are `@unchecked Sendable`. Their `prfFirst` is a
`SecureBytes` value that goes from the authenticator to one ceremony. That ceremony wipes it,
and nothing changes it before that. Do not give one result to two ceremonies or keep it after
the ceremony: the second reader gets wiped bytes, or the two race.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Auth/WebAuthn.swift` (`RawRegistration`,
`RawAssertion`).

## Merchant canonicalization and matching are byte-exact, and regex rules do not run

Canonicalization (spec 03c §5.2, §8.2) splits on the `unicode.IsSpace` set of Go, joins with
one U+0020, then makes each scalar lower-case with the simple mapping of Go (U+0130 gives `i`;
there is no Final_Sigma context). It does no Unicode normalization: an NFC spelling and an NFD
spelling stay different. The matcher compares UTF-8 bytes (equal, prefix, containment).
Containment of scalars and containment of UTF-8 agree, because UTF-8 is self-synchronizing.

These are byte-exact modules (spec 04 §2.4 R2): no `lowercased()`, no `String ==` on content,
no iteration by `Character`. `String ==` equates NFC and NFD, and then the phone and the
`conformance/categorize` fixtures give different results. `ios/scripts/check-forbidden.sh`
enforces a part of this.

The total order of hits is that of spec 03c §5.2. Each user rule comes before each dictionary
entry. A rule or an entry that the matcher refuses is a reported defect. It is never dropped
silently. `disabled` and `removed` are states, not defects.

The v3 regex rules are not executed, because v4 has no regex (spec 04 §2.2). Such a rule is a
`regex_not_supported` defect. `conformance/categorize` marks the cases that need a regex
executor with `requires: ["regex"]`, and the Swift suite skips them. This is the decision, not
a gap. Do not add a regex executor to get these cases to run.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Categorize/Canon/Canon.swift` (`Canon`),
`ios/HasalaCore/Sources/HasalaCore/Categorize/Matcher.swift` (`Matcher`).

## The fold does not read the taxonomy, the case tables or a model

Three parts of categorization run in the pipeline, the author and the readers, and never in the
fold (spec 03c §1.11):

- Taxonomy v1 (spec 03c §4.1). The 18 built-in categories are implicit constants that each
  account has with no op. A `category_defined` with a built-in id overrides it. Readers and the
  pipeline apply the taxonomy; the fold does not (§1.11 rule 3).
- Canonicalization and the Latin gate. They use the Unicode tables of the OS (case mapping,
  general category), and these can change with an OS version.
- The model tier. All of categorization is local to the device and deterministic except this
  tier. Its answers only become authored ops. They are never computed at fold time.

If the fold reads one of these, two iPhones can fold the same log to different results.

The taxonomy is in CoreCategorize, because that is the lowest module that needs it (the
dictionary gate and `decide`). `TaxonomyView` of CoreDomain and the projection build on it.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Categorize/Taxonomy.swift` (`TaxonomyV1`),
`ios/HasalaCore/Sources/HasalaCore/Categorize/CoreCategorize.swift`,
`ios/HasalaCore/Sources/HasalaCore/Categorize/Canon/Canon.swift`,
`ios/HasalaCore/Sources/HasalaCore/Categorize/LatinGate.swift`.

## The model's Latin gate uses fixed tables

Apple's model does not read Arabic reliably. Thus the gate before the Foundation Models tier is
on the script of the merchant subject (spec 03c §8.6.2). It is not on the languages that the SDK
reports as supported. Do not replace the gate with a question to the SDK.

The gate uses fixed tables: no ICU and no script detection. A subject passes only when it has
3 or more letters, each letter is in the `LATIN_V1` ranges, each digit is ASCII, each combining
mark is in U+0300 to U+036F, and each other scalar is printable ASCII or U+00A0. The one Unicode
lookup is the general category, which tells letters from marks.

Applies to: `ios/HasalaCore/Sources/HasalaCore/Categorize/LatinGate.swift` (`LatinGate`).
