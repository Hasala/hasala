// @ts-check
import { readFile, readdir, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const META = /<meta http-equiv="content-security-policy" content="([^"]*)"\s*\/?>/iu;
const INLINE_SCRIPT = /<script(?![^>]*\ssrc=)([^>]*)>([\s\S]*?)<\/script>/giu;
const INLINE_STYLE = /<style[^>]*>([\s\S]*?)<\/style>/giu;
const RUNS = /^(|text\/javascript|module|application\/javascript)$/iu;

/** @param {string} text */
const sha256 = (text) => `'sha256-${createHash('sha256').update(text, 'utf8').digest('base64')}'`;

/** @param {string} dir @returns {Promise<string[]>} */
async function htmlFiles(dir) {
  const entries = await readdir(dir, { withFileTypes: true });
  const found = await Promise.all(
    entries.map((entry) => {
      const path = join(dir, entry.name);
      if (entry.isDirectory()) {
        return htmlFiles(path);
      }
      return entry.name.endsWith('.html') ? [path] : [];
    }),
  );
  return found.flat();
}

/** "a b; c d" → [["a", ["b"]], ["c", ["d"]]], in order. @param {string} csp */
const parse = (csp) =>
  csp
    .split(';')
    .map((directive) => directive.trim().split(/\s+/u))
    .filter((directive) => directive[0])
    .map(([name, ...values]) => /** @type {[string, string[]]} */ ([name, values]));

/** Sources first, as Astro writes them, then the hashes in a stable order. @param {Set<string>} set */
const ordered = (set) => [
  ...[...set].filter((value) => !value.startsWith("'sha")),
  ...[...set].filter((value) => value.startsWith("'sha")).toSorted(),
];

/**
 * @typedef {{ token: string, drop: string[] }} WithoutAnalytics
 * @param {{ withoutAnalytics?: WithoutAnalytics }} [options]
 * @returns {import('astro').AstroIntegration}
 */
export function cspUnion(options = {}) {
  return {
    name: 'hasala:csp-union',
    hooks: {
      'astro:build:done': async ({ dir, logger }) => {
        const root = fileURLToPath(dir);
        const pages = [];
        const files = await htmlFiles(root);
        const read = await Promise.all(
          files.map(async (file) => ({ file, html: await readFile(file, 'utf8') })),
        );
        for (const { file, html } of read) {
          const match = META.exec(html);
          if (match) {
            pages.push({ file, html, directives: parse(match[1].replaceAll('&#39;', "'")) });
          }
        }
        if (pages.length === 0) {
          return;
        }

        /** @type {Record<string, Set<string>>} */
        const merged = { 'script-src': new Set(), 'style-src': new Set() };
        const others = (/** @type {[string, string[]][]} */ directives) =>
          JSON.stringify(directives.filter(([name]) => !(name in merged)));
        const template = pages[0].directives;
        for (const page of pages) {
          if (others(page.directives) !== others(template)) {
            throw new Error(
              `CSP of ${page.file} differs from ${pages[0].file} outside script-src/style-src; one policy cannot serve both.`,
            );
          }
          for (const [name, values] of page.directives) {
            if (name in merged) {
              for (const value of values) {
                merged[name].add(value);
              }
            }
          }
          for (const [, attrs, body] of page.html.matchAll(INLINE_SCRIPT)) {
            const type = /\stype="([^"]*)"/iu.exec(attrs)?.[1] ?? '';
            if (RUNS.test(type)) {
              merged['script-src'].add(sha256(body));
            }
          }
          for (const [, body] of page.html.matchAll(INLINE_STYLE)) {
            merged['style-src'].add(sha256(body));
          }
        }

        const policy = template
          .map(([name, listed]) =>
            [name, ...(name in merged ? ordered(merged[name]) : listed)].join(' '),
          )
          .join('; ');
        const meta = `<meta http-equiv="content-security-policy" content="${policy}" data-astro-transition-persist="csp">`;
        await Promise.all(
          pages.map((page) =>
            writeFile(
              page.file,
              page.html.replace(META, () => meta),
            ),
          ),
        );
        logger.info(
          `one CSP for ${pages.length} pages: ${merged['script-src'].size} script-src and ${merged['style-src'].size} style-src entries`,
        );

        const wa = options.withoutAnalytics;
        if (wa) {
          const file = join(root, '_headers');
          const headers = await readFile(file, 'utf8');
          if (!headers.includes(wa.token)) {
            throw new Error(
              `${file} has no ${wa.token}; the pages that carry codes would load Web Analytics.`,
            );
          }
          const kept = (/** @type {string} */ value) =>
            !wa.drop.some((origin) => value === origin || value.startsWith(`${origin}/`));
          const directives = template
            .filter(([name]) => name === 'script-src' || name === 'connect-src')
            .map(([name, listed]) => {
              const left = (name in merged ? ordered(merged[name]) : listed).filter((value) =>
                kept(value),
              );
              return [name, ...(left.length > 0 ? left : ["'none'"])].join(' ');
            })
            .join('; ');
          await writeFile(
            file,
            headers.replaceAll(wa.token, () => directives),
          );
          logger.info(
            `_headers: ${wa.token} is now script-src and connect-src without ${wa.drop.join(', ')}`,
          );
        }
      },
    },
  };
}
