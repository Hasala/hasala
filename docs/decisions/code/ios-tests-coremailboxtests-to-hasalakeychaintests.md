# iOS core tests, mailbox to Keychain: decisions from the code (2026-11-21)

These decisions were code comments under `ios/HasalaCore/Tests/CoreMailboxTests/`,
`ios/HasalaCore/Tests/HasalaCoreConformanceTests/` and
`ios/HasalaCore/Tests/HasalaCoreE2ETests/`. Code comments are
not permitted (`scripts/comment-lint.ts`), thus the decisions are here.

## A test that reads the private fixtures prints no fixture content

The private fixtures (`HASALA_PRIVATE_FIXTURES`) hold real bank mail. A test that reads
them must not put their content in its output: not in a failure message, not in a recorded
issue and not in a log line. The output of a test run can be copied to a pull request, an
issue or a CI log, and this repository is public.

What a test can print:

- the name of the fixture file or of the case, and the name of the field;
- a count (parsed, unparsed, matched);
- the offset of the first byte that is different;
- a JSON path, where each key is printed only when it has 40 characters or fewer and only
  the characters `a` to `z`, `0` to `9` and `_`. Each other key is printed as `<key>`,
  because it can be content.

A test must not print a value, a subject, a merchant, an amount or a body. The tests
compare first, and then they report only the names. Text is compared as UTF-8 bytes, not
as `String`, because `String ==` hides a difference between NFC and NFD.

A test of this kind is disabled by name when the variable is not set
(`[real-corpus] ...`), as `CLAUDE.md` says.

Applies to: `ios/HasalaCore/Tests/CoreMailboxTests/PrivateCorpusTests.swift`,
`ios/HasalaCore/Tests/HasalaCoreConformanceTests/JSONCorpusTests.swift` (`firstMismatch`,
`safeKey`), `ios/HasalaCore/Tests/HasalaCoreConformanceTests/NormalizerFixtureTests.swift`,
`ios/HasalaCore/Tests/HasalaCoreConformanceTests/TemplateFixtureTests.swift`,
`ios/HasalaCore/Tests/HasalaCoreConformanceTests/Support/Fixtures.swift`.

## The same DEFLATE stream as the conformance/ts frames is a measurement, not a contract

The contract for gzip is the decompressed payload
(`docs/decisions/code/ios-money-to-projection.md`). Two conforming compressors can write
different bytes for one input. Go's `compress/gzip` writes the OS byte 255, and Go's
`compress/flate` is not zlib, thus the streams of `conformance/blob` are different from the
streams of any zlib at level 9.

One stronger fact is true today, and one test pins it (`zlibMatchesTypeScript`): Apple's
system zlib and the Linux zlib that sealed `conformance/ts` write the same DEFLATE stream
and trailer at level 9. Only the OS byte of the header is different.

If an update of the OS changes the system zlib, that test fails, and only that test. This
is not a defect of `Gzip.compress`. Do not change the compressor to make the test pass
again. Record the new measurement, or remove the test. No stored frame is at risk, because
each frame is stored and sent as its author wrote it.

Applies to: `ios/HasalaCore/Tests/HasalaCoreConformanceTests/FrameFixtureTests.swift`
(`zlibMatchesTypeScript`).

## The JSON corpus test permits one difference from JSONSerialization

`JSONCorpusTests` parses each JSON file under `conformance/` with CoreJSON and with
Foundation's `JSONSerialization`, and the two must agree on each value. This is the only
use of `JSONSerialization`. The byte-exact modules do not use it
(`ios/scripts/check-forbidden.sh`).

`JSONSerialization` removes one U+FEFF at the start of a string value, as if it were a
byte-order mark. It keeps a U+FEFF at any other position. CoreJSON keeps the character, and
that is correct: spec 01 §15.1 puts inputs with U+FEFF in `phrase.json`. Thus the
comparison permits exactly this difference: CoreJSON's string has one more U+FEFF at its
start. It permits no other difference, and it does not permit the reverse.

Do not make CoreJSON remove the character to agree with Foundation. The recovery phrase
vectors would then fail. Do not make the comparison more tolerant.

Applies to: `ios/HasalaCore/Tests/HasalaCoreConformanceTests/JSONCorpusTests.swift`
(`firstMismatch`).

## The dialect corpus is one sequence in Go and in Swift

`conformance/dialect/patterns.json` holds a SHA-256 over the verdicts of the dialect
validator on a generated corpus of patterns. The digest is over the sequence: each pattern
and its reason codes, in the order that the generator gives them.

Go's `dialectCorpus()` (`server/internal/tmpl/conformance_test.go`) and Swift's
`DialectFixture.corpus()` are the same generator, written as the same nested loops over
the same literal lists. The Swift function is a transliteration, not a second design.

Change the two functions together, edit for edit, and write the fixture again
(`TestWriteDialectConformanceFixtures`). A change to one list, or to the order of one loop,
on one side makes the digest test fail although the two validators still agree.

Applies to: `ios/HasalaCore/Tests/HasalaCoreConformanceTests/DialectFixtureTests.swift`
(`DialectFixture.corpus`).

## The live recovery test makes exactly three recovery calls

`hasalad` permits three recovery calls an hour from one IP address (the `recover-ip`
limiter). The routes `recover/begin`, `recover/verify` and `recover/finish` share this
limit. The live recovery test (`ios/scripts/e2e-hasalad.sh`) runs from one address, thus it
makes exactly these three calls, one time each.

Do not add a recovery call to this test, for example a wrong code or a second begin. The
fourth call gets a rate-limit refusal and the test fails. The refusals of the recovery
routes are tested in the Go suite of the server.

Applies to: `ios/HasalaCore/Tests/HasalaCoreE2ETests/LiveRecoveryTests.swift`.

## The live tests make their accounts through the routes of the server

The live suites (`ios/scripts/e2e-hasalad.sh`) make each account as the app does: an
invite, `signup/begin`, the email code, then `password/register` or the passkey ceremony
(`Live.signUp`, `Live.passwordAccount`). The second iPhone signs in through
`password/login` or the passkey login (`Live.secondPhone`). No test writes a row into
`users` or `sessions`.

- Two things still go through SQL, because the harness has no mail sink and no operator
  CLI: the invite row, and the MAC of the email code (`Live.setCode` writes the MAC of a
  code that the test chose, with the auth key of the server).
- `SoftPasskey` signs for the relying party `hasala.app`, and the script starts `hasalad`
  with that relying party. Change the two together.
- Each suite makes at most 12 calls to the signup, sign-in and passkey routes, because
  `hasalad` refuses the thirteenth from one address and the script gives each suite a new
  server process (`ios-scripts-to-tools.md`). A password account with a second iPhone is
  5 calls. `LivePasskeyTests` makes 8. Put a new live account in a suite of its own.
- `NewAccountKeys` is wiped when the account is made. Thus `Live.passwordAccount` reads the
  words and the authority key before it calls `createWithPassword`.

Applies to: `ios/HasalaCore/Tests/HasalaCoreE2ETests/LiveHasaladTests.swift` (`Live`,
`LiveHasaladTests`, `LivePasskeyTests`),
`ios/HasalaCore/Tests/HasalaCoreE2ETests/LiveScenarioTests.swift` (`Live.twoRuntimes`).

## A regeneration of the Swift goldens changes every random file

`conformance/swift/` has one writer, the Swift executor
(`HASALA_WRITE_SWIFT_GOLDENS=1 swift test --filter SwiftGoldenTests`,
`conformance/README.md`). The other executors read these files: Go opens the frames, the
wraps and the phrase boxes, and verifies the signatures.

A regeneration writes every file again. The frames, the wraps and the signatures are
different bytes on each run, because the nonces, the salts and the signatures are random.
A large diff after a regeneration is thus not a sign of a change in behaviour. Regenerate
only when an input or a format changes.

Without the variable, the suite examines the committed files: the op cases encode to the
same bytes, each frame, wrap and box opens, each signature verifies and each stretched
password is the same. These checks read Swift's own output. They are not the cross-check.
The cross-check is the Go tests that read the same files, thus run them after a
regeneration.

Applies to: `ios/HasalaCore/Tests/HasalaCoreConformanceTests/SwiftGoldenTests.swift`.

## A time limit in a test counts the thread's processor time, and the fake network has no timeout (2026-11-26)

`swift test` runs all the tests of the package in one process and at the same time. On a
CI runner with three cores, a test can wait for a thread for more than a minute. In the
runs of 2026-11-25, tests with no work in them ended after 44 to 70 seconds. A limit on
elapsed time then measures the other tests, not the code.

`LongInputTests.timed` thus reads the processor time of its thread
(`CLOCK_THREAD_CPUTIME_ID`). Its body has no suspension point, so it stays on one thread.
The limit of 3 seconds stays. The slowest case, the Arabic card prefix at the size limit of
a text, uses about 1.1 seconds on the Mac of the owner.

`FakeGmailURLProtocol.exchange` sets the request and resource timeouts of its session to
one day. The default of URLSession is 60 seconds. The fake answers from memory, so a
timeout there can only come from a starved test process, and it reached the tests as
`.offline`. A test of a timeout uses a fake clock or its own exchange, not this session.

Applies to: `ios/HasalaCore/Tests/CoreExtractTests/LongInputTests.swift`,
`ios/HasalaCore/Sources/HasalaCore/TestSupport/FakeGmail.swift`.
