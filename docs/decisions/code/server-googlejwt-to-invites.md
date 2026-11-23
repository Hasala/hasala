# Google tokens, the disk fuse and invites: decisions from the code (2026-11-21)

These decisions were code comments under `server/internal/googlejwt`,
`server/internal/headroom` and `server/internal/invites`. Code comments are not
permitted (`scripts/comment-lint.ts`), thus the decisions are here.

## go-oidc and go-jose verify the signature; the pre-checks only refuse

`googlejwt` verifies two kinds of Google-signed token: the OIDC token that Pub/Sub puts
on each push to `POST /hooks/gmail/pubsub`, and the Google ID token that the app sends
when it links a mailbox (spec 02 §13.6, §2.3). It signs nobody in and it holds no Google
credential.

The signature check belongs to `github.com/coreos/go-oidc/v3` over go-jose. The package
parses no key material by hand and implements no algorithm. The key set fetches a
document, decodes it with go-jose's `JSONWebKeySet`, selects keys and calls go-jose's
`Verify`. To implement `oidc.KeySet` is the extension point that go-oidc supports;
go-oidc ships the same select-and-verify loop as `StaticKeySet`.

Before the signature check, the package parses the token without verification
(`parseUnverified`) and checks the header and the claims. These pre-checks have two
purposes only: they give a rejection its name, and they refuse obvious junk without a
JWKS fetch. Their output must be used only to reject. After go-oidc authenticated the
payload, each claim decision is made again on that payload, and the returned claims
(`azp`, `email`, `email_verified` and the others) come only from it.

Do not return a value from the unverified parse, and do not remove the second pass. Then
a claim that nobody signed decides who links a mailbox.

Applies to: `server/internal/googlejwt/verifier.go` (`Verifier.Verify`,
`parseUnverified`, `checkClaims`), `server/internal/googlejwt/keyset.go`.

## The JWKS is refreshed on a clock, never because of a token

`cachingKeySet` replaces `oidc.NewRemoteKeySet`. Do not go back to `RemoteKeySet`. In
go-oidc v3.11.0 it has two defects, and a test reproduced each one before this type was
written:

1. Its cache never expires. A key that the provider revokes stays trusted for the life
   of the process.
2. It fetches the JWKS again each time no cached key verifies the token, not only when
   the kid is unknown. It has no negative cache and no rate limit.

Defect 2 is an amplifier that needs no authentication. Each check before the key set is
public: `iss` and `alg` are fixed, the sender sets `exp`, `aud` is the client id in the
app or the push URL, and the JWKS publishes the kid. In a measurement, 20 forged tokens
that named the real kid caused 21 outbound fetches. A first fix that only filtered
unpublished kids still gave 21 fetches. If the provider then limits our rate, each real
verification fails.

A negative cache of kids that failed is also wrong. Its key comes from the attacker, and
a miss looks the same as a bad signature under a real kid. An attacker who sends garbage
under the live kid then stops every real token for the life of the entry. Thus the key
set holds no state that a token can write.

The rule: only the clock causes a fetch. A verification that fails reads the cache and
returns, with no I/O. `jwksRefresh` (1 minute) is the minimum time between fetch
attempts, and it is the one number for each timing property:

- a key that the provider adds works within this time;
- a key that the provider removes stops within this time;
- key material that changes under the same kid changes within this time, because the
  whole set is replaced, not patched by kid;
- an unauthenticated sender causes at most one outbound request for each interval.

The limit counts attempts, not successes. A fetch that fails (refused, 5xx, a document
that does not parse, our own timeout) also uses the interval. Without this, a provider
that is down gets one request for each inbound token.

One minute makes the rotation delay look like a retry, and the outbound rate stays
small (at most 1440 requests a day, usually about 2). A new key is refused for up to one
minute. That delay is the price of the bound, and the tests assert it in both
directions.

Applies to: `server/internal/googlejwt/keyset.go` (`cachingKeySet`, `jwksRefresh`,
`VerifySignature`, `currentKeys`, `fetch`), `server/internal/googlejwt/verifier_test.go`
(`TestForgedTokensCannotAmplifyIntoJWKSFetches`,
`TestAForgedSignatureUnderALiveKidDoesNotLockOutRealTokens`,
`TestVerifierRefetchesJWKSAfterRotation`,
`TestVerifierRejectsATokenSignedByARotatedOutKey`,
`TestVerifierRejectsAKeyReplacedUnderTheSameKid`).

## A failed refresh serves the old keys for one hour at most

When a refresh fails, the key set continues to serve the keys that it has. A fail-closed
rule makes a short Google outage a full outage of the mail hooks and the mailbox link.
But the old keys serve for `jwksStaleMax` (1 hour) at most, measured from the last fetch
that succeeded. "The JWKS cannot be reached" must not keep a revoked key trusted with no
end. After that hour the answer is "key set unavailable".

A key document with no keys counts as a failed fetch. If it went into the cache as "the
provider publishes nothing", each token fails for a full refresh interval.

Applies to: `server/internal/googlejwt/keyset.go` (`jwksStaleMax`, `staleKeys`,
`fetchJWKS`).

## The JWKS fetch is detached from the caller

A JWKS fetch is shared: each concurrent verification waits for the same one. The fetch
runs in its own goroutine on `context.WithoutCancel`, with its own 10-second timeout. A
caller waits on its own context, thus it keeps its own deadline and leaves alone when it
gives up. N callers on a cold cache cause one request.

Do not run the fetch on the context of the caller. `net/http` cancels that context when
the client disconnects. An earlier version did this, and the result was a silent denial
of service with no authentication: on a cold process, one forged token that passes the
public pre-checks, then a closed connection, used the fetch attempt, stopped the fetch
and cached nothing. Each real token then failed for a full refresh interval. No outbound
request occurred, thus nothing showed outside. The cost to the attacker was one closed
connection each minute. go-oidc protects the same property: `newRemoteKeySet` fetches on
`context.WithoutCancel(ctx)` and only the wait can be cancelled.

A second guard stays: only an attempt that got to the provider uses the refresh
interval. A fetch that was cancelled does not. If a later change connects the fetch to a
caller again, a closed connection still cannot take the attempt of the next request.

Applies to: `server/internal/googlejwt/keyset.go` (`currentKeys`, `fetch`,
`inflightFetch`), `server/internal/googlejwt/verifier_test.go`
(`TestAnAbortedRequestCannotPoisonTheKeySet`,
`TestASlowFetchHonoursTheCallersDeadlineWithoutAbortingTheFetch`).

## RS256 is the only algorithm, in three layers

Google signs with RS256 only (spec 02 §13.6). The algorithm never comes from the token.
Three layers refuse each other algorithm, `none` and HS256 included: `checkHeader`
first, the `SupportedSigningAlgs` of go-oidc second, and the `ParseSigned` call of the
key set (`keySetAlgs`) last. A token with a correct ES256 signature is refused before a
key is read.

`TestVerifierRejectsAlgNone` also calls go-oidc directly, to prove that the removal of
our header check opens nothing. Keep the three layers, and keep the three lists the
same.

Applies to: `server/internal/googlejwt/verifier.go` (`checkHeader`, `Verifier.init`),
`server/internal/googlejwt/keyset.go` (`keySetAlgs`),
`server/internal/googlejwt/verifier_test.go`.

## A key verifies only as a signing key with the kid of the token

- A key that the provider publishes with a `use` other than `sig` never verifies a
  signature. A key with no `use` is permitted (RFC 7517 makes it optional).
- A token that names a kid is verified against that key only. Thus a signature cannot
  pass through a different published key.
- A token with no kid is verified against each published key. RFC 7515 permits this, and
  Google does not send such a token. A test pins the behaviour so that it is known.

Applies to: `server/internal/googlejwt/keyset.go` (`VerifySignature`).

## Header parameters that bring a key are refused

A token with one of these JOSE header parameters is refused before all other checks:

- `jwk`: the token carries its own public key.
- `jku`, `x5u`: the same attack through a URL that the sender controls.
- `x5c`: a certificate chain in place of a key.
- `crit`: it demands the processing of a header that this package does not implement.

A verifier that obeys one of them verifies the attacker's signature against the
attacker's key. The test has a case for each entry of `forbiddenHeaders`. When you add an
entry, add its case.

Applies to: `server/internal/googlejwt/verifier.go` (`forbiddenHeaders`, `checkHeader`),
`server/internal/googlejwt/verifier_test.go`
(`TestVerifierRejectsAnEmbeddedJWKHeader`).

## A `typ` header must say JWT

`typ` is optional. When it is present, it must be `JWT` or `application/jwt`, in any
case (RFC 7519). The reason is defence in depth: if a provider later signs a different
kind of token with the same key set, that token must not pass here as an ID token. Do
not remove the check because Google always sends `JWT`.

Applies to: `server/internal/googlejwt/verifier.go` (`checkHeader`).

## The issuer and audience checks are in this package, and no audience means no token passes

go-oidc runs with `SkipClientIDCheck` and `SkipIssuerCheck`, because a `Verifier`
accepts more than one issuer and exactly one audience. go-oidc stays the authority for
the signature, the algorithm list, `exp` and `nbf`. Thus `checkClaims` and
`audienceAllowed` are the only issuer and audience checks. The audience comparison is
exact and constant-time, and an empty `aud` entry never agrees.

Without the audience check, a token that Google signed for a different relying party
passes: its signature is real and its issuer is correct. A change that removes or
loosens `audienceAllowed` opens the door fully.

A `Verifier` with an empty `Audience` (or with no issuer) refuses each token with
`ErrNotConfigured`. With the client id check of go-oidc off, a verifier with no audience
of its own is one missing `return` from "accept all". It must fail closed.

Applies to: `server/internal/googlejwt/verifier.go` (`Verifier.init`, `checkClaims`,
`audienceAllowed`), `server/internal/googlejwt/verifier_test.go`
(`TestVerifierRejectsWrongAudience`, `TestMisconfiguredVerifierRejectsEverything`).

## Google sends two issuer forms and two forms of `email_verified`

- Google documents its `iss` as `https://accounts.google.com` or as the bare
  `accounts.google.com`, and it sends the two. go-oidc has the same exception. A
  `Verifier` with no `Issuers` accepts exactly these two. A verifier that accepts only
  one form is not a bypass, but it silently refuses a part of the real Google tokens.
  That fault was in an earlier version.
- Google sends `email_verified` as the JSON boolean `true` or as the string `"true"`.
  `looseBool` accepts the two. Each other value (absent, `false`, `"false"`, junk) is
  false.

Applies to: `server/internal/googlejwt/verifier.go` (`GoogleIssuer`,
`GoogleIssuerNoScheme`, `looseBool`).

## An unavailable key set is not a rejected token

Each rejection wraps `ErrTokenRejected`. `ErrKeySetUnavailable` does not. A caller must
be able to tell "Google's key set cannot be reached" from "this token is forged": the
API answers the first with a 503 that the sender tries again, and the second with a 401,
and the two do not share a counter. An operator then sees an outage as an outage, not as
an attack.

`Verify` gets the keys itself before it calls go-oidc. go-oidc wraps an error of the key
set with `%v`, thus the error chain is lost and the outage looks like a bad signature.
Do not remove that first call.

Applies to: `server/internal/googlejwt/verifier.go` (`ErrKeySetUnavailable`,
`Verifier.Verify`), `server/internal/googlejwt/verifier_test.go`
(`TestAnUnavailableKeySetIsNotReportedAsAForgedToken`).

## Aggregated and distributed claims are refused in the pre-parse

A token with `_claim_names` or `_claim_sources` (OIDC Core §5.6.2) is refused. Google
sends none, and this package implements none. The refusal is in our own parse, before
go-oidc and before a JWKS fetch. If such a token gets to go-oidc, its error is logged as
a signature failure. That is the wrong reason, on a path where the log is the only
diagnosis.

Applies to: `server/internal/googlejwt/verifier.go` (`idClaims`).

## A token above 16 KiB is refused before it is decoded

`Verify` can be reached with no authentication, and its first step decodes two base64
segments whose size the sender sets. Thus a token longer than `maxTokenBytes` (16 KiB)
is refused first. A Google token is about 1 KB. The key document has its own cap of 256
KiB (`maxJWKSBytes`).

The test for the cap uses a token with a real signature and a large padding claim. A
block of repeated letters is refused as bad JSON with or without the cap, thus it tests
nothing.

Applies to: `server/internal/googlejwt/verifier.go` (`maxTokenBytes`,
`parseUnverified`), `server/internal/googlejwt/verifier_test.go`.

## A verifier is made with no network I/O

The construction of a `Verifier` does no OIDC discovery and no fetch. Do not use
`oidc.NewProvider`: it does discovery. A verifier that is made at process start must
come up when Google cannot be reached for a short time. The tests also need
construction to cost nothing.

Applies to: `server/internal/googlejwt/verifier.go` (`Verifier.init`),
`server/internal/googlejwt/verifier_test.go` (`TestConstructionPerformsNoNetworkIO`).

## The verifier tests are offline and make their tokens by hand

No test of `googlejwt` reaches a real JWKS endpoint. Each key is made in the test
process and served from an `httptest` server on loopback. Some tests also assert that a
rejection on a claim check causes no fetch, so the suite stays offline if a default
verifier later points at a real address.

The tests assemble each token by hand (base64url of a header, a payload and a
signature), with no JWT library. Half of the tests are forgeries (`alg: none`, an HMAC
over the RSA modulus, an injected `jwk` header) that a correct library does not make.

`mustReject` asserts the exact error of a rejection, not only that there is one. An
attack test that passes for the wrong reason continues to pass after its defence is
removed.

Applies to: `server/internal/googlejwt/verifier_test.go` (`mustReject`, `mintRaw`).

## The disk fuse reads free space on a timer, below a floor of 8 GB

`headroom` is P4 of the account isolation design (2026-08-09, ledgerd design archive).
Budgets for each account, multiplied by the number of accounts, can still be larger than
the disk, and Postgres has no storage quota for a role. A full filesystem stops Postgres
writes, which stops sync and sign-in for each person. It is also the failure that an
operator cannot repair quickly, because a backup, a dump and a log all need space. Thus
one goroutine samples the free space, and below the floor the API refuses each durable
write and continues to serve reads. What the gate stops, sign-in included, is in
`docs/decisions/code/server-api.md`.

The copy for an operator or a person must say this correctly: "Writes are paused while
the server is out of disk space, and new sign-ins are paused with them." Do not write
"the service is down". Do not write "sign in again": it sends the person to the one door
that cannot open.

The fuse is a flag that a timer sets, not a check for each write. A `statfs` for each
request puts a syscall on each write path for a number that changes in minutes, and the
cost of the fuse then grows with the traffic that it defends against. One sample each 30
seconds is late by one interval at most. That is safe only because the floor is
gigabytes: one interval of writes cannot use it.

The floor is 8 GB (the default of the package is 8 GiB; the configuration sets the
value). It is not an estimate of the working set of Postgres. It is the space that a
repair needs: a database that can still write its WAL, a `pg_dump` or a backup that has
somewhere to go, and a shell whose log files can be written. Do not make the floor
small, and do not make the interval long without a larger floor.

`New` returns a fuse that is not started. `cmd/hasalad` decides the path, the floor and
when to call `Start`. This lets a test give a floor and a sampler and never read the
real disk. A test that reads the real disk passes or fails with the free space of the
machine.

Applies to: `server/internal/headroom/headroom.go` (`Fuse`, `DefaultFloor`,
`DefaultInterval`, `Fuse.Sample`).

## The fuse starts open, and a failed sample or a stop does not change it

- A new fuse is not tripped until a sample says so. The other choice refuses each write
  for the first interval, or permanently if `statfs` is broken: an outage that the fuse
  itself causes. The fuse exists to catch a slow fill, and one interval does not miss a
  slow fill.
- A sample that fails changes nothing, and the error goes to the log. There is no
  free-space number, and the two other answers are wrong: to trip refuses each write
  because of one stat error, and to clear reports space that nobody measured. Thus a
  fuse whose first sample fails stays open, and a fuse that tripped and then lost its
  sampler stays tripped.
- On a platform that is not unix, the sampler always fails. By the same rule the server
  still serves there.
- `Stop` leaves the flag as it is. A stopped watcher does not show that the disk has
  space again. A shutdown path must not open the gate.

Applies to: `server/internal/headroom/headroom.go` (`New`, `Fuse.Check`, `Fuse.Stop`,
`errUnsupported`), `server/internal/headroom/statfs_other.go`.

## Free space is `Bavail`, not `Bfree`

The sampler reads `Bavail`: the blocks that a process without root can use. `Bfree` also
counts the reserved part (5% by default on ext4) that only root can use. Postgres does
not run as root. With `Bfree` the fuse reports space that Postgres cannot write to, and
it trips too late.

Applies to: `server/internal/headroom/statfs_unix.go` (`statfsAvail`).

## The code and link key of an emailed invite exist only in the email

For an emailed invite (spec 07 §3.2, §4.4, §6.4.2), the mail worker makes the code and
the link key when it renders the email, in the transaction of that render. The database
gets only their SHA-256 hashes. The plain values are not stored and not logged, and the
operator does not see them.

A result: the server cannot send the same code a second time. A resend makes a new code
and a new link key and replaces the hashes, thus the code that the person had stops. An
invite can be minted `MaxMints` times at most; then the operator must revoke it and make
a new invite.

Do not store the code or the link key to make a resend keep them, and do not put them in
a log line. A database copy or a log would then let its reader make an account, and the
link key would let the reader prove an address that is not theirs.

Applies to: `server/internal/invites/email.go` (`Renderer.Render`, `Resend`).
