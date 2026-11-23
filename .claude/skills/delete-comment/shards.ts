import { execFileSync } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

interface Unit {
  path: string;
  line: number;
  endLine: number;
  kind: string;
  hash: string;
  text: string;
}

const MAX_UNITS = 400;
const MAX_LINES = 1000;
const MAX_BUFFER = 268_435_456;
const DEEP_DEPTH = 5;
const AREA_DEPTH = 3;
const AFTER_LINES = 4;
const AFTER_WIDTH = 160;
const LINE_WIDTH = 400;
const FROZEN = [/^server\/internal\/pg\/migrations\//u];
const DEEP = [
  /^ios\/HasalaCore\/Sources\/HasalaCore\//u,
  /^ios\/HasalaCore\/Tests\//u,
  /^ios\/Hasala\/Features\//u,
  /^ios\/HasalaKit\/Sources\//u,
];
const NOISE = new Set(['internal', 'sources', 'src', 'hasalacore']);

const [outArg, ...only] = process.argv.slice(2);
if (!outArg) {
  console.error('usage: bun .claude/skills/delete-comment/shards.ts OUTDIR [PATH...]');
  process.exit(2);
}
const root = resolve(import.meta.dir, '../../..');
const out = resolve(outArg);
mkdirSync(join(out, 'shards'), { recursive: true });
mkdirSync(join(out, 'verdicts'), { recursive: true });
mkdirSync(join(out, 'issues'), { recursive: true });

const units: Unit[] = JSON.parse(
  execFileSync('bun', [join(root, 'scripts/comment-lint.ts'), 'list', '--json', ...only], {
    encoding: 'utf8',
    maxBuffer: MAX_BUFFER,
  }),
);

const byFile = new Map<string, Unit[]>();
for (const unit of units) {
  const fileUnits = byFile.get(unit.path);
  if (fileUnits) {
    fileUnits.push(unit);
  } else {
    byFile.set(unit.path, [unit]);
  }
}

const pre: string[] = [];
const work: [string, Unit[]][] = [];
for (const [path, list] of [...byFile].toSorted((left, right) => (left[0] < right[0] ? -1 : 1))) {
  const [first] = list;
  const generated = first !== undefined && first.line <= 2 && /do not edit/iu.test(first.text);
  const frozen = FROZEN.some((re) => re.test(path));
  const rest: Unit[] = [];
  for (const unit of list) {
    if (generated || frozen) {
      pre.push(
        `${unit.path}\t${unit.line}\t${unit.hash}\tK\t${generated ? 'generated file' : 'frozen file'}`,
      );
    } else if (/^\/\/ ?MARK:[^\n]*$/u.test(unit.text)) {
      pre.push(`${unit.path}\t${unit.line}\t${unit.hash}\tT\tsection label`);
    } else {
      rest.push(unit);
    }
  }
  if (rest.length > 0) {
    work.push([path, rest]);
  }
}
writeFileSync(join(out, 'pre.tsv'), pre.map((row) => `${row}\n`).join(''));

function areaOf(path: string): string {
  const parts = path.split('/');
  const depth = DEEP.some((re) => re.test(path)) ? DEEP_DEPTH : AREA_DEPTH;
  return parts.slice(0, Math.min(depth, parts.length - 1)).join('/');
}

const linesOf = (list: Unit[]): number =>
  list.reduce((sum, unit) => sum + unit.endLine - unit.line + 1, 0);

type Entry = Record<'n' | 'line' | 'lines', number> & Record<'path' | 'hash' | 'kind', string>;

interface Shard {
  files: [string, Unit[]][];
  units: number;
  lines: number;
}
const shards: Shard[] = [];
let current: Shard = { files: [], units: 0, lines: 0 };
const close = (): void => {
  if (current.files.length > 0) {
    shards.push(current);
  }
  current = { files: [], units: 0, lines: 0 };
};

const areas = new Map<string, [string, Unit[]][]>();
for (const entry of work) {
  const area = areaOf(entry[0]);
  const areaFiles = areas.get(area);
  if (areaFiles) {
    areaFiles.push(entry);
  } else {
    areas.set(area, [entry]);
  }
}
for (const [, files] of areas) {
  const areaUnits = files.reduce((sum, file) => sum + file[1].length, 0);
  const areaLines = files.reduce((sum, file) => sum + linesOf(file[1]), 0);
  const fits = current.units + areaUnits <= MAX_UNITS && current.lines + areaLines <= MAX_LINES;
  if (
    !fits &&
    (current.units > MAX_UNITS / 2 ||
      current.lines > MAX_LINES / 2 ||
      areaUnits > MAX_UNITS ||
      areaLines > MAX_LINES)
  ) {
    close();
  }
  for (const file of files) {
    const fileUnits = file[1].length;
    const fileLines = linesOf(file[1]);
    if (
      current.files.length > 0 &&
      (current.units + fileUnits > MAX_UNITS || current.lines + fileLines > MAX_LINES)
    ) {
      close();
    }
    current.files.push(file);
    current.units += fileUnits;
    current.lines += fileLines;
  }
}
close();

function clean(part: string): string {
  return part.toLowerCase().replaceAll(/[^a-z0-9]+/gu, '');
}

function slugOf(shard: Shard): string {
  const split = shard.files.map((file) => file[0].split('/').slice(0, -1));
  let [prefix = []] = split;
  for (const parts of split) {
    let common = 0;
    while (common < prefix.length && common < parts.length && prefix[common] === parts[common]) {
      common += 1;
    }
    prefix = prefix.slice(0, common);
  }
  const words = prefix.map((part) => clean(part)).filter((word) => word !== '' && !NOISE.has(word));
  const leaf = (parts: string[] = []): string => clean(parts[prefix.length] ?? '');
  const first = leaf(split[0]);
  const last = leaf(split.at(-1));
  if (first !== '' && !NOISE.has(first)) {
    words.push(first);
  }
  if (last !== '' && last !== first && !NOISE.has(last)) {
    words.push('to', last);
  }
  return words.length > 0 ? words.join('-') : 'root';
}

function codeAfter(src: string[], endLine: number): string[] {
  const after: string[] = [];
  for (let at = endLine; at < src.length && after.length < AFTER_LINES; at += 1) {
    const line = src[at] ?? '';
    if (line.trim() !== '') {
      after.push(line.length > AFTER_WIDTH ? `${line.slice(0, AFTER_WIDTH)}…` : line);
    }
  }
  return after;
}

const seen = new Map<string, number>();
const index: string[] = [];
for (const shard of shards) {
  const base = slugOf(shard);
  const count = (seen.get(base) ?? 0) + 1;
  seen.set(base, count);
  const slug = count === 1 ? base : `${base}-${count}`;
  const text: string[] = [];
  const map: Entry[] = [];
  let number = 0;
  for (const [path, list] of shard.files) {
    const src = readFileSync(join(root, path), 'utf8').split('\n');
    text.push(`\n######## FILE ${path}\n`);
    for (const unit of list) {
      number += 1;
      map.push({
        n: number,
        path,
        line: unit.line,
        hash: unit.hash,
        lines: unit.endLine - unit.line + 1,
        kind: unit.kind,
      });
      text.push(`#### ${number}  lines ${unit.line}-${unit.endLine}  ${unit.kind}`);
      if (unit.kind === 'full') {
        text.push(unit.text, '-- code after:', ...codeAfter(src, unit.endLine), '');
      } else {
        text.push(
          '-- on this line:',
          ...src
            .slice(unit.line - 1, unit.endLine)
            .map((line) => (line.length > LINE_WIDTH ? `${line.slice(0, LINE_WIDTH)}…` : line)),
          '',
        );
      }
    }
  }
  writeFileSync(join(out, 'shards', `${slug}.txt`), `${text.join('\n')}\n`);
  writeFileSync(join(out, 'shards', `${slug}.json`), JSON.stringify(map));
  index.push(`${slug}\t${shard.units}\t${shard.lines}\t${shard.files.length}`);
}
writeFileSync(join(out, 'index.tsv'), index.map((row) => `${row}\n`).join(''));
console.log(
  `${shards.length} shard(s), ${work.reduce((sum, file) => sum + file[1].length, 0)} comment(s) to classify, ${pre.length} classified by rule`,
);
console.log(index.join('\n'));
