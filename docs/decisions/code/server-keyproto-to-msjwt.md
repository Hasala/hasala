# Server key protocol, outbound mail and the Microsoft token verifier: decisions from the code (2026-11-21)

These decisions were code comments under `server/internal/keyproto`,
`server/internal/mail`, `server/internal/mailq` and `server/internal/msjwt`. Code
comments are not permitted (`scripts/comment-lint.ts`), thus the decisions are here.

## keyproto holds byte definitions and no key derivation

`keyproto` has the byte definitions that the server shares with the device (spec 01 §3,
§5.1, §5.5, §10.1–§10.3, §12.2): the domain strings, the builders of the signed
messages, the step-up hash and challenge, the canonical BootstrapPayload, the shape
checks of a wrap and of the phrase box, the key checks, the address normalization and
the display-name floor.

The package holds no data key and derives none. The server verifies signatures over
these bytes and stores opaque wraps. It never opens a wrap, a phrase box or a frame
(spec 02 §4.4 fence 3, spec 01 §12.2). Each derivation that needs the account master
key or the phrase is in `internal/cryptoref`. Only the vector generator and the tests
import that package, and the build-graph fence keeps it out of `hasalad`.

Do not move a derivation into `keyproto`. The package is linked into the server, and
the server then has code that can make a data key.

Each builder writes exactly the bytes of spec 01 §10.1. The anchor vectors of spec 01
§15.5 (A11–A26) pin these bytes in the tests of the package and in
`conformance/api-v1/`, which the Swift client reads. A change to the bytes of a builder
must change the vectors and the Swift client in the same change. If it does not, each
signature from a phone fails on the server.

Applies to: `server/internal/keyproto/domains.go` (package `keyproto`),
`server/internal/cryptoref`, `server/cmd/hasalad/fence_test.go`
(`TestFenceTheBuildGraph`).

## A signed message has exactly one encoding

Each signed message of spec 01 §10.1 has fixed-length fields and at most one field of
variable length. The variable field is the last field, or it is between fixed-length
fields. A domain string that comes before other fields is followed by exactly one
`0x00`. Thus no two different inputs give the same bytes.

A builder refuses a field of the wrong length (`ErrFieldLength`). It does not encode
it. A short nonce or a short key makes the encoding ambiguous: the bytes of one field
can then be read as the start of the next field.

A builder checks a writer id only for its length and for the absence of `0x00`. The
grammar of spec 01 §4.8 (`ValidWriterID`) is checked by the callers that accept a
writer id from the wire.

Keep this rule when you add a message. With a second variable field, or with a length
that is not checked, one signature can be valid for two different meanings.

Applies to: `server/internal/keyproto/messages.go` (each `...Message` builder, `need`,
`needWriter`).

## A key is examined before a signature under it counts

A valid signature must prove that the signer holds the private key. Some public keys
break this.

- **Ed25519.** `CheckEd25519PublicKey` refuses a key of the wrong length, a key that is
  not a point, and a point of small order (spec 01 §10.1: refuse small order before any
  verification). The length alone is not sufficient. Under the identity point, the
  signature `identity ‖ 0^32` verifies for every message in Go's `crypto/ed25519`.
  `edwards25519.SetBytes` accepts the same non-canonical encodings that
  `crypto/ed25519` accepts. Thus no encoding passes the check and then verifies as a
  key that the check did not see.
- **Each Ed25519 verification on the server goes through `VerifyEd25519`.** It makes
  the key check again at the time of the verification. Thus a key that somebody put in
  a row without the write-time check still authorizes nothing. Do not call
  `ed25519.Verify` directly in the server.
- **The device approval key (P-256).** `ParseDAK` uses
  `ecdsa.ParseUncompressedPublicKey`. That function refuses a compressed point, a point
  that is not on the curve and the point at infinity (V-H). Do not replace it with a
  parser that accepts one of these.

`TestSmallOrderEd25519KeysAreRefused` keeps the forgery as a case: the identity key
with the signature `identity ‖ 0^32` must not verify.

Applies to: `server/internal/keyproto/shapes.go` (`CheckEd25519PublicKey`,
`VerifyEd25519`), `server/internal/keyproto/dak.go` (`ParseDAK`),
`server/internal/keyproto/keyproto_test.go`.

## An email address is normalized one way, and nothing else is canonicalized

`EmailNorm` is the normalization of spec 01 §4.11:

1. Each byte must be `0x09` or in `0x20`–`0x7E`. An address with a non-ASCII byte is
   refused.
2. Leading and trailing `0x20` and `0x09` are removed.
3. ASCII `A`–`Z` become lowercase.
4. The result is valid only with a length of 3 to 254, exactly one `@`, a local part of
   1 to 64 bytes, a domain of 1 to 253 bytes that has a `.` not at its start or end,
   and no byte below `0x21`.

Nothing else is canonicalized. Dots and `+tags` stay. Two addresses that a mail
provider delivers to one mailbox are two addresses for Hasala.

The CHECK constraint on `users` restates the shape of the result. The phone computes
the same normalization. The result is the input of the email hash in the
BootstrapPayload (`EmailHash`), of the email tag and of the password salt. A change to
a step changes these values for each address that the step touches: the bootstrap
signature of the phone no longer agrees, and the server no longer finds the rows that
it tagged before. Do not add a provider-specific rule (for example, the removal of
dots).

Applies to: `server/internal/keyproto/identity.go` (`EmailNorm`, `EmailHash`).

## An account email carries only what it exists to carry

The account emails of spec 02 §14.6 are the codes, the address-in-use notice, the
security alerts and the goodbye. The renderers of `internal/auth` make them, and they
go out only through `internal/mailq`.

Each one is in English and goes to exactly one address. It has a text part and an HTML
part in the shared layout. The text starts with a greeting line and an empty line, and
it ends with the footer.

The only values that an account email substitutes are: the code, the time, the freeze
link, the word "passkey" or "password", and the first name in the greeting. It has no
other URL: the HTML layout adds only the logo and the links to the support page and the
privacy page on hasala.app. It has no account data and no device name.

An email leaves the server and can be read by a person who is not the holder. Thus it
shows nothing about the account. `TestTheTemplatesAreContentFree` and
`TestHTMLTemplatesAreContentFree` hold the rule. Do not add a substitution or a link
to make an email more helpful.

Applies to: `server/internal/mail/account.go` (`Code`, `AddressInUse`, `Alert`,
`Deleted`, `compose`).

## An email shows a name only at a verified address, and no other typed text

A code email greets the holder by name only when it is about an existing account and
it goes to an address that this account verified (spec 02 §14.6). These are the
purposes `email_verify`, `password_reset`, `recovery` and `email_change_old`. The codes
for a signup and for the new address of an email change greet nobody by name: nobody
has proved that address yet, and the name would go to a mailbox that can belong to a
different person.

The bank name in a waitlist email is a name from the catalog or the words "Another
bank". It is never the text that a person typed. If typed text went into an email, a
person could use the form on the website to make Hasala send their own text to the
address of another person.

When you add a template value, apply the same rule: no value that a person typed goes
to an address that its account did not verify.

Applies to: `server/internal/mail/account.go` (`CodeGreetsByName`),
`server/internal/mailq/templates.go` (`Content.BankName`).

## The alert email names the security screen, not the freeze button

The "If this wasn't you" line of a security alert sends the person to Profile ›
Sign-in & security. Each build has this screen. The freeze control in the app is not
in each build: the beta hides it. Thus the line names the place and not the button.

This is a known difference from spec 02 §14.6, whose wording names the freeze. Do not
change the line to name the freeze while a build that hides the control is in use. A
person who gets the alert then looks for a button that their app does not have.

Applies to: `server/internal/mail/account.go` (`notYou`).

## The freeze token is in the fragment of the freeze link

A freeze link is the address of the freeze page, then `#`, then the token. The token is
not in the path and not in a query string. A browser does not send the fragment in its
request. Thus the token does not reach the host of the website, its logs or Web
Analytics. The page reads the token from the fragment and removes it from the address
bar.

Do not move the token to the path or to a query parameter. `CLAUDE.md` ("Third-party
scripts") gives the rules for a page with a token in its address.

Applies to: `server/internal/mail/account.go` (`DefaultFreezeURL`),
`server/internal/auth/mailer.go` (`renderAlert`), `web/src/lib/link-page.ts`.

## The goodbye email promises the 30 days of the backup retention

The goodbye email after an account deletion has the row "Sealed backup: Gone from
backups by <date>". The date is the time of the deletion plus 30 days, written in UAE
time. The encrypted backups of the server expire within 30 days, and the privacy policy
says the same.

The number 30 is in three places: the backup retention of the deployment, the privacy
policy and this email. If the backup retention changes, change the three together. If
not, the email gives a person a date that is not true.

Applies to: `server/internal/mail/account.go` (`Deleted`), `docs/legal/privacy.md`.

## An account email goes as text when its HTML part fails

`compose` makes the text part and the HTML part of an account email. If the HTML render
fails, the email still goes, with the text part only. A code or a security alert must
not be lost because of a fault in the layout.

A failure is not expected at run time: the layout and the account template are embedded
in the binary, and `TestTheTemplatesAreContentFree` renders each account email. Keep
the fallback when you change `compose`. Do not make a render fault stop the email.

Applies to: `server/internal/mail/account.go` (`compose`).

## A send error never carries the provider's answer body

The error of `Cloudflare.Send` has the error class, the HTTP status and the numeric
code of the provider. It never has the body of the provider's answer. Cloudflare Email
Service repeats addresses in that body.

The text of this error goes into `mail_log.error` and into the server log. An address
in it stays in the row after the row lost its recipient, and it puts an address into a
log that must have none. Do not add the body, or a part of it, to the error to make a
fault easier to find. Use the numeric code.

Applies to: `server/internal/mail/cloudflare.go` (`Cloudflare.Send`).

## An email has no script, no remote content and one static image

Each transactional email renders into one shared layout
(`server/internal/mail/templates/layout.html.tmpl`): the account emails of spec 02
§14.6 and the templated kinds of spec 07 in `internal/mailq`. The rule is spec 07 F7-6:

- No template has a script, an inline style, a remote stylesheet (no `url()`, no
  `@import`), an `http://` link or a query string. The one `<style>` block of the
  layout does all the styling.
- The only image is the Hasala mark, a static PNG on hasala.app (`LogoURL`). Nothing in
  its address names the recipient. Thus a mail client that fetches the image tells the
  server nothing about who opened which email. Do not add an image or a link parameter
  that is different for each recipient: that is a tracking pixel.
- A mail client that blocks images still shows the word "Hasala" beside the mark.
- The mark is a PNG because Gmail and Outlook do not show SVG in an email.
- The website serves the mark from `web/public/brand/`. If that file is moved or
  removed, each email that was already sent loses its logo.

`TestTemplatesAreContentFree` (in `internal/mailq`) and
`TestHTMLTemplatesAreContentFree` (in `internal/mail`) hold the rule.

Applies to: `server/internal/mail/html.go` (`LogoURL`, `Layout`),
`server/internal/mailq/templates.go` (`RenderTemplate`).

## Every email goes through the mail queue, and the mail log keeps no content

`internal/mailq` is the only package that calls `mail.Sender.Send` (spec 07 F7-5).
`TestFenceMailIsSentOnlyByTheQueue` holds this. Thus each email has one `mail_log` row,
and the email log is complete.

A queued row is written in the transaction that causes the email, so an action that
rolls back sends nothing. A worker in `hasalad serve` sends it. The row stays for 30 days,
with no subject, no body, no link and no secret. `internal/mail` writes no recipient,
subject or body to a log.

The privacy policy says the same: a record of each email, never what the email said,
deleted after 30 days. Do not add a column or a log line that holds content, and do
not send an email from a different package.

Applies to: `server/internal/mail/mail.go` (`Sender`), `server/internal/mailq/mailq.go`
(`Queue`), `server/cmd/hasalad/fence_test.go`.

## A secret of an email is minted at send time, and the rendered email is not kept

An email can carry a secret: a code, or a link with a token.

- A `Renderer` makes the message of a row at send time, in its own transaction. It
  mints the secret of that kind then and stores only the hash. Thus no secret waits in
  the queue.
- A code of spec 02 is minted by its caller and must never be in the database.
  `SendNow` is the path for it: it writes the row as `sending`, calls the render
  function, sends the message and writes the outcome. It makes one attempt. Nothing is
  stored from which a second attempt could make the email again.
- After the send, the queue replaces the rendered message with an empty one
  (`msg = mail.Message{}`), in `SendNow` and in `ProcessOne`. The line looks like an
  assignment with no effect. Do not remove it: it drops the last reference to the
  secret.
- `mail.Unconfigured` is the sender of `serve` with no `[email]` group. Each send fails
  permanently and nothing is kept. Thus the log says `failed`, never `sent`, for a
  message that went nowhere, and no rendered code, link key or token stays in memory.
  An invite whose email failed can be sent again after email is configured, and that
  send mints a new code.
- `mail.Fake` keeps each rendered message in memory, codes and links included. It is
  for tests only. Do not use it as the sender of `serve`, also not as a stand-in when
  email is not configured.

Applies to: `server/internal/mailq/mailq.go` (`Renderer`, `SendNow`, `ProcessOne`),
`server/internal/mail/mail.go` (`Unconfigured`, `Fake`).

## The LISTEN connection is closed and not given back to the pool

The listener of the mail queue holds one pool connection on `LISTEN hasala_mail`. When
its wait ends with an error (a stop of the server, or a network fault), the connection
can be in the middle of a wait. The listener closes the connection before it releases
it, and the pool discards a closed connection.

Do not release the connection open. The pool can then give a connection in an unknown
state to a request.

Applies to: `server/internal/mailq/mailq.go` (`Queue.listen`).

## A send outcome is written only under the lease of its row

`finalize` writes the outcome of a send with a condition: the row is `sending` and its
`lease_until` is the lease that this send took. An account deletion can suppress the
row while the send is in progress. The outcome then changes nothing, and the row stays
suppressed. Do not remove the lease condition. Without it, a send that returns after
the deletion changes a row that the deletion already settled.

A `deleted` email (the goodbye after an account deletion) loses its address when its
row becomes final: sent, bounced or failed (O-17). The account is gone, so nothing else
removes that address later. The privacy policy says that this record loses the address
as soon as the email has gone, or after 24 hours if it could not be sent.

Applies to: `server/internal/mailq/mailq.go` (`Queue.finalize`, `Queue.Sweep`).

## The Microsoft token verifier is the Google verifier with Microsoft's claims

`msjwt` verifies the Microsoft ID token that the app sends when it links an Outlook
mailbox. It accepts a v2.0 token of the consumers tenant, thus only personal Microsoft
accounts. It never signs a person in, and it holds no Microsoft credential.

- **One verifier, not two.** The JWT checks are those of `googlejwt`, configured with
  Microsoft's issuer and key set: the JWKS cache (a refresh on a clock, never because a
  token failed; one detached fetch; a limit on the age of a stale set), the list of
  forbidden headers (`jwk`, `jku`, `x5u`, `x5c`, `crit`), RS256 only, the limit of
  16 KiB, one exact audience, and go-oidc over go-jose for the signature. A key is
  selected by `kid`. An `x5t` header is permitted and not used. A copy of that code in
  `msjwt` was rejected: the server would have two copies of the part that is easiest
  to get wrong, and a correction to one would not reach the other.
- **Claims come from the authenticated payload.** `msjwt` adds only Microsoft's claims
  (`tid`, `oid`, `preferred_username`). It decodes them from the same payload segment
  whose signature `googlejwt` verified, and only after that verification succeeds. Do
  not read a claim before the verification, and do not read it from a different copy
  of the token.
- **No OpenID discovery.** The issuer of the consumers tenant is fixed, and the address
  of the key set is written in full. The server does not fetch a discovery document.
- **A key set that is down is not a forged token.** The errors are the values of
  `googlejwt`. Each rejection wraps `ErrTokenRejected`. `ErrKeySetUnavailable` does
  not, so the caller can tell "Microsoft's key set cannot be read" from "this token is
  not valid". Do not wrap the two in one error.

The facts about the claims of a personal account (no `email_verified`, no `azp`, when
`email` and `preferred_username` are present) are in
`docs/decisions/outlook-mailbox.md`, section 6.

Applies to: `server/internal/msjwt/verifier.go` (`Verifier`, `Verify`,
`ConsumersIssuer`, `ConsumersJWKSURL`, `ErrTokenRejected`, `ErrKeySetUnavailable`).
