# iOS scripts and tools: decisions from the code (2026-11-21)

These decisions were code comments under `ios/scripts/` and `ios/tools/`. Code comments are
not permitted (`scripts/comment-lint.ts`), thus the decisions are here.

The release sequence (archive, inspect, upload), the gate of `archive.sh` and the limits of
the content checks are in `CLAUDE.md` ("The iOS app"). The export-compliance answer and the
checks I4 and I9 are in `docs/decisions/export-compliance.md`. The reason for
`imports.allow` is in `docs/decisions/code/ios-hasala.md`. They are not repeated here.

## The archive is signed for development and the export is signed manually

`archive.sh` makes the archive with automatic development signing. xcodebuild uses the App
Store Connect API key with `-allowProvisioningUpdates` to make or refresh the development
profile. The export then signs again for distribution, manually (`ExportOptions.plist`). It
needs an "Apple Distribution" identity in a keychain of the Mac, and the App Store profiles
with the names "Hasala App Store" (the app) and "Hasala Widgets App Store" (the widget
extension).

The reason: the upload key has the App Manager role, and that role cannot use cloud-managed
distribution certificates. An export with automatic signing fails with this key. Do not
change the export to automatic signing while the key has this role. When the certificate
changes, make new profiles with the same names.

`archive.sh` never uploads. `upload.sh` is a different step on purpose: the owner reads
`summary.txt` between the two (spec 06 §10.1–§10.2).

Applies to: `ios/scripts/archive.sh`, `ios/scripts/ExportOptions.plist`.

## Build numbers: one for each UTC minute, never offered two times

The build number (`CFBundleVersion`) is `YYMMDD.1HHMM` in UTC (spec 06 §8).

- The literal `1` keeps the second component free of a leading zero. Thus two build numbers
  compare correctly, component by component, as integers, and the second component always
  has five digits. Do not remove it: `hasala_build_newer` refuses each other shape, and the
  form without the dot (`HASALA_MIN_IOS_BUILD`, `CLAUDE.md`) needs the fixed width.
- `build_number.sh` accepts only an instant with a zone (`Z` or an offset) and converts it
  to UTC first.
- Two instants in the same UTC minute give the same number. `archive.sh` claims the number
  with a `mkdir` without `-p` on `ios/build/<BUILD>/`. That `mkdir` fails when the directory
  exists, so a second archive in the same minute is refused (exit 21). It never uses again
  or overwrites the archive, the .ipa or the summary of the first one. Do not change it to
  `mkdir -p`.
- `upload.sh` writes the number to `ios/build/last-build-number` before the upload starts.
  App Store Connect can take the number even when altool fails or is interrupted. A number
  that was offered must never be offered again, so `archive.sh` and `upload.sh` refuse a
  number that is not newer (spec 06 §10.4). After a failed upload, make a new archive. A
  validation alone records nothing.

Applies to: `ios/scripts/build_number.sh`, `ios/scripts/archive.sh`,
`ios/scripts/upload.sh`, `ios/scripts/release-common.sh` (`hasala_build_newer`,
`hasala_record_build`).

## The App Store Connect key is one file, named for its id, outside the repository

`asc_resolve_key` (spec 06 §9) gives the key to `archive.sh` and `upload.sh`. Nothing about
the key is in the repository.

- The key id and the issuer id come from the environment. If one is not set,
  `~/.config/hasala/asc.env` is read. That file is sourced as shell, so it runs as code in
  the release shell. Thus it must belong to the user and have mode 0600 or 0400; else it is
  refused. The two ids are not secrets. The `.p8` is a secret, and it never leaves its file.
- The key file must have the name `AuthKey_<ASC_KEY_ID>.p8`. altool finds a key by this
  name, and the rule stops an `ASC_KEY_PATH` that points at the key of a different id.
- The key file must be outside the repository. The script finds the repository from its own
  path, not from git: a git that fails must not skip this check.
- altool (Xcode 27) reads the private key from `--p8-file-path`. Without that option it
  searches for `AuthKey_<id>.p8` in `./private_keys`, `~/private_keys`, `~/.private_keys`,
  `~/.appstoreconnect/private_keys` and then `$API_PRIVATE_KEYS_DIR`, in that sequence. An
  old copy in one of the first four would win. Thus `upload.sh` gives `--p8-file-path` with
  `ASC_KEY_PATH` exactly, and also sets `API_PRIVATE_KEYS_DIR` to the directory of that
  file. Do not remove `--p8-file-path`.
- `asc_resolve_key` returns 14 on each refusal (the key code of spec 06 §10.4). The callers
  run it as `asc_resolve_key || exit 14`. In that position `set -e` does not apply in the
  function, so each step in it examines its own status (`|| return 14`). A new step without
  this continues after a failure.

Applies to: `ios/scripts/asc-env.sh` (`asc_resolve_key`), `ios/scripts/upload.sh`.

## macOS tools are called by absolute path

The scripts also run in the Nix devShell (`.envrc`), where GNU coreutils, grep, sed and
findutils are first on PATH.

- A tool whose BSD form and GNU form are different (`stat`, `date`), or that only macOS has
  (`shasum`, `plutil`, `PlistBuddy`, `codesign`, `otool`, `lockf`, the system `python3`),
  is called by its absolute path. GNU `stat -f` has a different meaning. GNU `date` has no
  `-j`, and its `-f` reads a file of dates. A bare `stat -f` or `date -j -f` gives a wrong
  result or an error in the devShell.
- A tool that stays on PATH is used only in a form that is the same in the two
  (`grep -E/-q/-c/-a/-r`, `find`, `mkdir`, `tail`, `od -An -tx1 -N4`).
  `hasala_marketing_version` uses only bash, with no grep or sed.
- `screens.sh`, `test-release-surface.sh` and `e2e-app.sh` call the Xcode tools by path
  (`/usr/bin/xcrun`, `/usr/bin/xcodebuild`), and `screens.sh` removes `SDKROOT` for `xcrun`.
  The PATH and the `SDKROOT` of the devShell can shadow the tools and the SDK of Xcode.
- There is one exception. `archive.sh` calls `xcodebuild`, and `upload.sh` calls
  `xcrun altool`, through PATH. The offline tests put a stub first on PATH, and they stop
  when the script calls the tool by path.

`ios/scripts/tests/devshell_test.sh` runs the release-script tests in the devShell. It first
makes sure that the shell puts GNU `stat` and `date` first, so a pass has a meaning.

Applies to: `ios/scripts/release-common.sh`, `ios/scripts/asc-env.sh`,
`ios/scripts/build_number.sh`, `ios/scripts/inspect-ipa.sh`, `ios/scripts/check-bundle.sh`,
`ios/scripts/screens.sh`, `ios/scripts/test-release-surface.sh`, `ios/scripts/e2e-app.sh`.

## The scripts fail closed

A check passes only when it read all that it must read. A tool that fails and a file that
is missing are failures, never "nothing found". These rules keep that property:

- An absence check uses `hasala_absent`. It is true only when grep read each path and no
  line agrees (grep exit 1). A match (0) and an error such as a path that cannot be read
  (2) are false.
- Do not pipe a tool into `grep -q` for an absence check. With `pipefail`, `grep -q` exits
  at the first match, the writer gets SIGPIPE (141), the pipeline fails, and `! ...` changes
  that into a pass. Write the output of the tool to a file, then give the file to
  `hasala_absent`. `check-imports.sh` uses a here-string and not `printf | grep -q` for the
  same reason: there an early match makes the pipeline fail.
- A listing must prove that it is a listing. I8 passes only when the `otool -L` output names
  libSystem. I9 passes only when `nm -g` gives a listing for each Mach-O and the main binary
  is one of them. Do not remove these conditions as unnecessary.
- `inspect-ipa.sh` makes each of its inputs one time (the entitlements, the plists as XML).
  A failure leaves the file missing or empty, and each check that reads it then fails.
- `archive.sh` assigns the output of `git status --porcelain` to a variable first. With
  `set -e`, a git that fails stops the script there. Inside `[[ -n "$(git ...)" ]]` a git
  that fails gives an empty string, and the tree reads as clean.

Each of these faults occurred one time, and `ios/scripts/tests/inspect_ipa_test.sh` has a
case for each: I12 piped `strings` into `grep -q`, so a large binary with a dev host near
its start passed; I7 skipped binary files; I12 and AT-REV-4 read only the main binary; I12
searched only lower case; an .ipa that unpacks to mode 000 left the temporary directory.

Applies to: `ios/scripts/release-common.sh` (`hasala_absent`, `hasala_grep_absent`),
`ios/scripts/inspect-ipa.sh`, `ios/scripts/check-bundle.sh`, `ios/scripts/archive.sh`,
`ios/scripts/check-imports.sh`.

## inspect-ipa.sh inspects a private copy and always removes it

- The script copies the .ipa into its temporary directory, and it hashes and unpacks that
  copy. Thus the SHA-256 in the PASS line is of the bytes that were inspected. `upload.sh`
  compares this value with the file that it uploads. If the script hashed the file at its
  first path, a change of that file during the inspection could pass.
- The temporary directory is made by name under `$TMPDIR` (else `/tmp`). On macOS,
  `mktemp -d` alone does not obey `TMPDIR`; it uses `_CS_DARWIN_USER_TEMP_DIR`. The mode-000
  test sets `TMPDIR` and makes sure that nothing stays there. With a bare `mktemp -d` that
  test proves nothing.
- The .ipa sets the modes of the files that it unpacks. A directory without `u+rwx` makes a
  plain `rm -rf` fail, and the directory stays. Thus the exit trap first runs
  `chmod -R u+rwx`.
- The two commands of the trap must not change the exit code, because `set -e` also applies
  in the trap. Each one ends with `|| true`.

Applies to: `ios/scripts/inspect-ipa.sh`, `ios/scripts/tests/inspect_ipa_test.sh`.

## Content searches read each plist as XML and find the mock by its type names

The content checks of `inspect-ipa.sh` (I7, I12, AT-REV-4) search the bytes of each file in
the Payload. `CLAUDE.md` gives their limits (UTF-16 text, compressed data). Two more facts
give the checks their shape:

- A binary plist stores a string that has a character outside ASCII as UTF-16. A search of
  the bytes of that file does not find it. The XML form is UTF-8. Thus each file that
  `plutil` reads as a property list (Info.plist, the privacy manifest, `.strings`, nibs,
  `CodeResources`) is also converted to XML and searched. Info.plist must convert, or the
  checks fail.
- The Swift compiler keeps a string literal of 15 UTF-8 bytes or fewer in the instructions
  when the literal is written inline. No search of the bytes finds it. `-HasalaScenario` and
  `-HasalaScreen` are found only where a constant holds them. Thus AT-REV-4 also searches
  for the names of the types that only the mock build has: the launch hooks (`ScreenLaunch`,
  `MotionLaunch`, `JackpotLaunch`), the mock graph and the mock services. A build that
  compiles a type keeps its name in the type metadata, stripped or not.

When you add a Debug launch argument or a type that only the mock build has, add the type
name to `mock_terms`. A short argument alone does not make the check fail.

Applies to: `ios/scripts/inspect-ipa.sh` (`plist_text`, `in_no_file`, `mock_terms`).

## Checks that mirror App Store Connect rules

These checks exist because App Store Connect has the same rule, and it refuses the build
only after the upload:

- App Store Connect refuses an upload that uses a required-reason API which the privacy
  manifest does not declare (ITMS-91053). Thus `privacy-lint.sh` runs in the gate of
  `archive.sh`, before the build (spec 06 §5.4). A declared category with no use is only a
  warning, because a use through a wrapper can be indirect. GRDB has its own manifest (spec
  06 §5.3) and is not scanned.
- App Store Connect refuses an extension whose two versions are different from the versions
  of its app. Thus I3w compares `CFBundleVersion` and `CFBundleShortVersionString` of the
  widget extension with the app.
- Apple adds the entitlement `beta-reports-active` to an exported app. Thus I1 compares the
  entitlements with the golden file exactly, except this key and the sequence in arrays.

Applies to: `ios/scripts/privacy-lint.sh`, `ios/scripts/archive.sh`,
`ios/scripts/inspect-ipa.sh` (`widget_versions_match`, `ents_match`).

## Test overrides count only in test mode

The offline script tests move the build directory with `HASALA_BUILD_DIR` and pin the time
with `HASALA_TEST_NOW`. Each variable counts only together with `HASALA_TEST_MODE=1`, and
the script then says so on stderr. Without `HASALA_TEST_MODE=1` the variable is refused:
`archive.sh` and `upload.sh` exit 2 before they do anything.

The reason: a variable that stays in a release shell by accident must never move the builds
or `last-build-number`, and must never give a false build number. Do not make the scripts
ignore the variable silently, and do not make it count alone.

Applies to: `ios/scripts/release-common.sh` (`hasala_build_root`, `hasala_now`),
`ios/scripts/archive.sh`, `ios/scripts/upload.sh`.

## The project check generates from a copy and compares files only

`generate-project.sh --check` compares the committed `Hasala.xcodeproj` with a new one.

- XcodeGen reads the target folders. It lists Info.plist and the entitlements as build-file
  exceptions only if the files exist. Thus the check generates in a copy of the sources
  (`project.yml`, `Config`, the target folders and the two `Package.swift` files), not from
  `project.yml` alone. A project from `project.yml` alone is different from the committed
  one.
- Git keeps files, not directories, and Xcode leaves empty directories after a build (for
  example `project.xcworkspace/xcshareddata`). Thus the check compares only the files. A
  comparison of directories reports a stale project on a Mac that built the app.

Applies to: `ios/scripts/generate-project.sh`.

## The end-to-end harness is local, and it works around simulator limits

`e2e-app.sh` runs `LiveE2ETests` on two simulators against a local `hasalad`.
`e2e-hasalad.sh` runs the live suite of HasalaCore the same way.

- Nothing contacts a host other than 127.0.0.1. The mail of the server goes to
  `e2e/mail-capture.ts` (`HASALA_EMAIL_API_BASE_URL`), APNs is off, Gmail is not configured,
  and the app reaches the server through its Debug-only `HASALA_API_BASE_URL` launch
  override. Each address is `@example.test`. The environment sets no trusted proxy, because
  `hasalad` refuses a different email API base behind the Cloudflare proxy setting.
- The Postgres directory is in `/tmp`, not in `$TMPDIR`. The unix socket of Postgres is in
  that directory, and a socket path longer than 103 bytes makes the server fail to start.
  `$TMPDIR` on macOS is deep.
- The simulators run as processes of the host. Thus the test runner can read and write files
  under the temporary directory of the harness. The tests and the harness speak only through
  these files (the captured mail, the account of E1, the wake requests).
- The iOS 27 simulator refuses a push that has only `content-available` (UNErrorDomain 1401)
  and each push to an app without the notification permission (2003). Thus
  `e2e/wake.apns` has an alert together with `content-available`, and E1 permits
  notifications. This is for the simulator only. The real wakes of `hasalad` stay
  content-free; do not copy the alert to the server.
- The permission alert of the system does not always show on a new simulator. E1 then
  answers "Not now", and E3 reports the refused push as an expected failure, not as a pass.
  This is an accepted limit of the simulator.
- Signing (`HASALA_E2E_SIGNING`). The default, `adhoc`, signs with the identity `-`, manual
  style, no team and no profile, and sets `AppIdentifierPrefix` to the team prefix of the
  project. The simulator build then has the Debug entitlements (the keychain access groups)
  in its binary, so the Keychain operates and a new launch keeps the session. E3 to E5 need
  that. With `unsigned` (as CI builds) there are no entitlements, the Keychain refuses each
  call (`errSecMissingEntitlement`), the Debug build keeps secrets in memory, and E3 to E5
  cannot pass.

Applies to: `ios/scripts/e2e-app.sh`, `ios/scripts/e2e-hasalad.sh`,
`ios/scripts/e2e/wake.apns`.

## The HasalaCore grep lints: limits and word boundaries

`check-forbidden.sh` runs the grep lints of spec 04 §2.4 (R2, R3, R7, R8) on the sources of
HasalaCore.

- grep cannot see four things, and review must find them (§2.4): bare `/.../` regex
  literals, `String <`, `String.contains` or `range(of:)` on content, and iteration over
  `Character`. A pass of the lint does not prove that these are absent.
- The escape is for one file, and a reviewer examines it: a line
  `// lint-allow: <name> <reason>` permits the token `<name>` in that file. The lint reads
  this line. It is not an ordinary comment, and a tool that deletes comments must keep it.
- The lint writes its word boundaries in full (`(^|[^A-Za-z0-9_])` and `([^A-Za-z0-9_]|$)`).
  It does not use `grep -w`. `grep -w` also needs a boundary after the match, so a pattern
  that ends in `(`, such as `print(`, would not find `print(x)`.

Applies to: `ios/scripts/check-forbidden.sh`.

## Script tests make forbidden patterns at run time

The script tests do not contain a full pattern that the checks search for. The Outlook
message id shapes are made from a prefix and 44 synthetic characters. The "secrets" are
assembled when the test runs. Thus the repository holds no string that reads as a message
id or a secret. Do not write such a pattern in full in a test file.

Applies to: `ios/scripts/tests/check_bundle_test.sh`,
`ios/scripts/tests/inspect_ipa_test.sh`.

## Charset tables come from the registry of Go, not from the converters of Apple

`CharsetTables.swift` is generated (spec 04 §1.1, §2.2 CoreNorm). The chain is:

1. The charset registry of Go (go-message/charset and golang.org/x/text, which the Go
   normalizer uses).
2. `TestWriteTwinArtifacts` in `server/internal/norm` writes
   `conformance/normalizer/charset-tables.ts`. A Go test fails when that file is stale.
3. `ios/tools/charset-tables/generate.swift` writes `CharsetTables.swift` from that file.
   `CoreNormTests` parses the TypeScript file again and compares.

Thus the Swift tables are equal to the tables of Go by construction. The converters of the
platform (`String.Encoding.windowsCP1256`, `CFStringConvertEncoding`) are never used. They
obey the mapping tables of Apple, and these disagree with Go at positions that are not
defined (windows-1252 at 5 bytes, iso-8859-6 at 32), as a WHATWG `TextDecoder` does. A
platform converter would make the normalizer of the phone give bytes different from the Go
normalizer for some mail. Do not edit `CharsetTables.swift` or the TypeScript file manually.

Applies to: `ios/tools/charset-tables/generate.swift`,
`ios/HasalaCore/Sources/HasalaCore/Norm/CharsetTables.swift`.

## Seed templates are copied byte for byte

`ios/tools/templates/sync.swift` copies each seed template
(`server/internal/tmpl/seed/*.json`) into the app resources with no change to its bytes. It
reads the JSON only to get the id and the version for `TemplatesManifest.swift` (spec 04
§4.6). It never writes JSON again.

The reason: the Arabic anchors in the templates came from the source of ledgerd v1. They
must never go through a keyboard or a JSON serializer, which can change the bytes of a
string that looks the same. A changed anchor does not agree with the mail of the bank, and
the SHA-256 in the manifest no longer agrees with the seed. `CoreTemplateTests` also
compares the bundle with the seed directory, so a difference fails `swift test` even when
nobody runs the script.

Applies to: `ios/tools/templates/sync.swift`.
