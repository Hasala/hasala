import { execFileSync } from "node:child_process";
import { appendFileSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

type Issue = { key: string; title: string; paths: string[]; comment: string; problem: string; fix: string; security: boolean };

const LABEL = "comment-debt";
const args = process.argv.slice(2);
const dryRun = args.includes("--dry-run");
const [runArg, sha] = args.filter((a) => a !== "--dry-run");
if (!runArg || !sha) {
  console.error("usage: bun .claude/skills/delete-comment/file-issues.ts [--dry-run] RUNDIR BASE_SHA");
  process.exit(2);
}
const run = resolve(runArg);
const gh = (a: string[]) => execFileSync("gh", a, { encoding: "utf8", stdio: ["ignore", "pipe", "inherit"] }).trim();
const repo = gh(["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"]);

const issues: Issue[] = JSON.parse(readFileSync(join(run, "issues.json"), "utf8"));
const filedFile = join(run, "issues-filed.tsv");
const filed = new Map<string, string>();
if (existsSync(filedFile)) {
  for (const line of readFileSync(filedFile, "utf8").split("\n")) {
    if (line === "") continue;
    const [key, url] = line.split("\t");
    filed.set(key, url);
  }
}

function link(path: string): string {
  const m = /^(.*?):(\d+)$/.exec(path);
  if (!m) return `- [\`${path}\`](https://github.com/${repo}/blob/${sha}/${path})`;
  return `- [\`${path}\`](https://github.com/${repo}/blob/${sha}/${m[1]}#L${m[2]})`;
}

function bodyOf(i: Issue): string {
  const quote = i.comment
    .split("\n")
    .map((l) => `> ${l}`)
    .join("\n");
  return [
    "A code comment marked this shortcut. Code comments are not permitted (`scripts/comment-lint.ts`), so the comment is deleted and this issue keeps the record.",
    "",
    `**Where** (at \`${sha.slice(0, 7)}\`, before the comment was deleted)`,
    "",
    ...i.paths.map(link),
    "",
    "**The comment**",
    "",
    quote,
    "",
    "**The problem**",
    "",
    i.problem,
    "",
    "**The fix**",
    "",
    i.fix,
    "",
  ].join("\n");
}

const secret = issues.filter((i) => i.security);
writeFileSync(
  join(run, "issues-private.md"),
  secret.map((i) => `## ${i.title}\n\nKey: \`${i.key}\`\n\n${bodyOf(i)}`).join("\n"),
);

if (!dryRun) {
  const labels = gh(["label", "list", "--limit", "200", "--json", "name", "--jq", ".[].name"]).split("\n");
  if (!labels.includes(LABEL)) {
    gh(["label", "create", LABEL, "--color", "D4C5F9", "--description", "A shortcut that a deleted code comment marked"]);
  }
}

let created = 0;
for (const i of issues) {
  if (i.security || filed.has(i.key)) continue;
  const bodyFile = join(run, "issue-body.md");
  writeFileSync(bodyFile, bodyOf(i));
  if (dryRun) {
    console.log(`would file: ${i.title}`);
    continue;
  }
  const url = gh(["issue", "create", "--title", i.title, "--body-file", bodyFile, "--label", LABEL]);
  appendFileSync(filedFile, `${i.key}\t${url}\n`);
  filed.set(i.key, url);
  created++;
  console.log(`${url}\t${i.title}`);
}
console.log(`${created} issue(s) filed, ${filed.size} in total, ${secret.length} security issue(s) written to ${join(run, "issues-private.md")} and not filed`);
