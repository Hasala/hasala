# The oracle corpus gates and the website build: decisions from the code (2026-11-21)

These decisions were code comments under `server/oracle/gates` and `web`. Code
comments are not permitted (`scripts/comment-lint.ts`), thus the decisions are here.

## Normalizer corpus gate: the bar and the shadow

`TestCorpusEquivalence` runs the frozen v1 pipeline (`parse.BodyText`, then
`parse.Unwrap`, then `parse.ParseForwardDate`) and `Normalize` on each message of a
copy of the v1 corpus. The bar is `other == 0`. It is not "no differences". These
differences are designed in and are permitted:

- **D1, the trim set.** v2 trims the explicit set {09 0A 0B 0C 0D 20 A0 FEFF}. v1 uses
  `strings.TrimSpace`, which also trims U+0085, U+2000 to U+200A and U+202F, and does
  not trim U+FEFF. One side drops a line that has only such characters, and the other
  side keeps it. The corpus has the two directions.
- **D2, the raw fallback.** When the MIME parse fails, v2 uses the raw body. v1 returns
  an error and records nothing. No corpus message reaches this branch, thus a derived
  fixture must cover it.
- **The partial walk.** v1 abandons a MIME tree from which v2 gets a real text leaf.
  The cause is the same as D2 (v2 does not discard text that it can recover). The gate
  counts it on its own line and does not put it in D2.

A message that v1 reads and v2 fails on is never permitted.

The gate decides D1 by substitution. `shadowV1Trim` calls `NormalizeWithTrim`, the
function that `Normalize` wraps, with the trim of v1. A difference is D1 only when
that one change removes it. The rule: the shadow calls the production code and changes
one argument. Do not copy a line of the normalizer into the test. A part that the
shadow implements again is invisible to the gate: a defect that the copy does not have
leaves the shadow in agreement with v1, the gate counts the row as D1, and the gate
passes. This was measured two times. A shadow that implemented the trim stages again
passed a mutation that deleted the entity decode, although almost all messages
changed. A shadow that implemented the nine lines of the wrapper again passed five
one-line defects: the outer subject kept, the outer From kept, the forward date not
connected, the HTML strip applied to a raw leaf, and the text stored before the
unwrap. The trimmer parameter of the normalizer exists for this test.

The probe (`TestCorpusDivergenceFromV1IsOnlyTheTrimSet`) does not use a list of
permitted message ids. It trims each line of the two texts with the two trim sets,
drops the lines that become empty, and then requires equal text. A difference that
does not come from the trim set stays and fails the test, and the check stays correct
when the corpus becomes larger.

The gate cannot examine the trim set, because the trim set is its permitted
difference. A character that somebody adds to the trim set passes the gate.
`TestNormalizeTrimsTheExplicitSetNotGoTrimSpace` and the conformance fixture
`hair-space-lines-survive` fail on that change. Do not add a trim-set assertion to the
gate. Add fixtures there. Four more mutations change no corpus message, thus no
comparison with v1 can find them: the `</div>` entry of the block tags, the `15:04:05`
forward-date layout, the address-list parse of From, and the selection among two
`text/html` leaves.

When the gate fails, correct the normalizer. If v2 is right and v1 was wrong, record
the new divergence with its reason in the design record (v2-normalizer-v1, ledgerd
design archive). Do not add a class to the gate to absorb a failure. A gate that gets
a new class for each failure measures nothing.

Applies to: `server/oracle/gates/norm/corpus_test.go` (`TestCorpusEquivalence`,
`shadowV1Trim`), `server/oracle/gates/norm/corpus_probe_test.go`
(`TestCorpusDivergenceFromV1IsOnlyTheTrimSet`), `server/internal/norm/oracle_hooks.go`
(`NormalizeWithTrim`).

## Corpus gates fail on an unusable, small or empty corpus

A checkout with no corpus skips the corpus gates (`HASALA_CORPUS_DB` is not set). A
path that is set and cannot be used fails the gate. It does not skip. A wrong path
must not switch a gate off silently.

Each gate also has a floor on the size of the corpus (`recordedCorpusSize`, the
message count of the last recorded pass, minus 10%). The `ingest_log` of v1 only
grows. Thus a snapshot with fewer rows is cut, old, or a different database. Without
the floor, a database with the correct schema and no rows passes with zero
differences. The value is a floor and not an exact count, because the live v1
instance continues to get mail. The 10% band accepts a snapshot that is a little
older. Change the value when you record a new pass.

The seed gate has a second floor (`recordedV1TemplateHits`, the number of messages
that the template tier of v1 read at that pass, minus 10%). The size floor does not
stop a corpus of the correct size whose mail no longer reaches the template tier: a
sender domain helper that is broken, a `Match` block that no longer matches, or a
normalizer that returns empty text. In that condition the gate compares no result with
no result and reports zero mismatches. With the second floor, "the gate compared
nothing" is a failure.

Applies to: `server/oracle/gates/norm/corpus_test.go` (`recordedCorpusSize`,
`TestCorpusEquivalence`), `server/oracle/gates/tmpl/seed/corpus_gate_test.go`
(`recordedCorpusSize`, `recordedV1TemplateHits`,
`TestSeedTemplatesReproduceV1OverTheFullCorpus`).

## Template corpus fixtures: a capped sample and a writer filter

`TestWriteTemplateFixtures` writes at most `templateFixtureCap` cases for each
template. The cap keeps the committed set small enough to review. The cap is not the
full check: the seed gate reads the full corpus. The writer takes the sample at an
even stride through the corpus in id order, with the first id and the last id always
included. The id order is the time order, thus each year of the corpus has its share.
A sample that takes the first rows contains only the oldest months.

`HASALA_TEMPLATE_FIXTURE_ONLY` limits a regeneration to the named templates. The
corpus fixture files come from different snapshots, and a regeneration takes the
sample again. When the corpus is one day larger, the stride moves and the large DIB
files change in thousands of lines. Nobody reads such a diff, and it imports real mail
again for a change that did not touch those templates. The filter limits only the
writer. `TestTemplateFixturesAreWhatThisBuildProduces` runs each committed file again
on each run, thus a file that was not regenerated is still examined.

Applies to: `server/oracle/gates/tmpl/corpus_writer_test.go` (`templateFixtureCap`,
`templateFilterEnv`, `sampleEvenly`).

## The harness sender domain is not the trust check

The corpus harness gets a sender domain from the stored From address of a v1
`ingest_log` row (the text after the last `@`). The From header is content and is not
verified. The harness uses this domain only to select the templates that are worth a
run on a message. A wrong value only gives a case with no match. Do not use this
helper as a trust decision. The real check is `MatchesSenderDomain` on the domain that
DKIM or ARC verified. v1 gated on the full From header, and v2 gates on a verified
signing domain that an old `ingest_log` row does not have, thus the helper is an
approximation of a fact that the two sides do not store.

Applies to: `server/oracle/gates/tmpl/corpus_writer_test.go` (`senderDomain`),
`server/oracle/gates/tmpl/seed/corpus_gate_test.go` (`senderDomain`).

## Seed template corpus gate: the bar, the harness and its blind spots

`TestSeedTemplatesReproduceV1OverTheFullCorpus` is the ship condition of spec §3.5:
the seed templates must give the output of the three v1 parsers on the full corpus. It
compares v1 (`parse.BodyText`, `parse.Unwrap`, the cascade of the DIB, ENBD and ENBD
alert parsers) with v2 (`norm.Normalize`, then `tmpl.Execute` for each seed whose
`Match` gates pass).

The bar:

- Mismatches must be 0. A mismatch is a different value in one of the eight compared
  fields.
- Misses must be 0. A miss is a result from the template tier of v1 and no result from
  v2.
- Ambiguous must be 0. Two seeds claimed one message. v1 stops at the first parser that
  matches, thus a second claim shows that the `Match` blocks do not divide the mail.
- New matches are permitted. Record each one with its reason in the design record
  (v2-seed-validation, ledgerd design archive), because "v2 read more" and "v2 read the
  wrong thing" look the same in this test. `v1Excuse` gives the reason that v1 had no
  template result.

Rules for the harness:

- The test does not implement the v1 side again. It builds the cascade as the v1
  command does and computes the fallback date as the v1 processor does. A gate that
  copies the thing it examines cannot see a defect in it.
- When a field comparison fails, change the template JSON. Do not make the comparison
  wider. `samePostedAt` uses `Equal` only because `==` on `time.Time` also compares
  the monotonic reading and the location pointer.
- `runGate` takes the definitions as a parameter. A mutation test can then give it a
  broken template and read the counts. Keep the parameter. The alternative is an edit
  of the committed JSON in a worktree that other sessions compile.
- The gate selects the v2 templates with the From of `norm.Result`, not with the
  `from_addr` of the row. For an inline forward these are different senders, and v1
  gates its parsers on the sender from the inner header block. A gate on the outer
  address counted forwarded messages as misses although no template failed. The
  normalizer gate proves that the From of `norm.Result` is equal to the From that v1
  recovers.

What the corpus cannot see. A mutation test made 26 one-edit defects in the
templates. The corpus found 15 of them and found none of these: a whole-line capture
for the card or account last four digits; the removal of the DEBIT or CREDIT suffix
rule; the suffix rules after the cascade; a default direction of debit; the removal of
the from-account preposition rule or of the deposit notice rule; the removal of the
case-insensitive flags; the removal of the date-only fallback layout of the ENBD
transfer; the removal of the credit branch of the ENBD alert. Real bank mail does not
take these branches. For example, no account or card line in the DIB mail has a space,
each ENBD transfer advice has a time with its date, each ENBD alert in the corpus is a
debit, and the description suffix always agrees with the cascade. Thus a pass on the
full corpus is no evidence about the order of the direction entries.
`TestSeedReproducesV1OnTheBranchesTheCorpusNeverExercises` covers these branches, and
it is necessary. It is a differential test and not a table of expected values: the v1
parser computes the expected value on each run, thus an expectation cannot move away
from v1. The task is "read what v1 reads, also where v1 is unusual".

The two tests together still cannot see a pattern alternative that v1 got after the
seed was made from it. This occurred with the third debit verb of the ENBD alert: no
corpus message and no synthetic case had it, and the alert missed the template tier
until a real message arrived. When a seed pattern and a parser in `oracle/v1ref/parse`
must be the same function, compare their alternatives literally. Do not rely on the
two tests for that.

Applies to: `server/oracle/gates/tmpl/seed/corpus_gate_test.go`
(`TestSeedTemplatesReproduceV1OverTheFullCorpus`, `runGate`, `samePostedAt`,
`TestSeedReproducesV1OnTheBranchesTheCorpusNeverExercises`).

## Seed anchors are compared with v1 by bytes

The payee anchor in DIB mail is spelled with a plain alef. The spelling with a hamza
on the alef is one code point different and looks like a correction. A template with
the hamza spelling compiles, validates and publishes, and it matches no DIB message. A
person who reviews right-to-left Arabic in a JSON string does not find this reliably.

Thus `TestSeedAnchorsAreByteIdenticalToV1` reads each anchor from the source of
`oracle/v1ref/parse/dib.go` and requires the seed JSON to contain the same bytes. The
test finds each anchor by the ASCII text around it. Do not type an Arabic literal in
the test file, and do not copy the anchors into it: a copy has the same risk. The one
exception is the hamza spelling, which the test contains to reject it. The table of
synthetic cases gets the anchors as a parameter for the same reason.

Applies to: `server/oracle/gates/tmpl/seed/corpus_gate_test.go`
(`TestSeedAnchorsAreByteIdenticalToV1`, `readV1Anchors`, `v1Anchors`,
`syntheticCases`).

## DIB seed templates partition DIB mail

v1 has one DIB parser with an `isCard` branch. The seeds have one template for each
layout. They are equivalent only because the card template requires the literal that
the account template excludes, thus no DIB message can match the two. Each other pair
of DIB templates is disjoint in the same way. Keep this property when you change a
`Match` block. The `ambiguous` count of the corpus gate finds a message that matches
two templates only if the corpus contains one.
`TestDIBSeedsPartitionEveryDIBMessage` holds the property with no corpus.

Applies to: `server/oracle/gates/tmpl/seed/corpus_gate_test.go`
(`TestDIBSeedsPartitionEveryDIBMessage`), `server/internal/tmpl/seed`.

## The direction entries of dib.account.v1 need no override

The DIB parser of v1 computes the direction in two steps: a cascade of four cases,
then a second value from the DEBIT or CREDIT suffix of the description, which
replaces the result of the cascade. A literal port needs `override` two times, and
`ValidateDefinition` permits it one time on purpose.

The template puts the two suffix rules first. The first entry that gives a value
wins, thus the suffix rules win and the cascade behind them runs only when no suffix
is there. This is the same function as v1, not an approximation. The template has six
direction entries: the DEBIT suffix, the CREDIT suffix, then the four cases with the
unconditional default last. Do not move the suffix rules behind the cascade, and do
not add an `override` or a multiple-override extension to the template format for this.
The corpus cannot find a wrong order (see the section above).
`TestSeedDirectionCascadeNeedsNoOverride` and the synthetic cases hold it.

Applies to: `server/oracle/gates/tmpl/seed/corpus_gate_test.go`
(`TestSeedDirectionCascadeNeedsNoOverride`), `server/internal/tmpl/seed`
(`dib.account.v1`).

## ENBD seed anchors depend on the whitespace collapse of the normalizer

The two ENBD parsers of v1 accept runs of whitespace (`\s+`, `\s*`): spaces after a
label, empty lines between a label and its value, and an indented value. The seeds do
not. Their separator class is one character, and a value must start the line directly
after its label. This is correct because the templates do not read the raw text. The
normalizer (`collapseWith`) replaces each run of space, tab and U+00A0 with one space,
trims each line and drops each empty line. After that step these shapes cannot exist.

Do not make the body anchors tolerant. The tolerant form of the alert anchor has
three unbounded quantifiers in one alternation branch, and the template dialect
refuses that shape because of polynomial backtracking. If the property stops, the
correction is in the normalizer, not in the pattern.

The exception is the last four digits of the ENBD alert, which come from the subject.
A subject is decoded and trimmed and is not collapsed. Thus that anchor uses `+` for
its separator.

`TestTheNormalizerRemovesTheWhitespaceVariationTheENBDAnchorsCannotExpress` holds the
property, because it is a property of a different package.

Applies to: `server/oracle/gates/tmpl/seed/corpus_gate_test.go`
(`TestTheNormalizerRemovesTheWhitespaceVariationTheENBDAnchorsCannotExpress`),
`server/internal/tmpl/seed` (the ENBD templates), `server/internal/norm/norm.go`
(`collapseWith`).

## Website: the CSP is built from the same inputs as the pages

The CSP in `web/astro.config.mjs` must agree with the code of the pages. Three
settings keep it so:

- The config reads the `PUBLIC_*` settings with `loadEnv`, the same way as Astro reads
  them for the pages (the `.env` files included). A read of `process.env` only gives a
  CSP for a different API origin or waitlist mode than the pages use.
- Astro adds hashes only for the scripts that it bundles. The config adds the hash of
  each inline `<head>` script in `src/lib/inline-scripts.mjs` (`INLINE_SCRIPTS`). An
  inline script that is not on that list is blocked.
- Markdown syntax highlight is off. Shiki writes inline `style` attributes, and they
  need `'unsafe-inline'`. The legal Markdown has no code blocks.

Applies to: `web/astro.config.mjs`, `web/src/lib/inline-scripts.mjs`.

## Website: one CSP for every page

`<ClientRouter />` keeps the policy of the first page for the full visit. A page with
a different policy is thus governed by the policy of the page where the visit
started. `src/lib/csp-union.mjs` writes one policy into each page after the build, and
`scripts/check-dist.ts` examines it independently: one CSP `<meta>` for each page,
marked `transition:persist`, with the same policy, and each inline script and style
permitted by its hashes. Do not give a page its own policy in its `<meta>`. A stricter
policy for a page goes in a header in `public/_headers`, as for the pages with a code
or a token in their address (`CLAUDE.md`, "Third-party scripts").

Applies to: `web/astro.config.mjs` (`cspUnion`), `web/scripts/check-dist.ts`,
`web/src/lib/csp-union.mjs`.

## Website Worker: a zone route, not a custom domain

The Worker serves `hasala.app/*` through a zone route. A custom domain is not used,
because the deploy token cannot manage custom domains. A change to a custom domain
makes the deployment fail.

Applies to: `web/wrangler.jsonc` (`routes`).

## Website Worker: the empty previews block

`wrangler.jsonc` has `"previews": {}`. Workers Builds runs `wrangler preview` for each
branch that is not `main`, and that command requires the block. Without it, each
preview build fails. The block is empty because the assets and the compatibility
settings stay at the top level.

Applies to: `web/wrangler.jsonc` (`previews`).

## Website Worker: request logs stay off

`observability` is off for the Worker. Request logs record paths, and the path of
`/i/<code>` contains an invite code. Invite codes must not be in a log. Do not switch
it on. This is the same rule that keeps Web Analytics off these pages.

Applies to: `web/wrangler.jsonc` (`observability`).

## The mark in the emails is a PNG

The header of the transactional emails shows the mark as a PNG
(`brand/hasala-mark-email.png`, 120 x 72 pixels for 40 x 24 points at 3x). Gmail and
Outlook do not show SVG images in mail. Do not replace it with the SVG mark.
`bun run icons` makes the file.

Applies to: `web/scripts/icons.ts`, `server/internal/mail/templates/layout.html.tmpl`.
