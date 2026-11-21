---
name: delete-comment
description: Classify the code comments of Hasala (tautology, stale, excuse, decision record), delete them, move the decisions to docs/decisions/code/, file issues for the excuses and make the comment baseline smaller. Use when the owner asks to delete comments, to make scripts/comment-baseline.txt smaller, or runs /delete-comment [path...].
---

# Delete comments

Code comments are not permitted in this repository. `scripts/comment-lint.ts`
finds each comment, and `scripts/comment-baseline.txt` lists the comments that
are still permitted. This skill makes that list smaller.

The argument is an optional list of paths. Without paths, the skill does all
comments that the lint reads.

## What the lint reads

- Go, Swift, TypeScript, JavaScript, Astro, CSS, shell, Nix, YAML, TOML,
  Python, SQL, xcconfig and JSONC files that git tracks.
- It does not read `server/oracle/v1ref/` (its bytes are frozen),
  `conformance/`, `testdata/`, `LICENSES/`, the Xcode project and the generated
  files in `EXCLUDED` of `scripts/comment-lint.ts`.
- It permits the lines that a tool reads: `//go:` directives, the
  `// Code generated ... DO NOT EDIT.` line, `// swift-tools-version:`,
  `// swiftlint:`, `// lint-allow: <name> <reason>`, `// @ts-check` and
  `// @ts-expect-error`, JSDoc types in `.js` and `.mjs` files,
  `# shellcheck`, the `#!` line, `-- +goose` lines, and the version after a
  pinned action (`uses: owner/action@<40 hex> # v1.2.3`).

## The categories

| Category | Meaning | Action |
| --- | --- | --- |
| T, tautology | Says what the code shows | Delete |
| S, stale | Refers to things that are gone, or tells history | Delete |
| E, excuse | Lets a shortcut stay in the code | Delete, and file an issue |
| D, decision record | An important reason that the code cannot show | Delete, and write it in `docs/decisions/code/` |
| K, keep | A tool reads it, or it documents an example configuration file | Keep in the baseline |

`classify.md` in this directory has the full rules. Do not change the rules
during a run. All shards must use the same rules.

## Procedure

Do the work in your own worktree, on a branch from `origin/main`. Put all
commands through `direnv exec .`. `RUN` is a new directory outside the
repository.

1. Make the shards:
   `bun .claude/skills/delete-comment/shards.ts RUN [path...]`.
   It writes `RUN/shards/<slug>.txt` (about 400 comments each), and
   `RUN/pre.tsv` for the comments that a rule classifies: `// MARK:` lines are
   T, and comments in generated files and in applied migrations are K.
2. Classify one shard and read its result before you start the others. Start
   one agent for the shard, with `ROOT`, `RUN`, `SLUG` and the instruction to
   follow `.claude/skills/delete-comment/classify.md`. Read its ADR file and its
   issues. If the result is not good, correct `classify.md` first.
3. Classify the other shards in parallel, at most 14 agents at one time. Each
   agent writes only `RUN/verdicts/<slug>.tsv`, `RUN/issues/<slug>.json` and
   `docs/decisions/code/<slug>.md`. The agents do not edit source files.
4. Merge and validate:
   `bun .claude/skills/delete-comment/merge.ts RUN`.
   It fails if a comment has no verdict, an E has no issue, or a D has no ADR
   section. Start the agent of a failed shard again.
5. Search the new ADR files for real data (amounts, dates, names, addresses,
   message ids). `CLAUDE.md` forbids them in this tree. Remove them.
6. Delete the comments:
   `bun scripts/comment-lint.ts strip RUN/strip.tsv`.
   The tool leaves a file as it is when the result changes more than comments.
7. Remove a file that is now empty, unless it is the only source file of its
   Swift target. Run `nix fmt`.
8. Make the baseline smaller: `bun scripts/comment-lint.ts ratchet`.
9. Verify:
   - `scripts/check.sh` (the gate) and `scripts/pre-push.sh --all`.
   - In `web/`: `bun run check`, `bun run test` and `bun run build`.
   - `nix flake check --no-build`, then build the checks that read changed
     files.
   - Swift does not build on Linux. Say so in the pull request. The `swift`
     and `ios-tools` jobs of CI build it on a Mac.
10. Write the index: `bun .claude/skills/delete-comment/merge.ts RUN --index`
    writes `docs/decisions/code/README.md` again.
11. Read `RUN/issues.json`. Merge the entries that are the same work. Then file
    the issues, with the commit that the shards were made from:
    `bun .claude/skills/delete-comment/file-issues.ts RUN <base sha>`.
    It files each entry one time, with the label `comment-debt`.
12. Open the pull request. Give the owner the counts for each category, the
    issue list and the lines removed.

> **WARNING:** Do not file an issue that has `"security": true`. The repository
> is public, and `CLAUDE.md` keeps security findings private.
> `file-issues.ts` writes these entries to `RUN/issues-private.md`. Give that
> file to the owner.

## The ratchet

- `bun scripts/comment-lint.ts check` fails on a comment that the baseline does
  not list, and on a baseline entry whose comment is gone.
- `scripts/check-comments.sh` adds `--base`: the baseline must not have an entry
  that the base commit does not have. The baseline only gets smaller.
- A changed comment is a new comment. Delete it; do not edit it.
- `bun scripts/comment-lint.ts stats [path...]` shows the comments that are left
  and the lines that their deletion removes.

## Limits

- The lint is a set of lexers, not compilers. `scripts/tests/comment_lint_test.sh`
  tests them. When you add a file type or a tool directive, add a case there.
- A comment inside an Astro template expression (`{cond && /* x */ <a/>}`) is
  not found. Only `{/* x */}`, `<!-- x -->`, the front matter, `<script>` and
  `<style>` are read.
- A generated file keeps its comments until its generator stops writing them.
  Then remove its path from `EXCLUDED`.
