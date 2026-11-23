# Template executor, seeds and fixtures: decisions from the code (2026-11-21)

These decisions were code comments under `server/internal/tmpl` and
`server/internal/tmpl/seed`. Code comments are not permitted
(`scripts/comment-lint.ts`), thus the decisions are here.

The Go package is the reference executor. `hasalad` does not link it (spec 02 §4.4,
fence 1). The Swift executor on the phone mirrors it and must give the same bytes on
`conformance/templates`. `docs/decisions/code/ios-sync-to-template.md` records the
Swift side: the hostile body, the trim set, the ASCII upper-case rule and the
sender-domain gate that the executor does not apply.

## The executor bounds, and the reason for each number

The bounds are part of the contract between the executors. Change a number in Go and in
Swift together.

- The body bound is 2,000,000 bytes of normalized text. The raw mail cap is 1,000,000
  bytes (it was ledgerd's SMTP cap, and the phone keeps it as
  `Disposition.maxMessageBytes`). Normalization can make a message larger: a base64
  UTF-16 part decodes to longer UTF-8. Thus the body bound is two times the raw cap. A
  body bound equal to the raw cap refuses mail that the reader already accepted.
  `TestExecuteBoundsExceedTheLargestStorableMail` fails when one number changes without
  the other.
- The subject bound is 64,000 bytes of the decoded, effective subject. RFC 5322 limits a
  header line, but encoded words can make the decoded value larger.
- The capture bound is 512 runes, not bytes. Each executor then counts in the same way
  and needs no knowledge of UTF-8. A longer capture is a conversion failure: the entry
  falls through and the field stays unset. A capture is never cut.
- One run reports at most 32 empty-group labels. The number came from the cap of
  ledgerd's diagnostics table, which is gone. It stays because the fixtures compare the
  list, and the Swift executor has the same cap.

Applies to: `server/internal/tmpl/exec.go` (`MaxBodyBytes`, `MaxSubjectBytes`,
`MaxCaptureRunes`, `MaxEmptyGroups`), `server/internal/tmpl/exec_test.go`
(`TestExecuteBoundsExceedTheLargestStorableMail`).

## Field presence comes from the values, with no mask

An extraction has no separate record of the fields that were produced. Presence is read
from the values. A mask is one more thing that the second executor can get wrong.

| Field | Produced when |
| --- | --- |
| amount | the currency is not empty |
| date | the posted time is not the zero time |
| merchant, last4, direction | the value is not empty |
| is_transfer | never |

The currency, not the amount, shows that an amount was read. The two are always set
together. A real amount of 0.00 is a value, and a zero integer does not tell "nothing
ran" from "zero".

`is_transfer` has no honest presence: a flag that is false looks the same as a flag that
nothing set. Thus the presence check always reports false for it, and `Compile` refuses
a definition that requires it. A template that requires it could never match.

The zero time has two meanings. With `date_from: "email"`, the executor reads no date
and the caller supplies the date of the mail. With `date_from: "body"`, a zero time
means that no entry produced a date. That is a failure only when the definition requires
the date. A zero time is never given out as a date that was read.

Do not add a mask, and do not use "the amount is not zero" as the presence of an amount.

Applies to: `server/internal/tmpl/exec.go` (`Extraction`, `Extraction.Produced`,
`Compile`).

## Empty groups are named `<field>_<group>`, and errors quote only the template

The executor reports the capture groups that took part in a match and captured nothing.
This list is the diagnostic for a bank that changed its mail: it tells which field came
back empty.

- A label is `<field>_<group>`, not the group name alone. Each text pattern and each
  last4 pattern uses the group name `v`. A bare `v` does not tell if the merchant or the
  card number is missing.
- The two halves are identifiers that the author of the template wrote. Thus a label has
  no mail content (the privacy disclosure of spec §2 permits "the names of the template
  fields that failed to extract"). A label must be an identifier of at most 32
  characters, and `Compile` refuses a group name that gives another shape.
- A group that did not take part is not empty. An optional currency prefix that is absent
  did not take part. Go's `FindStringSubmatch` gives `""` for the two cases. Thus the
  executor reads the index pairs, where a group that did not take part has the index -1.
  Do not change to the string form.
- The list is sorted and has no duplicates. The sequence in which an executor ran its
  entries is not part of the result.
- When a required field is missing, the returned extraction still holds the fields that
  were read and the empty groups. This is the case that the diagnostic is for. When the
  match block refuses the message, the extraction is the zero value.

The errors of the match gate quote the anchor of the template, never the text of the
message. A caller can log them. Do not put text from a message into an error or a label.

Applies to: `server/internal/tmpl/exec.go` (`Extraction.EmptyGroups`,
`Compiled.Execute`, `Compiled.gate`, `execState.recordEmptyGroups`).

## An amount has exactly two decimals and comes only from a capture

After the commas are removed, an amount must be digits, a point and exactly two digits,
with no sign. The bank alerts of the corpus always write two decimals. Money is always
positive, and the direction carries the sign. A capture with no decimals, with three
decimals or with a sign is a conversion failure. The executor does not guess.

The `amt` group must hold the number only. A pattern whose `amt` group also takes a
currency prefix fails the conversion on purpose. The format has an optional `ccy` group
for the currency. Two permitted spellings of the same thing would need two parsers in
each executor.

An amount or a date never comes from a literal. A `const` entry, a `flag` entry and
`on_match` can set the direction, the transfer flag and text, but not an amount or a
date. No literal spelling of these two is defined that each executor reads in the same
way. They come only from the typed conversion of a capture.

Applies to: `server/internal/tmpl/exec.go` (`amountShapeRe`, `convertAmount`,
`checkLiteral`).

## Date conversion follows Go's `time.Parse`

For each layout that the definition names, in sequence, the executor tries the full
trimmed capture and then the text before the first U+0020. The first success wins. The
split is at the first U+0020 only, not at "any whitespace": each executor finds that one
code point in the same way. If each layout fails on the two attempts, the conversion
fails. A zero time is never given out as a date.

Go's `time.Parse` decides these points. A parser written by hand does not get them by
accident, and each one can put a different date on a transaction:

- Month names match without case (`jun` is June). The AM/PM marker must be upper case.
- A numeric field of two digits needs exactly two digits. `5/Jun/2026` does not parse.
- Calendar ranges are checked. `31-02-2026` is an error, not 2 March.
- No layout has a zone, so the result is UTC.
- Text after the date is an error. This is why the first-token attempt is necessary.

`TestDateParsingSemanticsTheTypeScriptMirrorMustReproduce` pins them in Go, and
`conformance/templates/synthetic-dates.json` pins them for the Swift executor. Do not
change the date code of one executor alone.

Applies to: `server/internal/tmpl/exec.go` (`convertDate`, `parseLayout`).

## The last four digits are ASCII digits only

The last4 conversion drops each character that is not a digit and keeps the last four
digits. A capture with no digit is a conversion failure.

A digit is ASCII `0` to `9` and nothing else. The mail is Arabic, and Unicode counts the
Arabic-Indic digits (U+0660 to U+0669) as digits, but the banks do not write card
numbers with them. The regex engines also do not agree on what a digit class contains.
With a Unicode digit rule, two executors could read two different cards from one mail.

Applies to: `server/internal/tmpl/exec.go` (`convertLast4`).

## A sender domain matches on label boundaries

The sender-domain check compares the verified signing domain of a mail with the
`sender_domain` list of a definition. It is a suffix match on label boundaries: the
listed domain `bank.example` covers `alerts.bank.example` and does not cover
`evilbank.example`. A plain string suffix test covers the two, and a look-alike domain
costs little to register.

- The comparison ignores ASCII case, and a trailing root dot is removed.
- A value that does not have the shape of a domain matches nothing. `.bank.example` has
  an empty first label, and a suffix test would accept it as a name under
  `bank.example`. This is the same hole, from a malformed input.
- A text template matches no domain.

This function is the one statement of the rule in Go. The oracle gates call it. Do not
write the rule a second time in another form: two forms can select different templates.
The input must be the verified domain, never the `From` line of the body.

Applies to: `server/internal/tmpl/exec.go` (`MatchesSenderDomain`).

## One unbounded quantifier stays legal, and the templates bound its cost

The dialect refuses a pattern with two or more unbounded quantifiers in one branch. It
permits one. One unbounded quantifier is quadratic in a backtracking engine when the
match fails, because the engine tries each start position again. Go's RE2 does not
backtrack, so the Go executor is linear on each pattern, also on a pattern that the
dialect refuses.

Measured on 2026-08-01 in a JavaScript engine (Bun 1.3.14, `u` flag), pattern `[0-9]+z`:

| Input | Time |
| --- | --- |
| 50,000 digits | 1,162 ms |
| 100,000 digits | 4,459 ms |
| 200,000 digits | 17,935 ms |

The body bound is 2,000,000 bytes. Thus the dialect alone does not bound the cost of a
template on the phone. This gap is known, and the dialect does not close it. The bound
is a property of the published templates: each anchor has a mandatory literal prefix (the engine's prefix
scan drops almost all start positions) or a bounded run (each start position is cheap).
Measured in the same engine on a hostile body of 1 MB:

| Anchor | Time |
| --- | --- |
| A literal heading, then `([^\n]+)` | 1.8 ms |
| A literal heading, then a bounded amount | 3.5 ms |
| The ENBD alert amount with an unbounded run `[0-9][0-9,]*` first | 333,859 ms |
| The same anchor with the bounded run `[0-9][0-9,]{0,24}` | 15.6 ms |

The seed templates use the bounded run. `{0,24}` covers each amount that a 64-bit
integer can hold, and each corpus row extracted the same value before and after the
change.

A ban on patterns with no leading literal was rejected. `DEBIT$` is a seed anchor with
no leading literal, and the ENBD amount anchor starts with an optional currency group.
Such a rule would make these anchors impossible to write. The cost is measured and not
ruled: the template tests of the phone run each bundled template on hostile bodies, and
ICU's limit is the backstop (`docs/decisions/code/ios-sync-to-template.md`).

When you add a pattern, give it a mandatory literal prefix or a bounded run.
`TestKNOWNASingleUnboundedQuantifierIsStillQuadraticInJavaScript` asserts only that the
shape is still legal in the dialect. When it fails, the dialect changed and this section
must be written again.

Applies to: `server/internal/tmpl/exec_test.go`
(`TestKNOWNASingleUnboundedQuantifierIsStillQuadraticInJavaScript`),
`server/internal/tmpl/seed/enbd.alert.v1.json`.

## Template fixtures hold base64 text, decimal amounts and every field

The files in `conformance/templates` have these format rules. The Swift tests read the
same files, so the format is a contract.

- The subject and the normalized body are base64. They hold CR, U+FEFF, bidi controls
  and Arabic. An editor or a tool can change such characters in a JSON string, and the
  diff does not show it.
- `amount_minor` is a decimal string. A 64-bit integer does not survive a JSON reader
  that keeps numbers as doubles: 9,007,199,254,740,993 becomes a number that ends in
  992.
- Each case records each expected field, also when the template did not match. One
  executor can return a partial extraction where the other returns the zero value. A
  check of only the matched cases does not see that difference.

Applies to: `server/internal/tmpl/fixtures.go` (`TemplateCase`, `TemplateExpect`).

## The synthetic fixtures cover what the corpus cannot

The corpus fixtures are real bank mail (in the private fixtures repository). They are
the only proof that the executors agree on mail that really arrives. They were measured
to be blind in three ways when the synthetic fixtures were written:

1. Almost all ENBD messages of the corpus are transfer advices. The few alert messages
   are debits. Thus the credit path of the alert template has no corpus case, and no
   corpus amount has a currency other than AED.
2. No corpus case gives an empty capture group. Thus the corpus never compares the
   empty-group list.
3. Real mail is well-formed. The conversion rules are mostly about malformed input: an
   amount with three decimals, a year of two digits, a capture with U+00A0 around it.

The third class is where two executors written by hand differ with no error. Library
functions do not agree: a library trim also removes U+00A0 and U+FEFF, and a library
upper-case maps U+00DF to `SS`. Each of these differences is a synthetic case.

- Each expected value is the output of the Go executor, never the value that the name
  of the case suggests. A case with a wrong name does no harm.
- The currency fixture has a case with a dotless i (U+0131). The ASCII upper-case rule
  leaves it as it is, the result is not three upper-case letters, and the amount does
  not convert. A library upper-case makes `IED` from it. An executor that used the
  library would read an amount in a currency that nobody wrote, with no error.
- The currency class of that fixture is `[^ \n]{3}` and its entry has no `i` flag, on
  purpose. The case tests the conversion. With the flag, the different case folding of
  the regex engines for U+0131 would also come into the case.

Do not delete the synthetic fixtures because the corpus fixtures exist, and do not add
the `i` flag to the currency fixture.

Applies to: `server/internal/tmpl/synthetic_test.go` (`syntheticCurrency`,
`TestWriteSyntheticTemplateFixtures`).

## The seed anchors are the bank's own bytes, and the corpus gate proves the seeds

The seed templates are the declarative port of the ledgerd v1 parsers. A bank format is
data: a broken anchor is corrected in a template, not in parser code.

The Arabic anchors were extracted from the v1 parser source, which is frozen at
`server/oracle/v1ref/parse/dib.go`. Nobody typed them. A spelling "correction" during a
copy gives a template that compiles, passes the publish gate and then matches nothing,
with no error. DIB writes one of its anchors without a hamza, and the spelling with a
hamza matches no DIB mail of the corpus. `TestSeedAnchorsAreByteIdenticalToV1` (in
the oracle module) derives the anchors from the frozen source again on each run. Do not
type or "correct" an anchor. Copy the bytes from the bank's mail.

The v1 DIB parser read two layouts and chose between them with one test for the heading
of the card notice. A template has no control flow. Thus there are two templates whose
match blocks are complements: `dib.card.v1` has the heading in `body_contains`, and
`dib.account.v1` has it in `body_not_contains`. They are disjoint by construction, and
this makes them equal to the branch. `dib.account.v1` also excludes the headings of the
DIB layouts that have their own templates (transfers, refunds). A transfer notice whose
status is not completed reaches no template. A new DIB mail template must keep the set
disjoint.

Review does not prove a seed. The corpus gate
(`server/oracle/gates/tmpl/seed/corpus_gate_test.go`) runs the v1 parsers and the
templates on each message of the private corpus and requires the same output on all
eight extracted fields. That gate was the ship condition of spec §3.5.

Applies to: `server/internal/tmpl/seed/seed.go`, `server/internal/tmpl/seed/*.json`.

## The publish gate has three steps, and the dialect gate is its own step

ledgerd's template store and its publication log are gone (spec 02 D-2: the server does
not distribute templates). The publish gate stays, because the embedded seed and the
bundled templates of the phone must pass it. It has three steps, in this sequence:

1. The dialect gate, on each pattern.
2. The definition validator: field and type pairs, required fields, the override budget,
   the sender requirement.
3. `Compile`, the contract of the executor.

Step 2 also calls the pattern validator at this time. Step 1 runs first and alone on
purpose. A refactor of step 2 must not be able to remove the dialect gate as a side
effect. Its removal must be a visible deletion.

`Compile` does not run the definition validator again. That validator is policy for
publish time, and it is the expensive half (it compiles each pattern a second time).
`Compile` checks only what execution needs: the executor must be able to get a value for
each entry. Without step 3, a definition can pass the validator, ship and then read
nothing, with no error.

Applies to: `server/internal/tmpl/validate.go` (`ValidateForPublish`),
`server/internal/tmpl/exec.go` (`Compile`).

## A decode witness is a `body_contains` literal with a non-ASCII rune

A DKIM signature covers the bytes of the body. `Content-Type` and
`Content-Transfer-Encoding` decide how those bytes become text. When a signer does not
sign these two headers, a holder of the message can change one of them. The signature
still verifies, and the same bytes decode into other text.

A gate literal of a template is compared with the decoded text. A literal that is found
is thus a measurement of the decode, but only if another decode could not have produced
it. `DecodeWitnesses` returns the literals for which this is true. The rule:

- The literal must have a minimum of one non-ASCII rune. An ASCII literal proves
  nothing: each charset that a mail decoder accepts agrees with US-ASCII on the low 128
  values. A literal with a non-ASCII rune pins the charset of its bytes (Arabic under
  UTF-8 is mojibake under ISO-8859-1), and it pins the transfer decoding when the bank
  uses base64 or quoted-printable.
- Only `body_contains` literals count. `subject_contains` is compared with the subject,
  which is not the text that the amount comes from. `body_not_contains` is an absence,
  and an absence is what an incorrect decode produces. An absence as proof would read
  the attack as proof of no attack.
- A text template has no witness. A text is not decoded.
- The function tells which literals can be a witness. The caller must examine that they
  are in the text that the extraction read.

At this time no code path uses the result: the ledgerd ingest pipeline that trusted a
witnessed message is gone, and the phone takes its trust from the mail provider's
verdict. `server/internal/tmpl/seed/witness_test.go` still records, for each seed
template, whether it has a witness. If a trust decision uses this function again, do not
make the rule weaker.

Applies to: `server/internal/tmpl/witness.go` (`Definition.DecodeWitnesses`).
