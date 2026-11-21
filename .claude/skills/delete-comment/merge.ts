import { existsSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

type Entry = { n: number; path: string; line: number; hash: string; lines: number; kind: string };
type Issue = { key: string; title: string; paths: string[]; comment: string; problem: string; fix: string; security: boolean; shards?: string[] };

const outArg = process.argv[2];
if (!outArg) {
  console.error("usage: bun .claude/skills/delete-comment/merge.ts RUNDIR [--index]");
  process.exit(2);
}
const root = resolve(import.meta.dir, "../../..");

if (process.argv.includes("--index")) {
  const dir = join(root, "docs/decisions/code");
  const lines = [
    "# Decisions from the code",
    "",
    "These decisions were code comments. Code comments are not permitted",
    "(`scripts/comment-lint.ts`), so each decision that a comment recorded is in one",
    "of these documents. Each section names the files and symbols it applies to.",
    "Search this directory for a file name or a symbol before you change that code.",
    "",
    "The decisions of record of each area are one level up, in `docs/decisions/`.",
    "",
    "| Document | Sections |",
    "| --- | --- |",
  ];
  for (const file of readdirSync(dir).sort()) {
    if (!file.endsWith(".md") || file === "README.md") continue;
    const text = readFileSync(join(dir, file), "utf8").split("\n");
    const title = (text.find((l) => l.startsWith("# ")) ?? file).slice(2).replace(/: decisions from the code.*$/, "");
    lines.push(`| [${title}](${file}) | ${text.filter((l) => l.startsWith("## ")).length} |`);
  }
  writeFileSync(join(dir, "README.md"), lines.join("\n") + "\n");
  process.exit(0);
}
const run = resolve(outArg);
const CATEGORIES = new Set(["T", "S", "E", "D", "K"]);
const errors: string[] = [];
const rows: string[] = [];
const issues = new Map<string, Issue>();
const counts: Record<string, { units: number; lines: number }> = {};
const add = (cat: string, lines: number) => {
  counts[cat] ??= { units: 0, lines: 0 };
  counts[cat].units++;
  counts[cat].lines += lines;
};

const sections = new Map<string, Set<string>>();
function sectionsOf(file: string): Set<string> {
  if (!sections.has(file)) {
    const set = new Set<string>();
    if (existsSync(file)) {
      for (const line of readFileSync(file, "utf8").split("\n")) if (line.startsWith("## ")) set.add(line.slice(3).trim());
    }
    sections.set(file, set);
  }
  return sections.get(file)!;
}

for (const line of readFileSync(join(run, "pre.tsv"), "utf8").split("\n")) {
  if (line === "") continue;
  const [path, lineNo, hash, cat, ref] = line.split("\t");
  rows.push([path, lineNo, hash, cat, ref, "rule"].join("\t"));
  add(cat, 0);
}

const slugs = readdirSync(join(run, "shards"))
  .filter((f) => f.endsWith(".json"))
  .map((f) => f.slice(0, -5))
  .sort();
for (const slug of slugs) {
  const map: Entry[] = JSON.parse(readFileSync(join(run, "shards", `${slug}.json`), "utf8"));
  const verdictFile = join(run, "verdicts", `${slug}.tsv`);
  if (!existsSync(verdictFile)) {
    errors.push(`${slug}: no verdict file`);
    continue;
  }
  const keys = new Set<string>();
  const issueFile = join(run, "issues", `${slug}.json`);
  if (existsSync(issueFile)) {
    for (const issue of JSON.parse(readFileSync(issueFile, "utf8")) as Issue[]) {
      keys.add(issue.key);
      const have = issues.get(issue.key);
      if (have) {
        have.paths = [...new Set([...have.paths, ...issue.paths])];
        have.security ||= issue.security;
        have.shards!.push(slug);
      } else issues.set(issue.key, { ...issue, shards: [slug] });
    }
  }
  const verdicts = new Map<number, [string, string]>();
  for (const line of readFileSync(verdictFile, "utf8").split("\n")) {
    if (line.trim() === "") continue;
    const [n, cat, ...rest] = line.split("\t");
    const num = Number(n);
    if (!Number.isInteger(num) || !CATEGORIES.has(cat)) errors.push(`${slug}: bad line: ${line.slice(0, 80)}`);
    else if (verdicts.has(num)) errors.push(`${slug}: comment ${num} has two verdicts`);
    else verdicts.set(num, [cat, rest.join(" ").trim()]);
  }
  for (const e of map) {
    const v = verdicts.get(e.n);
    if (!v) {
      errors.push(`${slug}: comment ${e.n} has no verdict`);
      continue;
    }
    const [cat, ref] = v;
    if (cat === "E" && !keys.has(ref) && !issues.has(ref)) errors.push(`${slug}: comment ${e.n}: no issue with key ${ref}`);
    if (cat === "K" && ref === "") errors.push(`${slug}: comment ${e.n}: K with no reason`);
    if (cat === "D") {
      if (ref.startsWith("covered:")) {
        const target = ref.slice(8).split("#")[0].split(" ")[0];
        if (!existsSync(join(root, target))) errors.push(`${slug}: comment ${e.n}: ${target} does not exist`);
      } else if (!sectionsOf(join(root, "docs/decisions/code", `${slug}.md`)).has(ref)) {
        errors.push(`${slug}: comment ${e.n}: no ADR section "${ref}"`);
      }
    }
    rows.push([e.path, e.line, e.hash, cat, ref, slug].join("\t"));
    add(cat, e.lines);
  }
  for (const n of verdicts.keys()) if (!map.some((e) => e.n === n)) errors.push(`${slug}: verdict for comment ${n}, which is not in the shard`);
}

writeFileSync(join(run, "verdicts.tsv"), rows.map((r) => r + "\n").join(""));
writeFileSync(
  join(run, "strip.tsv"),
  rows
    .filter((r) => r.split("\t")[3] !== "K")
    .map((r) => r.split("\t").slice(0, 3).join("\t") + "\n")
    .join(""),
);
writeFileSync(join(run, "issues.json"), JSON.stringify([...issues.values()], null, 2));

for (const [cat, c] of Object.entries(counts).sort()) console.log(`${cat}\t${c.units}\t${c.lines}`);
console.log(`issues\t${issues.size}\t(${[...issues.values()].filter((i) => i.security).length} security)`);
if (errors.length > 0) {
  console.error(errors.join("\n"));
  console.error(`merge: ${errors.length} problem(s)`);
  process.exit(1);
}
