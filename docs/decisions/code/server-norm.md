# Go normalizer (norm): decisions from the code (2026-11-21)

These decisions were code comments under `server/internal/norm`. Code comments are
not permitted (`scripts/comment-lint.ts`), thus the decisions are here.

The Go normalizer is the reference for the Swift normalizer of the phone. The decisions
that the two share are in `docs/decisions/code/ios-money-to-projection.md` (the pinned text
operations, the MIME reader, the versions, content against identity) and in
`docs/decisions/code/ios-scripts-to-tools.md` (the charset tables). This document has only
the decisions that those documents do not record.

## The corpus gate swaps only the trim, inside the real pipeline

The corpus equivalence gate (`server/oracle/gates/norm`) proves one claim: on real mail,
the v2 normalizer differs from the v1 normalizer only through the trim set. The gate proves
it with a run of the real pipeline in which one argument is different: the line trim. It
passes `strings.TrimSpace` in place of the explicit trim set and changes nothing else.

Thus the stages that trim take the trim as a parameter (`trimmer`), and the composition of
the stages is in `normalizeWith`, not in the gate.

The rejected alternative is a copy of the stages, or of the composition, in the test. A
copy does not share a defect of the real code. Then the copy continues to agree with v1,
the gate counts the defect as an expected trim difference, and the gate passes. This was
measured two times:

- A gate with a copy of the stages passed when the entity decode of stage 6 was deleted.
  That deletion changed 6,808 of 7,002 corpus messages.
- A gate with a copy of the composition passed five defects of one line each (for example
  the outer Subject in place of the inner Subject, and an HTML strip on a raw leaf). Each
  defect changed as many as 56 messages.

The rules:

- Production always uses `trimExplicit`. Only `Normalize` and the gate go into
  `normalizeWith`.
- `oracle_hooks.go` exports the seams (`Trimmer`, `NormalizeWithTrim`, `TrimExplicit`,
  `HeadersOf`) for the oracle module only (spec 02 §4.3). They add no behaviour. Code in the
  main module must not call them.
- Do not move a part of the pipeline into the gate, and do not write a second
  implementation of a stage for a test.

Applies to: `server/internal/norm/norm.go` (`trimmer`, `normalizeWith`, `collapseWith`),
`server/internal/norm/unwrap.go` (`unwrapForwardWith`, `parseForwardDateWith`),
`server/internal/norm/oracle_hooks.go`, `server/oracle/gates/norm/corpus_test.go`.

## A message that does not parse still gives text

The normalizer gives text for a damaged message. It does not give nothing. The reason is
the rule "do not drop data silently" (`CLAUDE.md`, and §2 of the normalizer contract): a
message with no recorded body cannot go to Review in a useful form. The v1 normalizer
stopped on these messages and recorded no body.

- When the MIME structure of the message does not parse, the text is the raw body after the
  first empty line (`PartRaw`). The Subject and the From come from a scan of the raw header
  lines, because Review and the templates read the Subject.
- When the walk of a multipart tree stops on a part that cannot be made, the leaves that
  were already collected stay. A truncated multipart usually has a first leaf that is
  complete. The raw body is used only when the walk collected no text leaf.
- When the body of one leaf does not decode (incorrect base64, a truncated part), that leaf
  is skipped and its partial bytes are discarded. The walk continues.
- `ErrNoTextPart` is only for a well-formed message that has no `text/html` leaf and no
  `text/plain` leaf.

Do not change a skipped leaf or a stopped walk into an error for the whole message. The
message then gives no text. The Swift normalizer makes the same choices at the same places
(`docs/decisions/code/ios-money-to-projection.md`), and the two must stay the same.

Applies to: `server/internal/norm/norm.go` (`extract`, `walker.walk`, `scanRawHeaders`).

## Invalid UTF-8 gives one U+FFFD for each maximal subpart, and a BOM passes through

Stage 3 decodes UTF-8 with the error handling of the WHATWG Encoding Standard: one U+FFFD
for each maximal subpart of an ill-formed sequence. This is what a `TextDecoder` does, and
the Swift normalizer does the same.

Do not replace `decodeUTF8WHATWG` with `strings.ToValidUTF8`. That function gives one
U+FFFD for a full run of invalid bytes. Do not replace it with a `utf8.DecodeRune` loop.
That loop gives one U+FFFD for each byte. With one of these, Go and the phone give
different text for each message whose charset declaration is wrong (for example a
windows-1256 body with the label `utf-8`). Nobody sees that difference until such a message
arrives.

A U+FEFF at the start is not removed in this stage. The trim of stage 8 removes it where it
is. An implementation on another platform must also let the BOM through its decoder.

Applies to: `server/internal/norm/norm.go` (`decodeUTF8WHATWG`).

## A body and an encoded word resolve a charset label through different registries

A charset label is resolved in two places, and the two places do not use the same
registry:

- A body goes through the charset reader of go-message: first the short circuit for
  `utf-8` and `us-ascii`, then its registry chain (which includes the IANA index), then the
  body with no change when the registry fails.
- An RFC 2047 encoded word in a header goes through `golang.org/x/text/encoding/htmlindex`
  only. That is the label table of the WHATWG Encoding Standard, the same table that a
  `TextDecoder` uses. `mime.WordDecoder` handles `utf-8`, `iso-8859-1` and `us-ascii` itself
  before it calls the reader.

The two give different results for some labels. `ansi_x3.110-1983` is an alias of
ISO-8859-1 for a body and is unknown for a word. Each name that only the IANA index knows
(for example `ibm037` and `iso-8859-16`) is the same.

Thus the generator of the charset tables classifies each label two times, one time against
each registry, with the same probe (`classifyDecoder`). The generated file has one map for
bodies and one map for words. Do not use the body map for a header, and do not make one map
from the two. A Subject in a legacy charset would then decode differently on the phone and
in Go.

Applies to: `server/internal/norm/norm.go` (`wordDecoder`),
`server/internal/norm/twin_test.go` (`classifyDecoder`, `resolveCharsetLabel`,
`resolveWordCharsetLabel`).

## The charset label list holds each label that Go resolves

The charset tables for the phone are generated from a list of candidate labels
(`charsetLabels`). The real corpus needs only three of them: `utf-8`, `windows-1256` and
`us-ascii`. The list is much longer on purpose.

The phone treats a label that is not in the generated tables as unresolved: the bytes pass
with no decoding. Go decodes each label that its registry resolves. Thus a label that Go
resolves and the list does not have gives different text on the phone, with no error.

The rules:

- The list has each label that `htmlindex` resolves, and the single-byte code pages that a
  bank gateway can send. If a bank changes its encoding, the phone then has a table for it.
- The multi-byte and stateful charsets (UTF-16, UTF-32, the GB, Big5, EUC, Shift_JIS and
  ISO-2022 families) are in the list so that the generator gives them the class
  `unsupported`. The phone refuses that class and does not guess
  (`docs/decisions/code/ios-money-to-projection.md`). Without the entry, they are unresolved
  and pass as bytes.
- Do not remove a label because the corpus does not use it. Add a label when the registry
  of Go gets one.

Applies to: `server/internal/norm/twin_test.go` (`charsetLabels`, `buildCharsetTablesTS`).

## Fixture expectations are base64, not JSON strings

In a normalizer conformance case, the expected text, the expected Subject and the expected
From are base64 fields (`expect_text_base64` and the two others). They are not JSON
strings.

The reason: the output of the normalizer is not always valid UTF-8. When the charset cannot
be resolved, the raw fallback can give bytes that are not UTF-8. A JSON string cannot hold
such bytes. The writer of the fixture would replace them, the reader on the other platform
would replace them in a different way, and the suite would then compare two different
repairs of the same damage. Base64 makes the fixture the exact bytes.

Do not change these fields to strings to make the fixtures easier to read.

Applies to: `server/internal/norm/fixtures.go` (`ConformanceCase`),
`ios/HasalaCore/Tests/HasalaCoreConformanceTests/NormalizerFixtureTests.swift`.

## The real-mail fixtures name corpus messages by id

`CorpusFixtures` is a list of explicit corpus message ids. It is not a sample rule such as
"each 200th message". The corpus can get more messages, and a sample rule would then point
at different mail each time the fixtures are written again. With explicit ids, a new run of
the writer gives the same cases, and a difference in a case is a difference in the
normalizer.

Applies to: `server/internal/norm/fixtures.go` (`CorpusFixtures`).

## The forward unwrap gives the inner values, and its patterns use a literal space

Stage 10 removes the preamble and the header block of an inline forward (Apple Mail and
Gmail layouts). The transaction is what the inner message tells about, thus:

- The inner Subject is the effective Subject. One bank's transaction advice has the last
  four digits of the account only in the Subject, because the body masks the account
  number. With the outer Subject, each forwarded alert of that bank loses those digits.
- The inner Date is the effective date. A forward that arrives days after the purchase
  would otherwise give the transaction the date of the forward.
- The inner From is content. It is never used for trust
  (`docs/decisions/code/ios-money-to-projection.md`).
- When the body has no forward marker, a `Fwd:` or `FW:` prefix is removed from the Subject
  and the body stays the same.

Each regular expression of this stage writes a literal space (` *`) and never `\s`. In Go
(RE2), `\s` is tab, line feed, form feed, carriage return and space. In other regular
expression engines it is a larger Unicode set that includes U+00A0 and U+FEFF. A `\s` here
would make the Go normalizer and a port disagree with no error. Do not change these
patterns to `\s`.

Applies to: `server/internal/norm/unwrap.go` (`forwardMarkerRe`, `fwdSubjectRe`,
`fwdHeaderLineRe`, `unwrapForwardWith`).

## A forward date agrees with one of four closed layouts and is read as UTC

The Date of a forwarded header block is parsed against a closed list of four layouts
(`fwdDateLayouts`): the forms that iCloud webmail, Gmail and the Apple Mail app write.

- The list is closed. A new layout changes which messages get a date from the body and
  which get the arrival time. Thus a new layout is a new normalizer version, in Go and in
  Swift together. It is not a bug fix in version 1.
- A forward date is naive. A zone name at the end ("GST", "GMT+4") is removed: the parser
  tries the value, then the value without its last token. The result is read as UTC.
- Before the layouts are tried, U+202F and U+00A0 become U+0020. Apple Mail on recent OS
  versions writes U+202F (narrow no-break space) before AM and PM, and iCloud webmail has
  written U+00A0. Without this step, those dates do not parse and the transaction gets the
  arrival time.
- A date that agrees with no layout is not an error. The effective date is then the arrival
  time (`DateSourceReceived`).

Known gap: the list does not have the 12-hour form with seconds that the Apple Mail app on
iOS writes. Such a forward gets the arrival time. The gap came with the port from v1, to
keep the corpus equivalence gate clean. An issue records the fix.

Applies to: `server/internal/norm/unwrap.go` (`fwdDateLayouts`, `nbspReplacer`,
`parseForwardDateWith`), `ios/HasalaCore/Sources/HasalaCore/Norm/Unwrap.swift`.
