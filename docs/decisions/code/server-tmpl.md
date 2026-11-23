# Bank templates (tmpl): decisions from the code (2026-11-21)

These decisions were code comments under `server/internal/tmpl`. Code comments are
not permitted (`scripts/comment-lint.ts`), thus the decisions are here.

The format specification, `server/internal/tmpl/v2-template-format.md`, has the full rule
table and the measured times. `docs/decisions/code/ios-sync-to-template.md` records the
Swift side of the same contract: the reason codes as a wire format, the counters that
saturate, the list of permitted escapes, the compile of the engine as the backstop, and the
sender-domain gate that belongs to the trusted lane.

## The dialect is the part of RE2 that each engine reads the same

A template is data. Its pattern text is stored one time, and more than one regex engine
runs that same text: Go's RE2 in this package and a backtracking engine on the phone. The
dialect was measured against JavaScript's `RegExp` with the `u` flag, and the Swift
translator keeps that meaning for ICU. A construct that the engines read differently gives
a different amount or merchant on each side, and no side reports an error. Thus
`ValidatePattern` accepts only the constructs on which the engines were measured to agree.

The second purpose is cost. The body of a mail is text that an attacker can write. RE2
cannot backtrack, but the engine on the phone can. Thus the dialect refuses an unbounded
quantifier on a group, an unbounded quantifier inside a quantified group, more than one
unbounded quantifier in a branch, and the two bounded shapes of the sections below.

The dialect does not make a template cheap. The one unbounded quantifier that it permits
is quadratic in a backtracking engine when the match fails: `[0-9]+z` took 17.9 s on
200,000 digits in Bun 1.3.14. A template is cheap only when it has a mandatory literal
prefix, or a bounded run. The dialect has no rule "a pattern must start with a literal",
because that rule refuses seeds that ship (`DEBIT$`, and the ENBD amount anchor, which
starts with an optional currency group). The owner accepted this limit. The cost is
measured where it occurs: the hostile bodies of the Swift template tests and the ICU limit
(`docs/decisions/code/ios-sync-to-template.md`).
`TestKNOWNASingleUnboundedQuantifierIsStillQuadraticInJavaScript` records the limit.

The amount run of the ENBD alert seed is `[0-9,]{0,24}`, not `[0-9,]*`. The first
mandatory atom of that anchor is a digit class, so a backtracking engine starts at each
digit of the body, and the unbounded run backtracked the remaining digits each time:
333,859 ms on a 1 MB body. A run of 24 holds each amount that an `int64` can hold, and the
extractions on the corpus stayed the same, byte for byte. Do not make this run unbounded.

These rules also hold:

- A stored pattern has no inline flags. The only flag is `i`, in the `flags` list.
  `CompileGo` is the one place in Go that applies it, as the `(?i)` prefix. The JavaScript
  form is `new RegExp(ToJS(p), flags + "u")`. The `u` flag is necessary: only with it do
  the two engines fold case the same. Do not compile a stored pattern for a match in
  another way.
- The length limit of a pattern and the offset of an error count runes, not bytes. The
  Arabic anchors use 2 bytes for each rune. A limit in bytes would be a different limit in
  Go and in a mirror that counts code points.
- `\-` is permitted only inside a character class. In JavaScript's `u` mode, outside a
  class, only the syntax characters and `/` can have an identity escape, so `\-` there is
  a `SyntaxError`. Go accepts it in the two positions.

Applies to: `server/internal/tmpl/dialect.go` (`ValidatePattern`, `CompileGo`,
`MaxPatternRunes`, `escapeClassOnly`), `server/internal/tmpl/seed/enbd.alert.v1.json`.

## Each ban has a rewrite that the dialect accepts

Each reason code has a row in the dialect table of the tests (`dialectRules`). A row has a
pattern that the validator must refuse with that code, and a rewrite that the validator
must accept. A ban with no accepted rewrite makes a template impossible to write. An early
draft of the dialect refused each quantifier after `)`. Then the optional currency group
of the seeds, `(?P<ccy>[A-Z]{3} )?`, could not be written. Thus `?` and `{n,m}` on a group
are permitted, and only the unbounded forms are refused.

For the same reason, the rule against a variable repetition inside a repeated group does
not apply to `?` and `{0,1}`. One repetition multiplies nothing. `([0-9]{1,4})?` is the
accepted rewrite of `([0-9]+)?`. A rule that refused it would leave that ban with no
rewrite.

Do not add a ban without its accepted rewrite in the table.

Applies to: `server/internal/tmpl/dialect_test.go` (`dialectRules`),
`server/internal/tmpl/dialect.go` (`quantify`).

## A branch has at most one unbounded quantifier

The two nesting rules stop the exponential shape `(a+)+`. They do not stop the polynomial
shape: `k` unbounded quantifiers that can consume the same characters cost `n^k` in a
backtracking engine. RE2 does not have this cost, so Go cannot show the fault. Measured in
Bun 1.3.14: `[0-9]+[0-9]+z` took 86 ms on 800 characters, four such quantifiers took
88 s on 400 characters, and `[^\n]+X[^\n]+Y` took 31.7 s on 8,000 characters.

Thus the rule counts the unbounded quantifiers. It does not look for adjacent ones: a
mandatory literal between two of them does not make the pattern cheap, it only changes the
input that causes the cost. The count is for each alternation branch, because a
backtracking engine examines one branch at a time: `a+|b+` counts one. A group gives its
most expensive branch to the branch that contains it, so `(a+|b)c+` counts two. Two
adjacent unbounded quantifiers can always be written as one (`[0-9]+[0-9]+` is
`[0-9]{2,}`). Bounded quantifiers do not count here; the width bound counts them.

Do not change the count to a count for the full pattern, and do not change it to a check
for adjacent quantifiers.

Applies to: `server/internal/tmpl/dialect.go` (`MaxUnboundedPerBranch`,
`frame.worstBranch`), `server/internal/tmpl/dialect_test.go`
(`TestMultipleUnboundedQuantifiersInOneBranchAreRejected`).

## The repetition width bound is 1,024, and tests pin the number

`MaxBoundProduct` multiplies the upper bounds of the `{n,m}` quantifiers. It bounds the
length of a match, not the number of ways to assemble it. `(?:[a-z]{8}){8}z` and
`(?:[a-z0-9 ]{1,8}){8}z` have the same bound product, 64. On 512 characters that do not
match, in Bun 1.3.14, the first took 0.0 ms and the second took 2,178 ms. An anchor is not
a defence: `^...$` did not make the nested shape cheaper.

Thus there are two more rules. `nested_variable_repetition` refuses a group that can
repeat more than one time when its contents can match more than one length.
`repetition_width_too_large` bounds the width of one alternation branch at
`MaxRepetitionWidth`. The second rule is necessary because eight sibling `[a-z]{1,8}`
runs nest nothing, and took 7,140 ms.

The width is the number of ways in which one branch can divide the same input:

- a repetition `{lo,hi}` gives `hi - lo + 1` choices;
- concatenation multiplies, and alternation adds;
- a group that repeats `n` times gives its width to the power `n`, and a group that
  repeats at most one time multiplies nothing;
- an unbounded quantifier counts 1, not infinity. It is quadratic, not exponential, and
  the rule of one unbounded quantifier in a branch bounds it. A count of infinity would
  refuse a seed that ships. The length of such a quantifier is still unbounded, and this
  makes the group that contains it variable.

Why 1,024: it is 5.1 times the widest pattern that the seeds ship (200, the ENBD credit
anchor), and 16 times below the smallest measured cost problem. It is also the widest pair
that `MaxBoundProduct` permits before the pair can be collapsed (`{1,32}{1,32}`).

The tests pin the number and the arithmetic, not only the direction of the comparison:

- The dialect fixture has rows that are one below and one above the limit. A mirror that
  uses 900 or 4,096 fails on them. A mirror that takes the maximum of the branches, where
  the sum is correct, also fails.
- `TestTheShippingSeedsHaveHeadroomUnderTheWidthBound` reads `seed/*.json` from the disk,
  so a new seed is examined too. The widest seed must measure exactly 200, and the limit
  must be at least 4 times the widest seed.

Do not increase `MaxRepetitionWidth` when that test fails. A failure means that a template
is at the edge of the bound. Publish the collapsed rewrite of its pattern, with a new
template version.

Applies to: `server/internal/tmpl/dialect.go` (`MaxRepetitionWidth`, `quantify`),
`server/internal/tmpl/conformance_test.go` (`buildDialectFixture`),
`server/internal/tmpl/dialect_test.go`
(`TestVariableRepetitionInsideARepeatedGroupIsRejected`,
`TestTheShippingSeedsHaveHeadroomUnderTheWidthBound`).

## Each reason code has its reason in the format specification

`server/internal/tmpl/v2-template-format.md` is the document where a person learns the
dialect. Its rule table gives, for each reason code, the measured engine difference or the
cost bound, and the accepted rewrite. `TestEveryReasonCodeIsDocumentedInTheSpec` fails
when a reason code is not in that document.

A ban whose reason is not written is a ban that somebody removes as a simplification.
When you add or change a ban, change the rule table in the same commit.

Applies to: `server/internal/tmpl/dialect_test.go`
(`TestEveryReasonCodeIsDocumentedInTheSpec`), `server/internal/tmpl/v2-template-format.md`.

## The dialect fixture has a digest of a generated corpus

`conformance/dialect/patterns.json` holds rows that a person selected. The person who
selects the rows is also the person who wrote the validators, so the rows agree where
that person expected. Thus the fixture also holds `corpus_digest`: the validator runs on
a generated corpus (the cross product of a small grammar, 9,324 patterns), and the fixture
records a SHA-256 of the verdicts. The digest agrees only when the Go validator and its
mirror are the same function on all these patterns.

- The generator, `dialectCorpus`, is plain nested loops on literal arrays. The mirror
  (`DialectFixture.corpus` in the Swift conformance tests) is a copy of it, line for line.
  The sequence of the patterns is part of the contract, because the digest is of the
  sequence. Change the two generators together.
- The grammar has a fixed atom, a class, a negated class, an escape and one Arabic
  literal, each with every quantifier form that has a rule. The Arabic literal proves the
  agreement on a pattern that is not ASCII.
- Each hashed line is the pattern, a NUL byte, the reason codes with commas between them,
  and a line feed. NUL cannot occur in a pattern, so two different pairs cannot give the
  same bytes.
- The fixture holds a digest and not the rows, because the rows are about 400 KB. It also
  holds a checkpoint for each 1,000th pattern, so that the mirror can name the first
  pattern that differs.

Applies to: `server/internal/tmpl/conformance_test.go` (`dialectCorpus`,
`buildCorpusDigest`).

## The probe inputs hold the characters on which the engines differ

For each accepted pattern, the dialect fixture records what Go's engine did on each probe
input: the match, and each named group. Two validators can agree that a pattern is
permitted while the two engines match different text.

The probe inputs are hostile on purpose. They contain each character on which the engines
were measured to differ for a banned construct: CR, U+2028, U+2029, U+00A0, vertical tab,
U+FEFF, the Kelvin sign and the long s. Thus an accepted pattern is measured on the inputs
that break the refused patterns.

One probe has a carriage return in the merchant line of a DIB mail. It proves that
`[^\n]`, the accepted rewrite of the bare dot, includes `\r` in each engine. A bare dot
does not do that in JavaScript.

Do not remove these inputs, and do not replace them with ordinary text. Then the fixture
proves nothing about the differences that the dialect exists for.

Applies to: `server/internal/tmpl/conformance_test.go` (`probeCorpus`).

## The seed rows of the dialect fixture are the patterns that ship

Each `seed-*` row of the dialect fixture is a pattern from `seed/*.json`, copied exactly.
A row that is almost the seed pattern pins the agreement of the engines on a pattern that
nobody runs. Its groups can also differ from the real groups, and then the capture that
the executor reads is not compared. This fault occurred one time: a row had the currency
inside the `amt` group, while the seed has the two groups `ccy` and `amt`.

When you change a pattern in a seed, change its row in `buildDialectFixture` to the same
text and write the fixture again.

Applies to: `server/internal/tmpl/conformance_test.go` (`buildDialectFixture`).

## The ENBD alert seed has two currency patterns, and their sequence is fixed

`enbd.alert.v1` reads an amount with the currency next to it (`USD99.99`) and with a space
(`USD 99.99`).

- The two forms are two patterns. The one pattern `(?P<ccy>[A-Z]{3} ?)?...` measures 400
  wide. The widest seed is pinned at 200, and the width bound must be at least 4 times
  the widest seed. A width of 400 fails that test.
- The pattern for the adjacent currency is first. The executor uses the first pattern
  that matches. If the pattern with the space were first, it would match `USD99.99` with
  no currency group, and the amount would get the default currency, AED.
- The `last4` anchor reads the subject. The normalizer does not collapse white space in
  the subject, so this anchor is the only one with a `+` on its separator class.
- The separator class is `[ \t\n\f\r]`, which is Go's `\s` written in full, because `\s`
  has a different meaning in each engine.

Applies to: `server/internal/tmpl/seed/enbd.alert.v1.json`,
`server/internal/tmpl/conformance_test.go` (`buildDialectFixture`).

## A template fixture case carries normalized text, and one file holds one template

The dialect fixture proves that the validators and the engines agree. It proves nothing
about the executor: the first entry that wins, `override`, `on_match`, the typed
conversions, the date layouts, the empty-group diagnostic and the gate of the required
fields are decisions above the regex engine. `conformance/templates` records what the Go
executor gave for each case, field by field, and the other executor must give the same.

- A case carries the normalized subject and text, not the raw message. The normalizer has
  its own fixture set (`conformance/normalizer`). With raw mail in a template case, a
  fault of the normalizer and a fault of the executor would look the same.
- One file holds one template and all its cases, with the definition one time. One file
  for each case would be about 1,500 files, each with a copy of the definition. The test
  runner still makes one test for each case, so a failure names one message.

Applies to: `server/internal/tmpl/corpus_test.go`, `server/internal/tmpl/fixtures.go`
(`TemplateFixture`).

## The definition format is closed

`ParseDefinition` refuses an unknown key. A person writes a template by hand. A key with a
spelling error that the reader ignores gives a template that passes each check and
matches nothing. Do not make the reader lenient.

The date layouts are a closed list. Each executor implements exactly these layouts. A
layout that one executor knows and the other does not gives a different date on each
side, with no error. Add a layout to each executor and to the fixtures in the same change.

Applies to: `server/internal/tmpl/def.go` (`ParseDefinition`, `LayoutDDMMYYYY` and the
other layout constants).

## The canonical form of a template is total, sorted and escaped as JSON.stringify

`Definition.Canonical` gives the bytes that are hashed. It is not the storage form. A
mirror in another language must give the same bytes with a sort and `JSON.stringify`.
Each of these three properties prevents a hash that differs for a template that works
correctly on each side:

1. The keys are sorted at each level, `on_match` included. Go writes a struct in the
   sequence of its fields and JavaScript in the sequence of insertion. Neither can copy
   the other, but each can sort.
2. Each key is always there. A nil list is `[]` and an empty string is `""`. Thus a
   mirror does not copy Go's rules for empty values. The keys of the text channel
   (`channel`, `match.sms_sender`, `transfer_role`) are the exceptions: they are absent
   when they are empty, so a mail template keeps the bytes it had before.
3. Strings are escaped as `JSON.stringify` escapes them: only `"`, `\` and the C0
   controls. Go's `encoding/json` is wrong here in two ways. By default it escapes `&`,
   `<` and `>`. With `SetEscapeHTML(false)` it still escapes U+2028 and U+2029, which
   `JSON.stringify` writes as they are. Thus the encoder for strings is written by hand.
   The algorithm of `JSON.stringify` is fixed by the ECMAScript specification, so Go is
   the side that adapts.

`Canonical` gives an error for a string that is not valid UTF-8. Go would replace the bad
bytes with U+FFFD and JavaScript would not.

Do not replace the encoder with `encoding/json`. `conformance/dialect/patterns.json` pins
the bytes.

Applies to: `server/internal/tmpl/def.go` (`Definition.Canonical`, `canonicalString`).
