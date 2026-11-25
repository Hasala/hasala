# Server config, console, crypto reference, dictionary and Gmail push: decisions from the code (2026-11-21)

These decisions were code comments under `server/internal/config`,
`server/internal/console`, `server/internal/cryptoref`, `server/internal/dict` and
`server/internal/gmailpush`. Code comments are not permitted
(`scripts/comment-lint.ts`), thus the decisions are here.

## Behind Cloudflare the server refuses a raw secret value

A secret has no TOML key. It comes as a path in a `*_FILE` variable, which systemd fills
with `LoadCredential=` (spec 02 §18.1). The server refuses a secret file that a group or
other users can read.

With `server.trusted_proxy = cloudflare` (the posture of the QA host), the server also
refuses to start in these cases:

- A variable with a name `HASALA_*_KEY`, `HASALA_*_TOKEN` or `HASALA_*_SECRET` has a
  value. A raw value in the environment shows in `/proc` and in `systemctl show`.
- A database DSN carries a password, or `PGPASSWORD` is set. The QA host reaches
  Postgres only with peer authentication, so a password there is an error of the
  deployment.

With `trusted_proxy = none` (local runs and tests) the raw values are permitted. Do not
relax the rule for the Cloudflare posture, and do not add a TOML key for a secret. A
secret then stays in a file or a process listing that other users of the host can read.
The unit side of this rule is in `docs/decisions/code/github-to-ios.md` ("Secrets reach a
unit only as credential files").

Applies to: `server/internal/config/config.go` (`refuseRawSecrets`, `CheckSecretFile`).

## Operator arguments come only from the command line

The arguments of the operator modes (`purge-user`, `verify`, `migrate`) have no TOML key
and no environment variable. The command line is the one source.

The reason: the question "which account does this command delete" or "which invite does
it mint" must have its answer in the command that ran, and in no other place. An
environment variable or a file that stays from an earlier run could select a different
account. Do not add a `HASALA_*` variable or a TOML key for these arguments.

Applies to: `server/internal/config/config.go` (`Config.Purge`, `Config.Verify`,
`Config.Migrate`).

## A value that is compared exactly is shape-checked at start

Two configuration values are compared exactly, byte for byte, with a claim in a token
from a provider. The server examines their shape when it loads the configuration:

- `gmail.pubsub_service_account`. The Gmail hook compares the email of the Pub/Sub push
  token with this value. A value with a typing error gives no error at start. Each push
  then gets 403, and Gmail wakes stop silently.
- `outlook.client_id`. Microsoft writes the application id in the `aud` claim in lower
  case. The audience check is exact. Thus the configuration accepts the id only in lower
  case, and an upper-case id cannot make each Outlook link fail.

Do not make these shape checks looser. The failure that they prevent shows only as
refused requests in production.

Applies to: `server/internal/config/config.go` (`validateGmail`, `isServiceAccountEmail`,
`uuidShape`, `validateOutlook`).

## serve and the console refuse the environment of each other

Fence F7-4 (spec 07 §8.1) has two halves in the server itself:

- `hasalad serve` refuses to start while a `HASALA_CONSOLE_*` variable, a `HASALA_ASC_*`
  variable or `HASALA_TESTFLIGHT_MODE` is set. Thus a unit with incorrect wiring cannot
  turn the public process into a console, and cannot give it an App Store Connect key.
  No build reads the last two names now (`docs/decisions/testflight-manual.md`). The
  refusal stays, because a unit that carries one has incorrect wiring.
- `hasalad console` refuses to start while one of the secret files of `serve` is named
  (the auth key, the salt key, the APNs key, the route key, the email token, the
  Turnstile secret).

This is a second barrier behind the two systemd units
(`docs/decisions/code/github-to-ios.md`, "The console and the API share no
credential"). Do not remove a name from the two lists. When `serve` gets a new secret,
add it to the list of the console.

Applies to: `server/internal/config/config.go` (`CheckServeEnvironment`,
`CheckConsoleEnvironment`).

## A systemd credential file can show group bits

systemd writes a `LoadCredential=` file as root, with mode 0400, and gives the user of
the unit read access through an ACL (spec 05 §5.5). `stat` then shows the ACL mask in the
group bits (0440), although no group can read the file. Only the unit can reach the
credentials directory.

Thus the server accepts group bits on a secret file only when the file is directly in
`$CREDENTIALS_DIRECTORY`. Each other secret file must have no permission for group and
other. A permission for other is refused in the two cases.

Do not apply the strict rule to credential files: `hasalad` then does not start under
systemd. Do not apply the loose rule to other paths: a file that a group can really read
is then accepted.

Applies to: `server/internal/config/config.go` (`CheckCredentialFile`,
`InCredentialsDirectory`, `CheckSecretFile`).

## The console holds no key and sends no mail itself

The operator console (spec 07 §8) runs as its own process, `hasalad console`, on its own
loopback port. The LAN proxy in front of it sets the tailnet identity. The console holds
no mail token and no auth key. Each email that it causes is a queued `mail_log` row, and
the mail worker of `serve` sends it.

Do not give the console the mail token or the auth key to send a mail directly. The same
rule for the CLI modes is in `docs/decisions/code/scripts-to-server.md` ("Operator modes
hold no auth key and send no mail").

Applies to: `server/internal/console/console.go`.

## The console sends Referrer-Policy same-origin

The console sends `Referrer-Policy: same-origin`, not `no-referrer`. With `no-referrer`
a browser sends `Origin: null` on the form POSTs of the console itself (Fetch, "append a
request Origin header"). Each console action needs same-origin evidence, so it refuses
all these POSTs.

Nothing leaves the console with a referrer under the two policies, so `same-origin`
loses nothing. Do not change the policy to `no-referrer`: each action of the console
then answers 403.

Applies to: `server/internal/console/console.go` (`Console.Handler`, `Console.action`).

## A printed invite code is shown one time and is never in a URL

When the console mints an invite code with no address, it writes the code into the body
of the answer to that POST. The code is not stored (the database keeps only a hash), and
it is never in a URL.

Do not change this to a redirect with the code in the query or the path, and do not keep
the code in a flash value. A URL stays in the browser history and in the log of the
proxy. The page that shows the code cannot be loaded again, and that is intended.

Applies to: `server/internal/console/console.go` (`Console.actionThen`).

## The console health listener is outside the identity check and names no person

The console has a second listener (`HASALA_CONSOLE_METRICS_LISTEN`, spec 07 §13.3) with
`GET /healthz` for probe P8 and `GET /metrics` for Prometheus. It is not behind the identity check of the console, because
Prometheus and the health probe reach it on loopback with no tailnet identity.

Thus its body must say nothing about a person. It reports only the database, the App
Store Connect key and the number of requests with a Cloudflare header that reached the
console in the last 24 hours. One such request turns the answer to 503 for 24 hours, so a
leak of the tunnel to the console pages the owner.

The count is in memory, and a restart forgets it. This is intended: each refusal is also
an ERROR line in the journal, and Prometheus keeps the history of the counter below, so
the console needs no table for it. Do not add a field with an address, a login or an
account id to this body.

`/metrics` is the Prometheus text format, written by hand, so the server has no
Prometheus dependency. It has three series and no labels:

- `hasala_console_tunnel_refusals_total`: a counter of the refused requests since the
  process started. It does not stop at the 1024 entries that the 24-hour window keeps.
- `hasala_console_tunnel_refusals_24h`: the number that `/healthz` reports.
- `hasala_console_db_up`: 1 or 0.

The same rule applies to `/metrics`: no series and no label may name a person.

Applies to: `server/internal/console/health.go` (`Console.HealthHandler`, `HealthBody`,
`refusalLog`).

## `hasalad serve` has no metrics listener

`server.metrics_listen` (`HASALA_METRICS_LISTEN`) was a setting that the configuration
validated and that nothing served. It is removed, with the `metrics.port` option and the
`hasala` Prometheus job of the QA module, so an operator cannot set a value that gives no
endpoint. A TOML file that has the key is refused as unrecognized, and the environment
name gets the warning for a name that this build does not read.

Add the setting again in the same change that serves the endpoint of spec 02 §20.1.

Applies to: `server/internal/config/config.go` (`ServerConfig`),
`infra/qa/nix/module.nix`.

## The reference packages stay outside hasalad

Three packages of the server module are references for tests and fixtures. The build
graph of `cmd/hasalad` must not reach them, and `fence_test.go` asserts that (spec 02
§4.4):

- `internal/cryptoref` and `internal/cryptoref/vectors`: the Go reference for the
  cryptography of the device (spec 01 §4 to §6). The server holds no data key. It never
  seals, opens, unwraps or stretches something (fences 3 and 5). The package exists so
  that `cmd/gen-crypto-vectors` can write `conformance/crypto-v3/`, and so that the Go
  tests can open what the Swift client writes (spec 01 §15.2).
- `internal/dict`: the canonicalization and match rules of the merchant dictionary. It is
  the oracle that `conformance/dict/matching.json` pins (spec 02 §4.1, D-2, fence 1). The
  dictionary is in the app (spec 03c §8.5), and `server/oracle/cmd/export-dictionary`
  makes it. The server does not learn which merchants a person pays (spec 02 §2.3, A-11).

Do not import these packages from code that `hasalad` links. An import puts encryption
code or merchant matching into a server that must stay blind.

Applies to: `server/internal/cryptoref/keys.go`,
`server/internal/cryptoref/vectors/vectors.go`, `server/internal/dict/dict.go`,
`server/cmd/hasalad/fence_test.go`.

## Go writes the crypto vectors, and each run gives the same bytes

Go owns `conformance/crypto-v3/` (spec 01 §15.1) and `conformance/api-v1/messages.json`
and `stepup.json` (spec 02 §22). Go writes the expected values. The Swift client reads
them and never writes them again. No test harness computes its own expected value
(critic §5.5), because a harness that does this agrees with itself also when it is wrong.

The generator must give the same bytes on each run, because
`TestCommittedVectorsAreCurrent` makes all files again and compares them with the
committed files byte for byte:

- Each input is fixed: the anchors of spec 01 §15.5, and values from a seed or a pattern.
- The anchor inputs are in one file (`anchors.go`). Each generator and each test takes
  them from there. Thus an input cannot differ between the file that writes a vector and
  the test that pins it. Do not copy an anchor input into a test.
- The Ed25519 signatures of Go are deterministic, so the printed signatures are compared
  and verified.
- P-256 signing is the one randomized primitive. The generator gives it a fixed byte
  stream, so the sample signatures are stable bytes. A reader must only verify them and
  never compare them: the signatures of CryptoKit are different on each run.

Applies to: `server/internal/cryptoref/vectors/vectors.go` (`Generate`, `stream`),
`server/internal/cryptoref/anchors.go`.

## The reference reader follows the order of the spec literally

`cryptoref.ReadPage` is the Go reference for the order of checks of the frame reader
(spec 01 §6.6, R0 to R10, with R2b of §7.1). The reader of the device is the Swift one.
The Go reader exists so that the generator can write what each tamper case must give,
and so that the Go tests can examine it.

It is literal on purpose: each step is in the order of the spec, and the first step that
fails decides the result. Do not merge steps, change their order or add a shortcut for
speed. The expected results in `conformance/crypto-v3/tamper.json` come from this reader.
A different order changes which error a tampered row gives, and the Swift reader then
follows a wrong fixture.

Applies to: `server/internal/cryptoref/reader.go` (`ReadPage`, `ReaderState.open`).

## The dictionary fixture carries the answers of Go for each primitive

The Go side canonicalizes a merchant pattern and decides if it is permitted. The phone
canonicalizes a merchant with the same rules and decides if the pattern matches. Nothing
between them examines that the two agree. When they do not agree, there is no error: the
pattern does not match on a phone, and nobody sees why. Thus
`conformance/dict/matching.json` has the answers of Go, and the client tests compare the
answers of the device with them.

The primitives of the two languages do not agree by default. These four cases are known
(they came from the earlier JavaScript client; a language with full Unicode case mapping
has the same risk):

- U+0085 is white space for `unicode.IsSpace` of Go and is not in the `\s` set of
  JavaScript.
- U+FEFF is the opposite: in `\s`, not in `unicode.IsSpace`.
- U+0130 becomes one code point with `strings.ToLower` (the simple case mapping of
  Unicode) and two code points with a full case mapping (`i` and U+0307).
- A capital sigma at the end of a word becomes U+03C2 with a full case mapping (the
  Final_Sigma condition) and U+03C3 in Go, which has no context.

The sections of the fixture:

- `limits`: the numbers that the two sides hard-code, with the 4-rune floor of
  `contains`. A device cannot apply a different floor.
- `space` and `lower`: the two primitives, one code point at a time. A fixture with only
  complete strings also finds a divergence, but it does not say which primitive is
  wrong. Keep the probes on which the languages disagree. The `lower` probes are in
  base64, because some of them differ only in code points that a diff does not show.
- `canonical`: the verdict of `Canonicalize` for complete entries. The verdict is a
  boolean (`ok`), not a reason text. The reason is the wording of Go, and the device has
  its own codes. A fixed text in two languages fails falsely after a rename.
- `match`: the `contains` and `exact` verdicts. Postgres computes them
  (`position(pattern IN other) > 0`, or equality).

No Go matcher exists, on purpose. The server does not categorize. A Go copy of the
matcher of the device is a function that nothing calls, with green tests, and it drifts
from the two sides.

Applies to: `server/internal/dict/conformance_test.go` (`buildDictFixture`,
`sqlMatches`, `TestTheFixtureCarriesBothSidesOfEveryDivergence`).

## A dictionary pattern has no regex, bounds in runes and a floor for contains

- The match types are `contains` and `exact`. There is no `regex`, on purpose. A regex
  that goes to each device is a denial-of-service risk, and the regex engines of two
  languages do not agree.
- The bounds on a pattern and on a category count runes, not bytes. A bound in bytes is
  three times tighter for an Arabic merchant name, with no sign of it.
- An `exact` pattern has 2 runes or more. A `contains` pattern has 4 runes or more. A
  `contains` pattern is a substring test that runs on each device. A short one is a
  wildcard: `on` matches many unrelated merchants. The number four is measured: the 212
  seeded v1 rules of the operator have 4 characters or more, so the floor refuses
  nothing real.

Do not add a regex match type, do not change the bounds to bytes, and do not lower the
`contains` floor. The fixture `conformance/dict/matching.json` carries these limits to
the device.

Applies to: `server/internal/dict/dict.go` (`MatchContains`, `MatchExact`,
`maxPatternRunes`, `minPatternRunes`, `minContainsRunes`, `maxCategoryRunes`).

## A dictionary error names the field, never the value

An error from `Canonicalize` names the field (`pattern`, `category`, `match`) and never
repeats the value. The value is a merchant text. An error that quotes it puts that text
into the output or the log of the operator.

Do not add the value to an error message of this package.

Applies to: `server/internal/dict/dict.go` (`Canonicalize`, `ErrInvalidEntry`).

## Line breaks are refused before whitespace is collapsed

`Canonicalize` examines the raw pattern and the raw category for a line break before it
collapses white space. A merchant name is one line. The collapse step changes each run
of Unicode white space, a line break included, into one space. Without the earlier check,
a paste of two lines becomes one pattern that looks valid, and it is not refused. Text
that is not a merchant name is then stored as one.

The check uses each line end that Unicode defines (also U+0085, U+2028 and U+2029), not
only `\n`. Do not move the check after the collapse step.

Applies to: `server/internal/dict/dict.go` (`Canonicalize`, `hasLineBreak`, `collapse`).

## A Gmail notice leaves nothing on the server

The server holds no Google credential. A Gmail Pub/Sub notice says only "this mailbox
changed" (`emailAddress` and `historyId`, spec 02 §13):

- The server examines the shape of `historyId` and then drops it. It is never stored and
  never in a log.
- The address is only in a local variable during one request. The database has only an
  HMAC of the address under the route key.

Do not store or log the `historyId` or the address, and do not pass them to a wake. A
`historyId` series shows how often a mailbox gets mail. That breaks "the server is
blind" (`CLAUDE.md`, "Decisions").

Applies to: `server/internal/gmailpush/gmailpush.go` (`ParseEnvelope`, `Notice`).

## The mailbox route HMAC is separated by provider and its Gmail bytes are frozen

The key of a mailbox link in the database is
`HMAC(route_key, "hasala/v1/mailbox-route" ‖ 00 ‖ provider ‖ 00 ‖ normalized address)`
(spec 02 §13.3).

- The provider is in the input. One address that is linked through two providers gives
  two unrelated values.
- The Gmail value is pinned by a test vector to the bytes that the server stored before
  Outlook existed. Do not change the domain string, the order of the parts, the provider
  string `gmail` or the address normalization. A change orphans each stored Gmail link:
  its notices route to nobody, and no error shows.
- The key for a provider subject (`SubjectHMACFor`, used when the provider gives a
  stable subject but no verified address) uses the provider string with `-sub`. Thus it
  never equals an address HMAC. The subject is compared exactly: it is not trimmed and
  not put in lower case. Do not normalize it.

Applies to: `server/internal/gmailpush/gmailpush.go` (`RouteKey.AddressHMACFor`,
`RouteKey.AddressHMAC`, `RouteKey.SubjectHMACFor`),
`server/internal/gmailpush/gmailpush_test.go` (`TestRouteKeyBytes`).
