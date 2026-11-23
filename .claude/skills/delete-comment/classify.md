# Classify one shard of comments

You classify the code comments of one shard. You do not edit source files. A
tool deletes the comments later, from your verdicts.

You get three values: the repository root `ROOT`, the run directory `RUN` and
the shard name `SLUG`.

## Read first

1. `RUN/shards/SLUG.txt`: the comments. Each comment has a number, its file,
   its lines and the code that follows it. Consecutive comment lines are one
   comment.
2. `ROOT/CLAUDE.md`, sections "Decisions" and "Core principles".
3. The file names in `ROOT/docs/decisions/` and `ROOT/docs/decisions/code/`.
   Open a document when a comment is about its subject.

Open a source file only when the shard text is not sufficient. Search with
`grep` or `rg` in `ROOT` to see if a name in a comment still exists.

## The categories

Give each comment one category.

**T, tautology.** The comment says what the code already shows. Examples: a
summary of a function, a type or a test; the meaning of a name; a label for a
section; the steps of an algorithm that the code performs; a reference to a
spec section with no reason; a test comment that repeats the test name or its
assertions. A long comment can be a tautology.

**S, stale.** The comment refers to code, files, flags, tests, builds or
behaviour that no longer exist, or it tells history ("ledgerd did X", "this
used to", "was removed in"). Confirm with a search when the verdict depends on
a name. A comment that is half history and half tautology is S.

**E, excuse.** The comment lets a shortcut stay. It admits that the code is
incomplete, approximate, duplicated, hard-coded, untested, or wrong in a known
case, and a correct fix is possible. Signs: `TODO`, `FIXME`, `HACK`, "for
now", "temporary", "workaround", "good enough", "not handled", "best effort",
"until", "should be", a skipped or disabled test, a swallowed error, a
suppressed lint. The code is the problem, not the comment. Each E needs an
issue (see "Issues").

**D, decision record.** The comment gives an important reason that a reader
cannot get from the code, and its loss can make a later change break
something. Examples: an invariant, a security or privacy property, an order
that must not change, a fact about an external system (Gmail, Graph, APNs,
Postgres, Cloudflare, Apple frameworks, a bank's mail), a rejected
alternative, a trade-off with its reason, a limit that the owner accepted.
Both conditions are necessary: important and not obvious. Each D needs a place
in an ADR (see "ADR").

**K, keep.** Use K only for these: a tool or a test reads the comment; the
comment is the documentation of an example configuration file that an operator
copies (`*.example.*`); or you cannot decide after you read the code. Give the
reason.

Rules for difficult cases:

- A comment with a decision and a description is D. Move only the decision.
- A comment with a decision and history is D. Move only the decision.
- A file that has only comments becomes an empty file. That is not a reason
  for K.
- A known limit that the owner accepted, with its reason, is D. A known limit
  with a fix that somebody delayed is E.
- A comment that only names the rule a line obeys ("money is integer fils") is
  T when `CLAUDE.md` or a decision document already has the rule.
- Do not make D the safe answer. Most summaries of functions and most test
  comments are T.

## ADR

Write the decisions of this shard to `ROOT/docs/decisions/code/SLUG.md`. If the
file exists, add to it. If the shard has no new decision, do not make the file.

- If `CLAUDE.md` or a document in `docs/decisions/` already records the
  decision, write nothing. Give `covered:<path of that document>` as the
  reference of the verdict.
- Put comments that record the same decision in one section.
- Write the decision so that it is complete without the code: what is decided,
  why, and what breaks if somebody changes it. Do not copy the description of
  the code. Keep spec references such as "spec 01 §7.1".
- Use short plain sentences, as the documents in `docs/decisions/` do.
- Do not write a real name, address, amount, account or secret.

The format:

```markdown
# <Area>: decisions from the code (<today's date>)

These decisions were code comments under `<directories>`. Code comments are
not permitted (`scripts/comment-lint.ts`), thus the decisions are here.

## <Decision title, unique in this file>

<The decision, the reason, and the result of a change.>

Applies to: `path/to/file.go` (`Symbol`), `path/to/other.go`.
```

## Issues

Write the excuses of this shard to `RUN/issues/SLUG.json`, as a JSON array.
Write `[]` if there are none. One entry for each hack; many comments can share
one entry.

```json
[
  {
    "key": "short-kebab-key",
    "title": "Imperative title of the fix, 70 characters or fewer",
    "paths": ["path/to/file.go:120"],
    "comment": "The comment text, shortened if it is long.",
    "problem": "What the code does now and why that is a shortcut.",
    "fix": "What a correct implementation does.",
    "security": false
  }
]
```

Set `"security": true` when the shortcut weakens authentication, keys,
cryptography, access control or privacy. These issues are not filed in public.

## Verdicts

Write `RUN/verdicts/SLUG.tsv`. One line for each comment number, in order, with
tabs between the fields:

```
<number>	<category>	<reference>
```

The reference:

- T: empty.
- S: a few words that say what is gone.
- E: the `key` of its issue.
- D: the exact title of its ADR section, or `covered:<path>`.
- K: the reason.

Each number of the shard must have exactly one line. Count the lines before
you finish.

## Limits

- Write only these three files. Do not change other files. Do not run builds,
  tests or git commands that change state.
- Your last message is one line: the counts of T, S, E, D and K.
