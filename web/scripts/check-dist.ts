/**
 * Checks the built site in dist/ (run after `astro build`; `bun run build`
 * runs it). Exits non-zero on any problem.
 *
 * CSP. <ClientRouter /> keeps the first page's policy for the whole visit, so
 * src/lib/csp-union.mjs writes one policy into every page. This verifies it
 * independently:
 *   - every page has exactly one CSP <meta>, marked transition:persist;
 *   - every page carries the same policy;
 *   - every inline <script> the browser runs (not JSON-LD) and every inline
 *     <style>, on any page, is allowed by that policy's hash list;
 *   - no element has a style="" attribute (blocked without 'unsafe-inline');
 *   - every <script src> is same-origin, or Cloudflare Turnstile.
 *
 * No Web Analytics where the address carries a code or a token. Those are
 * the pages that send no referrer (<meta name="referrer" content="no-referrer">)
 * and every address _redirects serves from one (/i/* is i.html). Each must
 * get exactly one Content-Security-Policy header from _headers, with
 * frame-ancestors 'none', whose script-src and connect-src are the <meta>'s
 * minus Cloudflare Web Analytics, and which names cloudflareinsights.com
 * nowhere. Cloudflare's edge injects the Web Analytics beacon into every
 * HTML page, and Web Analytics records paths.
 *
 * JS budget. The JavaScript a page loads up front: its module scripts, their
 * static imports (recursively; dynamic import() is not followed) and its
 * executable inline scripts, gzipped (level 9) file by file. / must stay at
 * or under JS_BUDGET; every page's figure is printed.
 *
 *   bun scripts/check-dist.ts [dist]      (V=1 lists each page's files)
 */
import { readFileSync, readdirSync } from 'node:fs';
import { join, relative } from 'node:path';
import { createHash } from 'node:crypto';
import { gzipSync } from 'node:zlib';
import { fileURLToPath } from 'node:url';

const JS_BUDGET = 15 * 1024;
const BUDGET_PAGES = new Set(['index.html']);
const SCRIPT_ORIGINS = ['https://challenges.cloudflare.com'];

const dist = process.argv[2] ?? fileURLToPath(new URL('../dist', import.meta.url));

const META = /<meta http-equiv="content-security-policy"[^>]*>/giu;
const INLINE_SCRIPT = /<script(?![^>]*\ssrc=)([^>]*)>([\s\S]*?)<\/script>/giu;
const INLINE_STYLE = /<style[^>]*>([\s\S]*?)<\/style>/giu;
const STYLE_ATTR = /<[a-z][^>]*\sstyle=["']/giu;
const SCRIPT_SRC = /<script[^>]*\ssrc="([^"]*)"/giu;
const MODULE_SRC = /<script type="module" src="([^"]+)"/gu;
const STATIC_IMPORT = /(?:from|import)\s*["'](\.\/[^"']+|\/_astro\/[^"']+)["']/gu;
/** Script types the browser runs, so CSP checks them; data blocks (JSON-LD) are not. */
const RUNS = /^(|text\/javascript|module|application\/javascript)$/iu;

const ANALYTICS = /cloudflareinsights\.com/iu;
const NO_REFERRER = /<meta name="referrer" content="no-referrer"\s*\/?>/iu;

/** "a b; c d" → Map { a → {b}, c → {d} }. */
const directivesOf = (csp: string): Map<string, Set<string>> =>
  new Map(
    csp
      .split(';')
      .map((directive) => directive.trim().split(/\s+/u))
      .filter((directive) => directive[0])
      .map(([name, ...values]) => [name, new Set(values)] as const),
  );
const sha256 = (text: string): string => `'sha256-${createHash('sha256').update(text, 'utf8').digest('base64')}'`;
const gz = (bytes: Uint8Array): number => gzipSync(bytes, { level: 9 }).length;
const kb = (count: number): string => (count / 1024).toFixed(2);
const preview = (text: string): string => JSON.stringify(text.slice(0, 60));

function htmlFiles(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) {return htmlFiles(path);}
    return entry.name.endsWith('.html') ? [path] : [];
  });
}

const problems: string[] = [];
const files = htmlFiles(dist).toSorted();
if (files.length === 0) {problems.push(`no HTML in ${dist}: build first`);}

const policies = new Map<string, string>();
const inline: { page: string; kind: 'script' | 'style'; hash: string; body: string }[] = [];
const pages = new Map<string, string>();

for (const file of files) {
  const page = relative(dist, file);
  const html = readFileSync(file, 'utf8');
  pages.set(page, html);

  const metas = html.match(META) ?? [];
  if (metas.length !== 1) {
    problems.push(`${page}: expected 1 CSP <meta>, found ${metas.length}`);
    continue;
  }
  if (!metas[0].includes('data-astro-transition-persist="csp"')) {problems.push(`${page}: CSP <meta> is not transition:persist`);}
  const content = /content="([^"]+)"/u.exec(metas[0])?.[1];
  if (!content) {
    problems.push(`${page}: CSP <meta> has no content`);
    continue;
  }
  policies.set(page, content.replaceAll('&#39;', "'"));

  for (const [, attrs, body] of html.matchAll(INLINE_SCRIPT)) {
    if (RUNS.test(/\stype="([^"]*)"/iu.exec(attrs)?.[1] ?? '')) {inline.push({ page, kind: 'script', hash: sha256(body), body });}
  }
  for (const [, body] of html.matchAll(INLINE_STYLE)) {inline.push({ page, kind: 'style', hash: sha256(body), body });}
  for (const [tag] of html.matchAll(STYLE_ATTR)) {problems.push(`${page}: style="" attribute (blocked without 'unsafe-inline'): ${tag.slice(0, 80)}`);}
  for (const [, src] of html.matchAll(SCRIPT_SRC)) {
    const self = src.startsWith('/') && !src.startsWith('//');
    if (!self && !SCRIPT_ORIGINS.some((origin) => src.startsWith(`${origin}/`))) {problems.push(`${page}: <script src> from another origin: ${src}`);}
  }
}

if (new Set(policies.values()).size > 1) {problems.push(`pages carry ${new Set(policies.values()).size} different CSPs; they must share one`);}
for (const [page, csp] of policies) {
  const directives = directivesOf(csp);
  for (const x of inline) {
    if (!directives.get(`${x.kind}-src`)?.has(x.hash)) {problems.push(`${x.page}: inline ${x.kind} not allowed by the CSP of ${page}: ${preview(x.body)}`);}
  }
}
console.log(`CSP: ${policies.size} pages, ${inline.length} inline scripts/styles checked against every page's policy`);

// No Web Analytics on the pages whose address carries a code or a token.
const glob = (pattern: string): RegExp => new RegExp(`^${pattern.replaceAll(/[.+?^${}()|[\]\\]/gu, String.raw`\$&`).replaceAll('*', '.*')}$`, 'u');
const textOf = (name: string): string => {
  try {
    return readFileSync(join(dist, name), 'utf8');
  } catch {
    problems.push(`no ${name} in ${dist}`);
    return '';
  }
};
/** _headers as Workers Static Assets reads it: rules in order, "! Name" detaches, repeated names are joined. */
const rules: { match: RegExp; detach: string[]; set: [string, string][] }[] = [];
for (const line of textOf('_headers').split('\n')) {
  if (!line.trim() || line.trim().startsWith('#')) {continue;}
  if (!/^\s/u.test(line)) {
    rules.push({ match: glob(line.trim()), detach: [], set: [] });
    continue;
  }
  const trimmed = line.trim();
  if (trimmed.startsWith('!')) {rules.at(-1)?.detach.push(trimmed.slice(1).trim().toLowerCase());}
  else {rules.at(-1)?.set.push([trimmed.slice(0, trimmed.indexOf(':')).trim().toLowerCase(), trimmed.slice(trimmed.indexOf(':') + 1).trim()]);}
}
const headersFor = (path: string): Map<string, string[]> => {
  const out = new Map<string, string[]>();
  for (const rule of rules.filter((candidate) => candidate.match.test(path))) {
    for (const name of rule.detach) {out.delete(name);}
    for (const [name, value] of rule.set) {out.set(name, [...(out.get(name) ?? []), value]);}
  }
  return out;
};
const privatePaths = [...pages].filter(([, html]) => NO_REFERRER.test(html)).map(([page]) => `/${page.replace(/\.html$/u, '')}`);
for (const [from, to] of textOf('_redirects')
  .split('\n')
  .filter((line) => line.trim() && !line.trim().startsWith('#'))
  .map((line) => line.trim().split(/\s+/u))
  .filter((parts) => parts[2] === '200')) {
  if (privatePaths.includes(to)) {privatePaths.push(from.replaceAll('*', 'test'));}
}
// The pages known to carry one, so the check cannot pass by finding none.
for (const path of ['/i', '/i/test', '/freeze', '/waitlist/confirm', '/waitlist/leave']) {
  if (!privatePaths.includes(path)) {problems.push(`${path}: carries a code or a token but has no <meta name="referrer" content="no-referrer">`);}
}
const shared = directivesOf([...policies.values()][0] ?? '');
for (const path of privatePaths) {
  const csps = headersFor(path).get('content-security-policy') ?? [];
  if (csps.length !== 1) {
    problems.push(`${path}: _headers gives it ${csps.length} Content-Security-Policy headers, not 1`);
    continue;
  }
  const csp = directivesOf(csps[0]);
  if (ANALYTICS.test(csps[0]) || csps[0].includes('%')) {problems.push(`${path}: its CSP header admits Web Analytics or was not filled in: ${csps[0].slice(0, 160)}`);}
  if (!csp.get('frame-ancestors')?.has("'none'")) {problems.push(`${path}: its CSP header lacks frame-ancestors 'none'`);}
  for (const name of ['script-src', 'connect-src']) {
    const want = [...(shared.get(name) ?? [])].filter((value) => !ANALYTICS.test(value)).toSorted();
    const got = [...(csp.get(name) ?? [])].toSorted();
    if (want.join(' ') !== got.join(' ')) {problems.push(`${path}: its CSP header's ${name} is not the <meta>'s minus Web Analytics: ${got.join(' ') || '(none)'}`);}
  }
}
console.log(`Web Analytics: kept off ${privatePaths.length} paths (${privatePaths.join(', ')})`);

if ([...pages.values()].some((html) => html.includes('data-sitekey='))) {
  const joined = pages.get('joined.html') ?? '';
  const shown = (attr: string): boolean => !/\shidden[\s=>]/u.test(new RegExp(`<[^>]*\\s${attr}(?:\\s[^>]*)?>`, 'u').exec(joined)?.[0] ?? ' hidden>');
  if (shown('data-joined-ok') || !shown('data-joined-error')) {problems.push('joined.html: a post without script has no Turnstile token and is refused, so the page must start on its error card');}
}

// JS budget.
const moduleBytes = (src: string): Uint8Array | null => {
  try {
    return readFileSync(join(dist, src.replace(/^\//u, '')));
  } catch {
    return null;
  }
};
for (const [page, html] of pages) {
  const todo = [...html.matchAll(MODULE_SRC)].map((match) => match[1]);
  const seen = new Set<string>();
  const loaded: { path: string; bytes: Uint8Array }[] = [];
  for (let src = todo.pop(); src !== undefined; src = todo.pop()) {
    if (seen.has(src)) {continue;}
    seen.add(src);
    const bytes = moduleBytes(src);
    if (!bytes) {
      problems.push(`${page}: module script ${src} is not in dist`);
      continue;
    }
    loaded.push({ path: src, bytes });
    for (const [, imp] of new TextDecoder().decode(bytes).matchAll(STATIC_IMPORT)) {
      todo.push(imp.startsWith('./') ? `/_astro/${imp.slice(2)}` : imp);
    }
  }
  const inl = new TextEncoder().encode(
    [...html.matchAll(INLINE_SCRIPT)]
      .filter(([, attrs]) => RUNS.test(/\stype="([^"]*)"/iu.exec(attrs)?.[1] ?? ''))
      .map((match) => match[2])
      .join(''),
  );
  const raw = loaded.reduce((sum, file) => sum + file.bytes.length, 0) + inl.length;
  const gzip = loaded.reduce((sum, file) => sum + gz(file.bytes), 0) + (inl.length > 0 ? gz(inl) : 0);
  const budgeted = BUDGET_PAGES.has(page);
  console.log(
    `JS ${page.padEnd(22)} raw ${kb(raw).padStart(6)} KB | gzip ${kb(gzip).padStart(5)} KB | ${loaded.length} files + ${inl.length} B inline${budgeted ? ` | budget ${kb(JS_BUDGET)} KB` : ''}`,
  );
  if (process.env.V) {for (const file of loaded.toSorted((left, right) => left.path.localeCompare(right.path))) {console.log(`    ${file.path.padEnd(60)} ${String(file.bytes.length).padStart(6)} B  gz ${String(gz(file.bytes)).padStart(5)} B`);}}
  if (budgeted && gzip > JS_BUDGET) {problems.push(`${page}: ${kb(gzip)} KB of JS (gzip) is over the ${kb(JS_BUDGET)} KB budget`);}
}

for (const problem of problems) {console.error(`✗ ${problem}`);}
console.log(problems.length > 0 ? `${problems.length} problem(s)` : 'dist checks passed');
process.exit(problems.length > 0 ? 1 : 0);
