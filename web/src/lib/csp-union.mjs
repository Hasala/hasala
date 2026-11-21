// @ts-check
import { readdir, readFile, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const META = /<meta http-equiv="content-security-policy" content="([^"]*)"\s*\/?>/i;
const INLINE_SCRIPT = /<script(?![^>]*\ssrc=)([^>]*)>([\s\S]*?)<\/script>/gi;
const INLINE_STYLE = /<style[^>]*>([\s\S]*?)<\/style>/gi;
const RUNS = /^(|text\/javascript|module|application\/javascript)$/i;

/** @param {string} text */
const sha256 = (text) => `'sha256-${createHash('sha256').update(text, 'utf8').digest('base64')}'`;

/** @param {string} dir @returns {Promise<string[]>} */
async function htmlFiles(dir) {
  const out = [];
  for (const e of await readdir(dir, { withFileTypes: true })) {
    const p = join(dir, e.name);
    if (e.isDirectory()) out.push(...(await htmlFiles(p)));
    else if (e.name.endsWith('.html')) out.push(p);
  }
  return out;
}

/** "a b; c d" → [["a", ["b"]], ["c", ["d"]]], in order. @param {string} csp */
const parse = (csp) =>
  csp
    .split(';')
    .map((d) => d.trim().split(/\s+/))
    .filter((d) => d[0])
    .map(([name, ...values]) => /** @type {[string, string[]]} */ ([name, values]));

/**
 * @typedef {{ token: string, drop: string[] }} WithoutAnalytics
 * @param {{ withoutAnalytics?: WithoutAnalytics }} [options]
 * @returns {import('astro').AstroIntegration}
 */
export default function cspUnion(options = {}) {
  return {
    name: 'hasala:csp-union',
    hooks: {
      'astro:build:done': async ({ dir, logger }) => {
        const root = fileURLToPath(dir);
        const pages = [];
        for (const file of await htmlFiles(root)) {
          const html = await readFile(file, 'utf8');
          const m = META.exec(html);
          if (m) pages.push({ file, html, directives: parse(m[1].replaceAll('&#39;', "'")) });
        }
        if (!pages.length) return;

        /** @type {Record<string, Set<string>>} */
        const merged = { 'script-src': new Set(), 'style-src': new Set() };
        const others = (/** @type {[string, string[]][]} */ d) =>
          JSON.stringify(d.filter(([n]) => !(n in merged)));
        const template = pages[0].directives;
        for (const page of pages) {
          if (others(page.directives) !== others(template)) {
            throw new Error(`CSP of ${page.file} differs from ${pages[0].file} outside script-src/style-src; one policy cannot serve both.`);
          }
          for (const [name, values] of page.directives) if (name in merged) values.forEach((v) => merged[name].add(v));
          for (const [, attrs, body] of page.html.matchAll(INLINE_SCRIPT)) {
            const type = /\stype="([^"]*)"/i.exec(attrs)?.[1] ?? '';
            if (RUNS.test(type)) merged['script-src'].add(sha256(body));
          }
          for (const [, body] of page.html.matchAll(INLINE_STYLE)) merged['style-src'].add(sha256(body));
        }

        const values = (/** @type {Set<string>} */ set) => [...[...set].filter((v) => !v.startsWith("'sha")), ...[...set].filter((v) => v.startsWith("'sha")).sort()];
        const policy = template.map(([name, v]) => [name, ...(name in merged ? values(merged[name]) : v)].join(' ')).join('; ');
        const meta = `<meta http-equiv="content-security-policy" content="${policy}" data-astro-transition-persist="csp">`;
        await Promise.all(pages.map((p) => writeFile(p.file, p.html.replace(META, () => meta))));
        logger.info(
          `one CSP for ${pages.length} pages: ${merged['script-src'].size} script-src and ${merged['style-src'].size} style-src entries`,
        );

        const wa = options.withoutAnalytics;
        if (wa) {
          const file = join(root, '_headers');
          const headers = await readFile(file, 'utf8');
          if (!headers.includes(wa.token)) throw new Error(`${file} has no ${wa.token}; the pages that carry codes would load Web Analytics.`);
          const kept = (/** @type {string} */ v) => !wa.drop.some((d) => v === d || v.startsWith(`${d}/`));
          const directives = template
            .filter(([name]) => name === 'script-src' || name === 'connect-src')
            .map(([name, v]) => {
              const left = (name in merged ? values(merged[name]) : v).filter(kept);
              return [name, ...(left.length ? left : ["'none'"])].join(' ');
            })
            .join('; ');
          await writeFile(file, headers.replaceAll(wa.token, () => directives));
          logger.info(`_headers: ${wa.token} is now script-src and connect-src without ${wa.drop.join(', ')}`);
        }
      },
    },
  };
}
