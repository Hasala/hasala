import { existsSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

type Entry = Record<'n' | 'line' | 'lines', number> & Record<'path' | 'hash' | 'kind', string>;
interface Issue {
  key: string;
  title: string;
  paths: string[];
  comment: string;
  problem: string;
  fix: string;
  security: boolean;
  shards?: string[];
}

const SECTION = '## ';
const JSON_EXT = '.json';
const COVERED = 'covered:';
const BAD_LINE_WIDTH = 80;
const STRIP_FIELDS = 3;

const outArg = process.argv.at(2);
if (!outArg) {
  console.error('usage: bun .claude/skills/delete-comment/merge.ts RUNDIR [--index]');
  process.exit(2);
}
const root = resolve(import.meta.dir, '../../..');

if (process.argv.includes('--index')) {
  const dir = join(root, 'docs/decisions/code');
  const lines = [
    '# Decisions from the code',
    '',
    'These decisions were code comments. Code comments are not permitted',
    '(`scripts/comment-lint.ts`), so each decision that a comment recorded is in one',
    'of these documents. Each section names the files and symbols it applies to.',
    'Search this directory for a file name or a symbol before you change that code.',
    '',
    'The decisions of record of each area are one level up, in `docs/decisions/`.',
    '',
    '| Document | Sections |',
    '| --- | --- |',
  ];
  for (const file of readdirSync(dir).toSorted()) {
    if (!file.endsWith('.md') || file === 'README.md') {
      continue;
    }
    const text = readFileSync(join(dir, file), 'utf8').split('\n');
    const title = (text.find((row) => row.startsWith('# ')) ?? file)
      .slice(2)
      .replace(/: decisions from the code.*$/u, '');
    lines.push(`| [${title}](${file}) | ${text.filter((row) => row.startsWith(SECTION)).length} |`);
  }
  writeFileSync(join(dir, 'README.md'), `${lines.join('\n')}\n`);
  process.exit(0);
}
const run = resolve(outArg);
const CATEGORIES = new Set(['T', 'S', 'E', 'D', 'K']);
const errors: string[] = [];
const rows: string[] = [];
const issues = new Map<string, Issue>();
const counts: Record<string, { units: number; lines: number }> = {};
const add = (cat: string, lines: number): void => {
  const count = counts[cat] ?? { units: 0, lines: 0 };
  count.units += 1;
  count.lines += lines;
  counts[cat] = count;
};

const sections = new Map<string, Set<string>>();
function sectionsOf(file: string): Set<string> {
  const known = sections.get(file);
  if (known) {
    return known;
  }
  const set = new Set<string>();
  if (existsSync(file)) {
    for (const line of readFileSync(file, 'utf8').split('\n')) {
      if (line.startsWith(SECTION)) {
        set.add(line.slice(SECTION.length).trim());
      }
    }
  }
  sections.set(file, set);
  return set;
}

for (const line of readFileSync(join(run, 'pre.tsv'), 'utf8').split('\n')) {
  if (line === '') {
    continue;
  }
  const [path, lineNo, hash, cat, ref] = line.split('\t');
  rows.push([path, lineNo, hash, cat, ref, 'rule'].join('\t'));
  add(cat, 0);
}

const slugs = readdirSync(join(run, 'shards'))
  .filter((name) => name.endsWith(JSON_EXT))
  .map((name) => name.slice(0, -JSON_EXT.length))
  .toSorted();
for (const slug of slugs) {
  const map: Entry[] = JSON.parse(readFileSync(join(run, 'shards', `${slug}.json`), 'utf8'));
  const verdictFile = join(run, 'verdicts', `${slug}.tsv`);
  if (!existsSync(verdictFile)) {
    errors.push(`${slug}: no verdict file`);
    continue;
  }
  const keys = new Set<string>();
  const issueFile = join(run, 'issues', `${slug}.json`);
  if (existsSync(issueFile)) {
    for (const issue of JSON.parse(readFileSync(issueFile, 'utf8')) as Issue[]) {
      keys.add(issue.key);
      const have = issues.get(issue.key);
      if (have) {
        have.paths = [...new Set([...have.paths, ...issue.paths])];
        have.security ||= issue.security;
        have.shards?.push(slug);
      } else {
        issues.set(issue.key, { ...issue, shards: [slug] });
      }
    }
  }
  const verdicts = new Map<number, [string, string]>();
  for (const line of readFileSync(verdictFile, 'utf8').split('\n')) {
    if (line.trim() === '') {
      continue;
    }
    const [id, cat, ...rest] = line.split('\t');
    const num = Number(id);
    if (!Number.isInteger(num) || !CATEGORIES.has(cat)) {
      errors.push(`${slug}: bad line: ${line.slice(0, BAD_LINE_WIDTH)}`);
    } else if (verdicts.has(num)) {
      errors.push(`${slug}: comment ${num} has two verdicts`);
    } else {
      verdicts.set(num, [cat, rest.join(' ').trim()]);
    }
  }
  for (const entry of map) {
    const verdict = verdicts.get(entry.n);
    if (!verdict) {
      errors.push(`${slug}: comment ${entry.n} has no verdict`);
      continue;
    }
    const [cat, ref] = verdict;
    if (cat === 'E' && !keys.has(ref) && !issues.has(ref)) {
      errors.push(`${slug}: comment ${entry.n}: no issue with key ${ref}`);
    }
    if (cat === 'K' && ref === '') {
      errors.push(`${slug}: comment ${entry.n}: K with no reason`);
    }
    if (cat === 'D' && ref.startsWith(COVERED)) {
      const [anchorless = ''] = ref.slice(COVERED.length).split('#');
      const [target = ''] = anchorless.split(' ');
      if (!existsSync(join(root, target))) {
        errors.push(`${slug}: comment ${entry.n}: ${target} does not exist`);
      }
    } else if (
      cat === 'D' &&
      !sectionsOf(join(root, 'docs/decisions/code', `${slug}.md`)).has(ref)
    ) {
      errors.push(`${slug}: comment ${entry.n}: no ADR section "${ref}"`);
    }
    rows.push([entry.path, entry.line, entry.hash, cat, ref, slug].join('\t'));
    add(cat, entry.lines);
  }
  for (const num of verdicts.keys()) {
    if (!map.some((entry) => entry.n === num)) {
      errors.push(`${slug}: verdict for comment ${num}, which is not in the shard`);
    }
  }
}

writeFileSync(join(run, 'verdicts.tsv'), rows.map((row) => `${row}\n`).join(''));
writeFileSync(
  join(run, 'strip.tsv'),
  rows
    .filter((row) => row.split('\t')[3] !== 'K')
    .map((row) => `${row.split('\t').slice(0, STRIP_FIELDS).join('\t')}\n`)
    .join(''),
);
writeFileSync(join(run, 'issues.json'), JSON.stringify([...issues.values()], null, 2));

for (const [cat, count] of Object.entries(counts).toSorted()) {
  console.log(`${cat}\t${count.units}\t${count.lines}`);
}
console.log(
  `issues\t${issues.size}\t(${[...issues.values()].filter((issue) => issue.security).length} security)`,
);
if (errors.length > 0) {
  console.error(errors.join('\n'));
  console.error(`merge: ${errors.length} problem(s)`);
  process.exit(1);
}
