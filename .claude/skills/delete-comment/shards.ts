import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

type Unit = { path: string; line: number; endLine: number; kind: string; hash: string; text: string };

const MAX_UNITS = 400;
const MAX_LINES = 1000;
const FROZEN = [/^server\/internal\/pg\/migrations\//];
const DEEP = [/^ios\/HasalaCore\/Sources\/HasalaCore\//, /^ios\/HasalaCore\/Tests\//, /^ios\/Hasala\/Features\//, /^ios\/HasalaKit\/Sources\//];
const NOISE = new Set(["internal", "sources", "src", "hasalacore"]);

const [outArg, ...only] = process.argv.slice(2);
if (!outArg) {
  console.error("usage: bun .claude/skills/delete-comment/shards.ts OUTDIR [PATH...]");
  process.exit(2);
}
const root = resolve(import.meta.dir, "../../..");
const out = resolve(outArg);
mkdirSync(join(out, "shards"), { recursive: true });
mkdirSync(join(out, "verdicts"), { recursive: true });
mkdirSync(join(out, "issues"), { recursive: true });

const units: Unit[] = JSON.parse(
  execFileSync("bun", [join(root, "scripts/comment-lint.ts"), "list", "--json", ...only], { encoding: "utf8", maxBuffer: 1 << 28 }),
);

const byFile = new Map<string, Unit[]>();
for (const u of units) {
  if (!byFile.has(u.path)) byFile.set(u.path, []);
  byFile.get(u.path)!.push(u);
}

const pre: string[] = [];
const work: [string, Unit[]][] = [];
for (const [path, list] of [...byFile].sort((a, b) => (a[0] < b[0] ? -1 : 1))) {
  const generated = list[0].line <= 2 && /do not edit/i.test(list[0].text);
  const frozen = FROZEN.some((re) => re.test(path));
  const rest: Unit[] = [];
  for (const u of list) {
    if (generated || frozen) pre.push(`${u.path}\t${u.line}\t${u.hash}\tK\t${generated ? "generated file" : "frozen file"}`);
    else if (/^\/\/ ?MARK:[^\n]*$/.test(u.text)) pre.push(`${u.path}\t${u.line}\t${u.hash}\tT\tsection label`);
    else rest.push(u);
  }
  if (rest.length > 0) work.push([path, rest]);
}
writeFileSync(join(out, "pre.tsv"), pre.map((l) => l + "\n").join(""));

function areaOf(path: string): string {
  const parts = path.split("/");
  const depth = DEEP.some((re) => re.test(path)) ? 5 : 3;
  return parts.slice(0, Math.min(depth, parts.length - 1)).join("/");
}

const linesOf = (list: Unit[]) => list.reduce((n, u) => n + u.endLine - u.line + 1, 0);

type Shard = { files: [string, Unit[]][]; units: number; lines: number };
const shards: Shard[] = [];
let current: Shard = { files: [], units: 0, lines: 0 };
const close = () => {
  if (current.files.length > 0) shards.push(current);
  current = { files: [], units: 0, lines: 0 };
};

const areas = new Map<string, [string, Unit[]][]>();
for (const entry of work) {
  const area = areaOf(entry[0]);
  if (!areas.has(area)) areas.set(area, []);
  areas.get(area)!.push(entry);
}
for (const [, files] of areas) {
  const units = files.reduce((n, f) => n + f[1].length, 0);
  const lines = files.reduce((n, f) => n + linesOf(f[1]), 0);
  const fits = current.units + units <= MAX_UNITS && current.lines + lines <= MAX_LINES;
  if (!fits && (current.units > MAX_UNITS / 2 || current.lines > MAX_LINES / 2 || units > MAX_UNITS || lines > MAX_LINES)) close();
  for (const f of files) {
    const n = f[1].length;
    const l = linesOf(f[1]);
    if (current.files.length > 0 && (current.units + n > MAX_UNITS || current.lines + l > MAX_LINES)) close();
    current.files.push(f);
    current.units += n;
    current.lines += l;
  }
}
close();

function slugOf(shard: Shard): string {
  const split = shard.files.map((f) => f[0].split("/").slice(0, -1));
  let prefix = split[0];
  for (const parts of split) {
    let i = 0;
    while (i < prefix.length && i < parts.length && prefix[i] === parts[i]) i++;
    prefix = prefix.slice(0, i);
  }
  const clean = (p: string) => p.toLowerCase().replace(/[^a-z0-9]+/g, "");
  const words = prefix.map(clean).filter((p) => p !== "" && !NOISE.has(p));
  const leaf = (parts: string[]) => clean(parts[prefix.length] ?? "");
  const first = leaf(split[0]);
  const last = leaf(split[split.length - 1]);
  if (first !== "" && !NOISE.has(first)) words.push(first);
  if (last !== "" && last !== first && !NOISE.has(last)) words.push("to", last);
  return words.length > 0 ? words.join("-") : "root";
}

const seen = new Map<string, number>();
const index: string[] = [];
for (const shard of shards) {
  const base = slugOf(shard);
  const n = (seen.get(base) ?? 0) + 1;
  seen.set(base, n);
  const slug = n === 1 ? base : `${base}-${n}`;
  const text: string[] = [];
  const map: { n: number; path: string; line: number; hash: string; lines: number; kind: string }[] = [];
  let k = 0;
  for (const [path, list] of shard.files) {
    const src = readFileSync(join(root, path), "utf8").split("\n");
    text.push(`\n######## FILE ${path}\n`);
    for (const u of list) {
      k++;
      map.push({ n: k, path, line: u.line, hash: u.hash, lines: u.endLine - u.line + 1, kind: u.kind });
      text.push(`#### ${k}  lines ${u.line}-${u.endLine}  ${u.kind}`);
      if (u.kind === "full") {
        text.push(u.text);
        const after: string[] = [];
        for (let i = u.endLine; i < src.length && after.length < 4; i++) {
          if (src[i].trim() !== "") after.push(src[i].length > 160 ? src[i].slice(0, 160) + "…" : src[i]);
        }
        text.push("-- code after:", ...after, "");
      } else {
        text.push("-- on this line:", ...src.slice(u.line - 1, u.endLine).map((l) => (l.length > 400 ? l.slice(0, 400) + "…" : l)), "");
      }
    }
  }
  writeFileSync(join(out, "shards", `${slug}.txt`), text.join("\n") + "\n");
  writeFileSync(join(out, "shards", `${slug}.json`), JSON.stringify(map));
  index.push(`${slug}\t${shard.units}\t${shard.lines}\t${shard.files.length}`);
}
writeFileSync(join(out, "index.tsv"), index.map((l) => l + "\n").join(""));
console.log(`${shards.length} shard(s), ${work.reduce((n, f) => n + f[1].length, 0)} comment(s) to classify, ${pre.length} classified by rule`);
console.log(index.join("\n"));
