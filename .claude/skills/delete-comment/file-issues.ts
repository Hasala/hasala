import { execFileSync } from 'node:child_process';
import { appendFileSync, existsSync, readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

interface Issue {
  key: string;
  title: string;
  paths: string[];
  comment: string;
  problem: string;
  fix: string;
  security: boolean;
}

const LABEL = 'comment-debt';
const SHORT_SHA = 7;
const args = process.argv.slice(2);
const dryRun = args.includes('--dry-run');
const [runArg, sha] = args.filter((arg) => arg !== '--dry-run');
if (!runArg || !sha) {
  console.error(
    'usage: bun .claude/skills/delete-comment/file-issues.ts [--dry-run] RUNDIR BASE_SHA',
  );
  process.exit(2);
}
const run = resolve(runArg);
const gh = (ghArgs: string[]): string =>
  execFileSync('gh', ghArgs, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit'] }).trim();
const repo = gh(['repo', 'view', '--json', 'nameWithOwner', '--jq', '.nameWithOwner']);

const issues: Issue[] = JSON.parse(readFileSync(join(run, 'issues.json'), 'utf8'));
const filedFile = join(run, 'issues-filed.tsv');
const filed = new Map<string, string>();
if (existsSync(filedFile)) {
  for (const line of readFileSync(filedFile, 'utf8').split('\n')) {
    if (line === '') {
      continue;
    }
    const [key, url] = line.split('\t');
    filed.set(key, url);
  }
}

function link(path: string): string {
  const match = /^(.*?):(\d+)$/u.exec(path);
  if (!match) {
    return `- [\`${path}\`](https://github.com/${repo}/blob/${sha}/${path})`;
  }
  return `- [\`${path}\`](https://github.com/${repo}/blob/${sha}/${match[1]}#L${match[2]})`;
}

function bodyOf(issue: Issue): string {
  const quote = issue.comment
    .split('\n')
    .map((line) => `> ${line}`)
    .join('\n');
  return [
    'A code comment marked this shortcut. Code comments are not permitted (`scripts/comment-lint.ts`), so the comment is deleted and this issue keeps the record.',
    '',
    `**Where** (at \`${sha.slice(0, SHORT_SHA)}\`, before the comment was deleted)`,
    '',
    ...issue.paths.map((path) => link(path)),
    '',
    '**The comment**',
    '',
    quote,
    '',
    '**The problem**',
    '',
    issue.problem,
    '',
    '**The fix**',
    '',
    issue.fix,
    '',
  ].join('\n');
}

const secret = issues.filter((issue) => issue.security);
writeFileSync(
  join(run, 'issues-private.md'),
  secret
    .map((issue) => `## ${issue.title}\n\nKey: \`${issue.key}\`\n\n${bodyOf(issue)}`)
    .join('\n'),
);

if (!dryRun) {
  const labels = gh([
    'label',
    'list',
    '--limit',
    '200',
    '--json',
    'name',
    '--jq',
    '.[].name',
  ]).split('\n');
  if (!labels.includes(LABEL)) {
    gh([
      'label',
      'create',
      LABEL,
      '--color',
      'D4C5F9',
      '--description',
      'A shortcut that a deleted code comment marked',
    ]);
  }
}

let created = 0;
for (const issue of issues) {
  if (issue.security || filed.has(issue.key)) {
    continue;
  }
  const bodyFile = join(run, 'issue-body.md');
  writeFileSync(bodyFile, bodyOf(issue));
  if (dryRun) {
    console.log(`would file: ${issue.title}`);
    continue;
  }
  const url = gh([
    'issue',
    'create',
    '--title',
    issue.title,
    '--body-file',
    bodyFile,
    '--label',
    LABEL,
  ]);
  appendFileSync(filedFile, `${issue.key}\t${url}\n`);
  filed.set(issue.key, url);
  created += 1;
  console.log(`${url}\t${issue.title}`);
}
console.log(
  `${created} issue(s) filed, ${filed.size} in total, ${secret.length} security issue(s) written to ${join(run, 'issues-private.md')} and not filed`,
);
