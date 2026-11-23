import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';

export interface Span {
  start: number;
  end: number;
}
export interface Unit {
  path: string;
  line: number;
  endLine: number;
  start: number;
  end: number;
  kind: 'full' | 'trailing' | 'inline';
  hash: string;
  exempt: boolean;
  text: string;
}
type Lang =
  | 'go'
  | 'swift'
  | 'ts'
  | 'js'
  | 'astro'
  | 'css'
  | 'sh'
  | 'nix'
  | 'yaml'
  | 'toml'
  | 'py'
  | 'sql'
  | 'xcconfig'
  | 'jsonc';

interface QuoteRules {
  backslash: boolean;
  multiline: boolean;
}

const BASELINE = 'scripts/comment-baseline.txt';
const MAX_BUFFER = 2 ** 28;

const ESCAPED_LINE: QuoteRules = { backslash: true, multiline: false };
const ESCAPED_BLOCK: QuoteRules = { backslash: true, multiline: true };
const RAW_BLOCK: QuoteRules = { backslash: false, multiline: true };

const LANGS: Record<string, Lang> = {
  go: 'go',
  swift: 'swift',
  ts: 'ts',
  mts: 'ts',
  tsx: 'ts',
  js: 'js',
  mjs: 'js',
  cjs: 'js',
  astro: 'astro',
  css: 'css',
  sh: 'sh',
  bash: 'sh',
  nix: 'nix',
  yml: 'yaml',
  yaml: 'yaml',
  toml: 'toml',
  py: 'py',
  sql: 'sql',
  xcconfig: 'xcconfig',
  jsonc: 'jsonc',
};

const EXCLUDED = [
  /^server\/oracle\/v1ref\//u,
  /^conformance\//u,
  /(^|\/)testdata\//u,
  /^LICENSES\//u,
  /^ios\/Hasala\.xcodeproj\//u,
  /(^|\/)node_modules\//u,
  /^ios\/HasalaKit\/Sources\/HasalaDesign\/Generated\//u,
  /^ios\/HasalaCore\/Sources\/HasalaCore\/Norm\/CharsetTables\.swift$/u,
  /^ios\/HasalaCore\/Sources\/HasalaCore\/Categorize\/DictionaryManifest\.swift$/u,
  /^ios\/HasalaCore\/Sources\/HasalaCore\/Crypto\/BIP39English\.swift$/u,
  /^ios\/HasalaCore\/Sources\/HasalaCore\/Resources\/(Sample|Templates)Manifest\.swift$/u,
  /^infra\/qa\/cloudflared\/config\.golden\.yml$/u,
];

export function langOf(path: string): Lang | undefined {
  if (EXCLUDED.some((re) => re.test(path))) {
    return undefined;
  }
  const dot = path.lastIndexOf('.');
  if (dot === -1 || path.lastIndexOf('/') > dot) {
    return undefined;
  }
  return LANGS[path.slice(dot + 1)];
}

function lineEnd(src: string, from: number): number {
  const found = src.indexOf('\n', from);
  return found === -1 ? src.length : found;
}

function blockEnd(src: string, start: number): number {
  const found = src.indexOf('*/', start + 2);
  return found === -1 ? src.length : found + 2;
}

function nestedBlockEnd(src: string, start: number): number {
  let depth = 1;
  let pos = start + 2;
  while (pos < src.length && depth > 0) {
    if (src[pos] === '/' && src[pos + 1] === '*') {
      depth += 1;
      pos += 2;
    } else if (src[pos] === '*' && src[pos + 1] === '/') {
      depth -= 1;
      pos += 2;
    } else {
      pos += 1;
    }
  }
  return pos;
}

function skipQuoted(src: string, start: number, quote: string, rules: QuoteRules): number {
  let pos = start + 1;
  while (pos < src.length) {
    const ch = src[pos];
    if (rules.backslash && ch === '\\') {
      pos += 2;
      continue;
    }
    if (ch === quote) {
      return pos + 1;
    }
    if (!rules.multiline && ch === '\n') {
      return pos;
    }
    pos += 1;
  }
  return src.length;
}

function doubledQuoteEnd(text: string, start: number): number {
  let pos = start + 1;
  while (pos < text.length && !(text[pos] === "'" && text[pos + 1] !== "'")) {
    pos += text[pos] === "'" ? 2 : 1;
  }
  return pos + 1;
}

function regexEnd(src: string, start: number): number {
  let pos = start + 1;
  let inClass = false;
  while (pos < src.length && src[pos] !== '\n') {
    const ch = src[pos];
    if (ch === '\\') {
      pos += 2;
      continue;
    }
    if (ch === '[') {
      inClass = true;
    } else if (ch === ']') {
      inClass = false;
    } else if (ch === '/' && !inClass) {
      return pos + 1;
    }
    pos += 1;
  }
  return -1;
}

function step(ch: string | undefined, open: string, close: string): number {
  if (ch === open) {
    return 1;
  }
  return ch === close ? -1 : 0;
}

function lexGo(src: string): Span[] {
  const out: Span[] = [];
  let pos = 0;
  while (pos < src.length) {
    const ch = src[pos];
    const next = src[pos + 1];
    if (ch === '/' && next === '/') {
      const end = lineEnd(src, pos);
      out.push({ start: pos, end });
      pos = end;
    } else if (ch === '/' && next === '*') {
      const end = blockEnd(src, pos);
      out.push({ start: pos, end });
      pos = end;
    } else if (ch === '"') {
      pos = skipQuoted(src, pos, '"', ESCAPED_LINE);
    } else if (ch === "'") {
      pos = skipQuoted(src, pos, "'", ESCAPED_LINE);
    } else if (ch === '`') {
      pos = skipQuoted(src, pos, '`', RAW_BLOCK);
    } else {
      pos += 1;
    }
  }
  return out;
}

function lexCLike(src: string, lineComments: boolean): Span[] {
  const out: Span[] = [];
  let pos = 0;
  while (pos < src.length) {
    const ch = src[pos];
    const next = src[pos + 1];
    if (lineComments && ch === '/' && next === '/') {
      const end = lineEnd(src, pos);
      out.push({ start: pos, end });
      pos = end;
    } else if (ch === '/' && next === '*') {
      const end = blockEnd(src, pos);
      out.push({ start: pos, end });
      pos = end;
    } else if (ch === '"') {
      pos = skipQuoted(src, pos, '"', ESCAPED_LINE);
    } else if (ch === "'" && !lineComments) {
      pos = skipQuoted(src, pos, "'", ESCAPED_LINE);
    } else {
      pos += 1;
    }
  }
  return out;
}

function lexXcconfig(src: string): Span[] {
  const out: Span[] = [];
  let pos = 0;
  while (pos < src.length) {
    const at = src.indexOf('//', pos);
    if (at === -1) {
      break;
    }
    const end = lineEnd(src, at);
    out.push({ start: at, end });
    pos = end;
  }
  return out;
}

const SWIFT_REGEX_PREV = new Set(['(', ',', ':', '=', '[', '{', '!', '&', '|', '?', ';', '']);

function lexSwift(src: string): Span[] {
  const out: Span[] = [];
  const len = src.length;

  function string(start: number, hashes: number): number {
    const multi = src.startsWith('"""', start);
    const open = multi ? 3 : 1;
    const close = `${multi ? '"""' : '"'}${'#'.repeat(hashes)}`;
    const escape = `\\${'#'.repeat(hashes)}`;
    let pos = start + open;
    while (pos < len) {
      if (src.startsWith(escape, pos)) {
        const after = pos + escape.length;
        pos = src[after] === '(' ? code(after + 1, true) : after + 1;
        continue;
      }
      if (src.startsWith(close, pos)) {
        return pos + close.length;
      }
      if (!multi && src[pos] === '\n') {
        return pos;
      }
      pos += 1;
    }
    return len;
  }

  function prevSignificant(start: number): string {
    let pos = start - 1;
    while (pos >= 0 && (src[pos] === ' ' || src[pos] === '\t')) {
      pos -= 1;
    }
    if (pos < 0 || src[pos] === '\n') {
      return '';
    }
    return src[pos] ?? '';
  }

  function hashed(start: number): number {
    let pos = start;
    while (src[pos] === '#') {
      pos += 1;
    }
    const hashes = pos - start;
    if (src[pos] === '"') {
      return string(pos, hashes);
    }
    if (src[pos] === '/') {
      const close = `/${'#'.repeat(hashes)}`;
      const found = src.indexOf(close, pos + 1);
      return found === -1 ? pos + 1 : found + close.length;
    }
    return pos;
  }

  function regexStart(pos: number): boolean {
    const next = src[pos + 1];
    return (
      src[pos] === '/' &&
      next !== ' ' &&
      next !== '=' &&
      next !== '\n' &&
      SWIFT_REGEX_PREV.has(prevSignificant(pos))
    );
  }

  function token(pos: number): number {
    const ch = src[pos];
    const next = src[pos + 1];
    if (ch === '/' && next === '/') {
      const end = lineEnd(src, pos);
      out.push({ start: pos, end });
      return end;
    }
    if (ch === '/' && next === '*') {
      const end = nestedBlockEnd(src, pos);
      out.push({ start: pos, end });
      return end;
    }
    if (ch === '"') {
      return string(pos, 0);
    }
    if (ch === '#') {
      return hashed(pos);
    }
    if (regexStart(pos)) {
      const end = regexEnd(src, pos);
      return end < 0 ? pos + 1 : end;
    }
    return -1;
  }

  function code(start: number, untilParen: boolean): number {
    let depth = 0;
    let pos = start;
    while (pos < len) {
      const ch = src[pos];
      if (untilParen && ch === ')' && depth === 0) {
        return pos + 1;
      }
      const next = token(pos);
      if (next !== -1) {
        pos = next;
        continue;
      }
      if (untilParen) {
        depth += step(ch, '(', ')');
      }
      pos += 1;
    }
    return len;
  }

  code(0, false);
  return out;
}

const JS_REGEX_WORDS = new Set([
  'return',
  'typeof',
  'case',
  'in',
  'of',
  'void',
  'delete',
  'throw',
  'new',
  'else',
  'do',
  'await',
  'yield',
]);

function lexJs(src: string): Span[] {
  const out: Span[] = [];
  const len = src.length;

  function template(start: number): number {
    let pos = start + 1;
    while (pos < len) {
      const ch = src[pos];
      if (ch === '\\') {
        pos += 2;
      } else if (ch === '`') {
        return pos + 1;
      } else if (ch === '$' && src[pos + 1] === '{') {
        pos = code(pos + 2, true);
      } else {
        pos += 1;
      }
    }
    return len;
  }

  function regexAllowed(start: number): boolean {
    let pos = start - 1;
    while (pos >= 0 && /\s/u.test(src[pos] ?? '')) {
      pos -= 1;
    }
    if (pos < 0) {
      return true;
    }
    const ch = src[pos] ?? '';
    if (/[A-Za-z0-9_$]/u.test(ch)) {
      let back = pos;
      while (back >= 0 && /[A-Za-z0-9_$]/u.test(src[back] ?? '')) {
        back -= 1;
      }
      return JS_REGEX_WORDS.has(src.slice(back + 1, pos + 1));
    }
    return ch !== ')' && ch !== ']' && ch !== '}';
  }

  function token(pos: number): number {
    const ch = src[pos];
    const next = src[pos + 1];
    if (ch === '/' && next === '/') {
      const end = lineEnd(src, pos);
      out.push({ start: pos, end });
      return end;
    }
    if (ch === '/' && next === '*') {
      const end = blockEnd(src, pos);
      out.push({ start: pos, end });
      return end;
    }
    if (ch === '"') {
      return skipQuoted(src, pos, '"', ESCAPED_LINE);
    }
    if (ch === "'") {
      return skipQuoted(src, pos, "'", ESCAPED_LINE);
    }
    if (ch === '`') {
      return template(pos);
    }
    if (ch === '/' && regexAllowed(pos)) {
      const end = regexEnd(src, pos);
      return end < 0 ? pos + 1 : end;
    }
    return -1;
  }

  function code(start: number, untilBrace: boolean): number {
    let depth = 0;
    let pos = start;
    while (pos < len) {
      const ch = src[pos];
      if (untilBrace && ch === '}' && depth === 0) {
        return pos + 1;
      }
      const next = token(pos);
      if (next !== -1) {
        pos = next;
        continue;
      }
      if (untilBrace) {
        depth += step(ch, '{', '}');
      }
      pos += 1;
    }
    return len;
  }

  code(0, false);
  return out;
}

function shift(spans: Span[], by: number): Span[] {
  return spans.map((span) => ({ start: span.start + by, end: span.end + by }));
}

function jsxCommentEnd(src: string, start: number): number {
  const open = /^\{\s*\/\*/u.exec(src.slice(start, start + 40));
  if (!open) {
    return -1;
  }
  const close = src.indexOf('*/', start + open[0].length);
  if (close === -1) {
    return -1;
  }
  const tail = /^\s*\}/u.exec(src.slice(close + 2, close + 42));
  return tail ? close + 2 + tail[0].length : -1;
}

function lexAstro(src: string): Span[] {
  const out: Span[] = [];
  let body = 0;
  if (src.startsWith('---\n')) {
    const close = src.indexOf('\n---', 3);
    if (close !== -1) {
      out.push(...shift(lexJs(src.slice(4, close + 1)), 4));
      body = close + 4;
    }
  }
  let pos = body;
  while (pos < src.length) {
    if (src.startsWith('<!--', pos)) {
      const found = src.indexOf('-->', pos + 4);
      const end = found === -1 ? src.length : found + 3;
      out.push({ start: pos, end });
      pos = end;
      continue;
    }
    const tag = /^<([Ss][Cc][Rr][Ii][Pp][Tt]|[Ss][Tt][Yy][Ll][Ee])\b[^>]*>/u.exec(
      src.slice(pos, pos + 400),
    );
    if (tag) {
      const name = (tag[1] ?? '').toLowerCase();
      const open = pos + tag[0].length;
      const found = src.toLowerCase().indexOf(`</${name}`, open);
      const close = found === -1 ? src.length : found;
      const inner = src.slice(open, close);
      out.push(...shift(name === 'script' ? lexJs(inner) : lexCLike(inner, false), open));
      pos = close;
      continue;
    }
    if (src[pos] === '{') {
      const end = jsxCommentEnd(src, pos);
      if (end !== -1) {
        out.push({ start: pos, end });
        pos = end;
        continue;
      }
    }
    pos += 1;
  }
  return out;
}

function lexShell(src: string): Span[] {
  const out: Span[] = [];
  const len = src.length;
  const pending: { word: string; stripTabs: boolean }[] = [];

  function heredocs(start: number): number {
    let pos = start;
    while (pending.length > 0 && pos < len) {
      const doc = pending.shift();
      if (doc === undefined) {
        break;
      }
      while (pos < len) {
        const end = lineEnd(src, pos);
        const raw = src.slice(pos, end);
        const line = doc.stripTabs ? raw.replace(/^\t+/u, '') : raw;
        pos = Math.min(end + 1, len);
        if (line === doc.word) {
          break;
        }
      }
    }
    return pos;
  }

  function dquote(start: number): number {
    let pos = start + 1;
    while (pos < len) {
      const ch = src[pos];
      if (ch === '\\') {
        pos += 2;
      } else if (ch === '"') {
        return pos + 1;
      } else if (ch === '$' && src[pos + 1] === '(') {
        pos = code(pos + 2, ')');
      } else if (ch === '$' && src[pos + 1] === '{') {
        pos = code(pos + 2, '}');
      } else if (ch === '`') {
        pos = skipQuoted(src, pos, '`', ESCAPED_BLOCK);
      } else {
        pos += 1;
      }
    }
    return len;
  }

  function commentAt(pos: number, until: string): boolean {
    return src[pos] === '#' && until !== '}' && (pos === 0 || /[\s;(|&]/u.test(src[pos - 1] ?? ''));
  }

  function heredocAt(pos: number): boolean {
    return src[pos] === '<' && src[pos + 1] === '<' && src[pos + 2] !== '<' && src[pos - 1] !== '<';
  }

  function heredocStart(pos: number): number {
    const match = /^<<(-?)\s*(?:'([^']+)'|"([^"]+)"|\\?([A-Za-z_][A-Za-z0-9_]*))/u.exec(
      src.slice(pos, pos + 200),
    );
    if (!match) {
      return pos + 2;
    }
    pending.push({ word: match[2] ?? match[3] ?? match[4] ?? '', stripTabs: match[1] === '-' });
    return pos + match[0].length;
  }

  function token(pos: number, until: string): number {
    const ch = src[pos];
    const next = src[pos + 1];
    if (ch === '\\') {
      return pos + 2;
    }
    if (ch === '\n') {
      return pending.length > 0 ? heredocs(pos + 1) : pos + 1;
    }
    if (ch === "'") {
      return skipQuoted(src, pos, "'", src[pos - 1] === '$' ? ESCAPED_BLOCK : RAW_BLOCK);
    }
    if (ch === '"') {
      return dquote(pos);
    }
    if (ch === '`') {
      return skipQuoted(src, pos, '`', ESCAPED_BLOCK);
    }
    if (ch === '$' && next === '{') {
      return code(pos + 2, '}');
    }
    if (ch === '$' && next === '(') {
      return code(pos + 2, ')');
    }
    if (commentAt(pos, until)) {
      const end = lineEnd(src, pos);
      out.push({ start: pos, end });
      return end;
    }
    if (heredocAt(pos)) {
      return heredocStart(pos);
    }
    return -1;
  }

  function code(start: number, until: string): number {
    let depth = 0;
    let pos = start;
    while (pos < len) {
      const ch = src[pos];
      if (until !== '' && ch === until && depth === 0) {
        return pos + 1;
      }
      const next = token(pos, until);
      if (next !== -1) {
        pos = next;
        continue;
      }
      if (until !== '') {
        depth += step(ch, until === ')' ? '(' : '{', until);
      }
      pos += 1;
    }
    return len;
  }

  code(0, '');
  return out;
}

function lexNix(src: string): Span[] {
  const out: Span[] = [];
  const len = src.length;

  function dstring(start: number): number {
    let pos = start + 1;
    while (pos < len) {
      const ch = src[pos];
      if (ch === '\\') {
        pos += 2;
      } else if (ch === '"') {
        return pos + 1;
      } else if (ch === '$' && src[pos + 1] === '{') {
        pos = code(pos + 2, true);
      } else {
        pos += 1;
      }
    }
    return len;
  }

  function istring(start: number): number {
    let pos = start + 2;
    while (pos < len) {
      if (src.startsWith("''", pos)) {
        const next = src[pos + 2];
        if (next === "'" || next === '$') {
          pos += 3;
        } else if (next === '\\') {
          pos += 4;
        } else {
          return pos + 2;
        }
      } else if (src[pos] === '$' && src[pos + 1] === '$') {
        pos += 2;
      } else if (src[pos] === '$' && src[pos + 1] === '{') {
        pos = code(pos + 2, true);
      } else {
        pos += 1;
      }
    }
    return len;
  }

  function token(pos: number): number {
    const ch = src[pos];
    const next = src[pos + 1];
    if (ch === '#') {
      const end = lineEnd(src, pos);
      out.push({ start: pos, end });
      return end;
    }
    if (ch === '/' && next === '*') {
      const end = blockEnd(src, pos);
      out.push({ start: pos, end });
      return end;
    }
    if (ch === '"') {
      return dstring(pos);
    }
    if (ch === "'" && next === "'") {
      return istring(pos);
    }
    if (ch === '$' && next === '{') {
      return code(pos + 2, true);
    }
    return -1;
  }

  function code(start: number, untilBrace: boolean): number {
    let depth = 0;
    let pos = start;
    while (pos < len) {
      const ch = src[pos];
      if (untilBrace && ch === '}' && depth === 0) {
        return pos + 1;
      }
      const next = token(pos);
      if (next !== -1) {
        pos = next;
        continue;
      }
      if (untilBrace) {
        depth += step(ch, '{', '}');
      }
      pos += 1;
    }
    return len;
  }

  code(0, false);
  return out;
}

function yamlCommentAt(line: string): number {
  let pos = 0;
  while (pos < line.length) {
    const ch = line[pos];
    if (ch === "'") {
      pos = doubledQuoteEnd(line, pos);
    } else if (ch === '"') {
      pos = skipQuoted(line, pos, '"', ESCAPED_LINE);
    } else if (ch === '#' && (pos === 0 || line[pos - 1] === ' ' || line[pos - 1] === '\t')) {
      return pos;
    } else {
      pos += 1;
    }
  }
  return -1;
}

function blockScalarIndent(codePart: string): number {
  if (
    !/(^|[\s:-])[|>][+-]?[0-9]?[+-]?\s*$/u.test(codePart) ||
    !/(:|^\s*-)\s*[|>][+-]?[0-9]?[+-]?\s*$/u.test(codePart)
  ) {
    return -1;
  }
  const dashes = (/^\s*(-\s+)*/u.exec(codePart)?.[0] ?? '').length;
  return /^\s*(-\s+)+[|>]/u.test(codePart) ? dashes - 1 : dashes;
}

function lexYaml(src: string): Span[] {
  const out: Span[] = [];
  let pos = 0;
  let scalarIndent = -1;
  while (pos < src.length) {
    const end = lineEnd(src, pos);
    const line = src.slice(pos, end);
    const indent = line.length - line.trimStart().length;
    if (scalarIndent >= 0 && (line.trim() === '' || indent > scalarIndent)) {
      pos = end + 1;
      continue;
    }
    const comment = yamlCommentAt(line);
    const codePart = comment < 0 ? line : line.slice(0, comment);
    if (comment >= 0) {
      out.push({ start: pos + comment, end });
    }
    scalarIndent = blockScalarIndent(codePart);
    pos = end + 1;
  }
  return out;
}

function lexHash(src: string, triple: boolean): Span[] {
  const out: Span[] = [];
  const len = src.length;
  let pos = 0;
  while (pos < len) {
    const ch = src[pos];
    if (ch === '#') {
      const end = lineEnd(src, pos);
      out.push({ start: pos, end });
      pos = end;
    } else if (ch === '"' || ch === "'") {
      const fence = ch.repeat(3);
      if (triple && src.startsWith(fence, pos)) {
        let inner = pos + 3;
        while (inner < len && !src.startsWith(fence, inner)) {
          inner += ch === '"' && src[inner] === '\\' ? 2 : 1;
        }
        pos = Math.min(inner + 3, len);
      } else {
        pos = skipQuoted(src, pos, ch, { backslash: ch === '"' || !triple, multiline: false });
      }
    } else {
      pos += 1;
    }
  }
  return out;
}

function dollarQuoteEnd(src: string, start: number): number {
  const match = /^\$[A-Za-z_]*\$/u.exec(src.slice(start, start + 64));
  if (!match) {
    return start + 1;
  }
  const found = src.indexOf(match[0], start + match[0].length);
  return found === -1 ? src.length : found + match[0].length;
}

function lexSql(src: string): Span[] {
  const out: Span[] = [];
  let pos = 0;
  while (pos < src.length) {
    const ch = src[pos];
    const next = src[pos + 1];
    if (ch === '-' && next === '-') {
      const end = lineEnd(src, pos);
      out.push({ start: pos, end });
      pos = end;
    } else if (ch === '/' && next === '*') {
      const end = nestedBlockEnd(src, pos);
      out.push({ start: pos, end });
      pos = end;
    } else if (ch === "'") {
      pos = doubledQuoteEnd(src, pos);
    } else if (ch === '"') {
      pos = skipQuoted(src, pos, '"', RAW_BLOCK);
    } else if (ch === '$') {
      pos = dollarQuoteEnd(src, pos);
    } else {
      pos += 1;
    }
  }
  return out;
}

const LEXERS: Record<Lang, (src: string) => Span[]> = {
  go: lexGo,
  swift: lexSwift,
  ts: lexJs,
  js: lexJs,
  astro: lexAstro,
  css: (src: string): Span[] => lexCLike(src, false),
  jsonc: (src: string): Span[] => lexCLike(src, true),
  xcconfig: lexXcconfig,
  sh: lexShell,
  nix: lexNix,
  yaml: lexYaml,
  toml: (src: string): Span[] => lexHash(src, true),
  py: (src: string): Span[] => lexHash(src, true),
  sql: lexSql,
};

export function lex(lang: Lang, src: string): Span[] {
  return LEXERS[lang](src);
}

const EXEMPT: Partial<Record<Lang, RegExp[]>> = {
  go: [
    /^\/\/go:[a-z]+/u,
    /^\/\/ Code generated .* DO NOT EDIT\.$/u,
    /^\/\/nolint\b/u,
    /^\/\/lint:[a-z]+/u,
    /^\/\/ \+build /u,
    /^\/\/export /u,
    /^\/\/line /u,
  ],
  swift: [
    /^\/\/ swift-tools-version:/u,
    /^\/\/ ?swiftlint:[a-z]+/u,
    /^\/\/ lint-allow: \S+ \S/u,
    /^\/\/ swift-format-ignore/u,
  ],
  ts: [
    /^\/\/ ?@ts-(check|nocheck|expect-error|ignore)\b/u,
    /^\/\/\/ ?<reference /u,
    /^\/\*\s*@vite-ignore\s*\*\/$/u,
    /^(\/\/|\/\*) ?(eslint|biome|prettier)-/u,
  ],
  js: [
    /^\/\/ ?@ts-(check|nocheck|expect-error|ignore)\b/u,
    /^\/\/\/ ?<reference /u,
    /^\/\*\s*@vite-ignore\s*\*\/$/u,
    /^(\/\/|\/\*) ?(eslint|biome|prettier)-/u,
    /^\/\*\*[^]*@(type|typedef|param|returns?|satisfies|template|import)\b/u,
  ],
  sh: [/^# ?shellcheck /u],
  sql: [/^-- \+goose [A-Za-z]+$/u],
  py: [/^# ?(type:|noqa|pragma:)/u],
};

function isExempt(lang: Lang, src: string, span: Span, text: string): boolean {
  if ((lang === 'sh' || lang === 'py') && span.start === 0 && text.startsWith('#!')) {
    return true;
  }
  if (lang === 'astro') {
    return (EXEMPT.ts ?? []).some((re) => re.test(text));
  }
  if (lang === 'yaml') {
    const lineStart = src.lastIndexOf('\n', span.start - 1) + 1;
    return (
      /\buses:\s*\S+@[0-9a-f]{40}\s*$/u.test(src.slice(lineStart, span.start)) &&
      /^# ?v?[0-9]/u.test(text)
    );
  }
  return (EXEMPT[lang] ?? []).some((re) => re.test(text));
}

function hashOf(text: string): string {
  return createHash('sha256')
    .update(text.replaceAll(/\s+/gu, ' ').trim())
    .digest('hex')
    .slice(0, 12);
}

function kindOf(before: boolean, after: boolean): Unit['kind'] {
  if (!after) {
    return 'inline';
  }
  return before ? 'full' : 'trailing';
}

export function unitsOf(path: string, lang: Lang, src: string): Unit[] {
  const spans = lex(lang, src).toSorted((left, right) => left.start - right.start);
  const lineStarts = [0];
  for (let pos = 0; pos < src.length; pos += 1) {
    if (src[pos] === '\n') {
      lineStarts.push(pos + 1);
    }
  }
  const lineOf = (off: number): number => {
    let lo = 0;
    let hi = lineStarts.length - 1;
    while (lo < hi) {
      const mid = Math.floor((lo + hi + 1) / 2);
      if ((lineStarts[mid] ?? 0) <= off) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo + 1;
  };
  const units: Unit[] = [];
  for (const span of spans) {
    const text = src.slice(span.start, span.end);
    const lineStart = src.lastIndexOf('\n', span.start - 1) + 1;
    const lineStop = lineEnd(src, span.end);
    const before = src.slice(lineStart, span.start).trim() === '';
    const after = src.slice(span.end, lineStop).trim() === '';
    const kind = kindOf(before, after);
    const exempt = isExempt(lang, src, span, text);
    const line = lineOf(span.start);
    const endLine = lineOf(Math.max(span.start, span.end - 1));
    const prev = units.at(-1);
    if (
      prev &&
      kind === 'full' &&
      prev.kind === 'full' &&
      !exempt &&
      !prev.exempt &&
      prev.endLine + 1 === line &&
      src.slice(prev.end, span.start).trim() === ''
    ) {
      prev.end = span.end;
      prev.endLine = endLine;
      prev.text = src.slice(prev.start, prev.end);
      prev.hash = hashOf(prev.text);
      continue;
    }
    units.push({
      path,
      line,
      endLine,
      start: span.start,
      end: span.end,
      kind,
      hash: hashOf(text),
      exempt,
      text,
    });
  }
  return units;
}

const OPENERS = /[{([]\s*$/u;
const CLOSERS = /^\s*[})\]]/u;

export function strip(src: string, units: Unit[]): string {
  let out = src;
  const sorted = [...units].toSorted((left, right) => right.start - left.start);
  for (const unit of sorted) {
    const lineStart = out.lastIndexOf('\n', unit.start - 1) + 1;
    const lineStop = lineEnd(out, unit.end);
    const before = out.slice(lineStart, unit.start);
    const after = out.slice(unit.end, lineStop);
    if (before.trim() === '' && after.trim() === '') {
      out = out.slice(0, lineStart) + out.slice(Math.min(lineStop + 1, out.length));
      out = tidy(out, lineStart);
    } else if (after.trim() === '') {
      out = out.slice(0, lineStart) + before.replace(/\s+$/u, '') + out.slice(lineStop);
    } else if (before.trim() === '') {
      out = out.slice(0, unit.start) + after.replace(/^\s+/u, '') + out.slice(lineStop);
    } else if (unit.text.includes('\n')) {
      out = `${out.slice(0, unit.start).replace(/[ \t]+$/u, '')}\n${out
        .slice(unit.end)
        .replace(/^[ \t]+/u, '')}`;
    } else {
      const spaced = /\s$/u.test(before) && /^\s/u.test(after);
      out = out.slice(0, unit.start) + out.slice(spaced ? unit.end + 1 : unit.end);
    }
  }
  return out;
}

function tidy(src: string, at: number): string {
  let out = src;
  let pos = at;
  const lineAt = (from: number): string => out.slice(from, lineEnd(out, from));
  const prevStart = (from: number): number =>
    from <= 0 ? -1 : out.lastIndexOf('\n', from - 2) + 1;
  for (;;) {
    if (pos >= out.length) {
      const trimmed = out.replace(/\n+$/u, '');
      return trimmed === '' ? '' : `${trimmed}\n`;
    }
    const next = lineAt(pos);
    const prevAt = prevStart(pos);
    const prev = prevAt < 0 ? '' : lineAt(prevAt);
    if (next.trim() === '' && (prevAt < 0 || prev.trim() === '' || OPENERS.test(prev))) {
      out = out.slice(0, pos) + out.slice(Math.min(lineEnd(out, pos) + 1, out.length));
      continue;
    }
    if (prevAt >= 0 && prev.trim() === '' && CLOSERS.test(next)) {
      out = out.slice(0, prevAt) + out.slice(pos);
      pos = prevAt;
      continue;
    }
    return out;
  }
}

function codeOnly(lang: Lang, src: string): string {
  const spans = lex(lang, src).toSorted((left, right) => right.start - left.start);
  let out = src;
  for (const span of spans) {
    out = out.slice(0, span.start) + out.slice(span.end);
  }
  return out.replaceAll(/\s+/gu, '');
}

function git(root: string, args: string[]): string {
  return execFileSync('git', ['-C', root, ...args], {
    encoding: 'utf8',
    maxBuffer: MAX_BUFFER,
    stdio: ['ignore', 'pipe', 'ignore'],
  });
}

function trackedFiles(root: string, only: string[]): string[] {
  const files = git(root, [
    'ls-files',
    '-z',
    '--cached',
    '--others',
    '--exclude-standard',
    '--',
    ...only,
  ])
    .split('\0')
    .filter((file) => file !== '' && langOf(file) !== undefined && existsSync(join(root, file)));
  return [...new Set(files)].toSorted();
}

function scan(root: string, only: string[]): Unit[] {
  const units: Unit[] = [];
  for (const path of trackedFiles(root, only)) {
    const lang = langOf(path);
    if (lang === undefined) {
      continue;
    }
    units.push(...unitsOf(path, lang, readFileSync(join(root, path), 'utf8')));
  }
  return units;
}

type Baseline = Map<string, string[]>;

function parseBaseline(text: string): Baseline {
  const map: Baseline = new Map();
  for (const line of text.split('\n')) {
    if (line === '') {
      continue;
    }
    const tab = line.lastIndexOf('\t');
    if (tab === -1) {
      throw new Error(`${BASELINE}: bad line: ${line}`);
    }
    const path = line.slice(0, tab);
    const hash = line.slice(tab + 1);
    const hashes = map.get(path);
    if (hashes) {
      hashes.push(hash);
    } else {
      map.set(path, [hash]);
    }
  }
  return map;
}

function formatBaseline(entries: [string, string][]): string {
  return entries
    .map(([path, hash]) => `${path}\t${hash}`)
    .toSorted()
    .map((line) => `${line}\n`)
    .join('');
}

function readBaseline(root: string): Baseline {
  const file = join(root, BASELINE);
  return existsSync(file) ? parseBaseline(readFileSync(file, 'utf8')) : new Map();
}

function byPath(units: Unit[]): Map<string, Unit[]> {
  const map = new Map<string, Unit[]>();
  for (const unit of units) {
    if (unit.exempt) {
      continue;
    }
    const pathUnits = map.get(unit.path);
    if (pathUnits) {
      pathUnits.push(unit);
    } else {
      map.set(unit.path, [unit]);
    }
  }
  return map;
}

function compare(
  units: Unit[],
  baseline: Baseline,
): { added: Unit[]; kept: [string, string][]; gone: number } {
  const added: Unit[] = [];
  const kept: [string, string][] = [];
  let total = 0;
  const live = byPath(units);
  for (const [, hashes] of baseline) {
    total += hashes.length;
  }
  for (const [path, pathUnits] of live) {
    const allowed = [...(baseline.get(path) ?? [])];
    for (const unit of pathUnits) {
      const at = allowed.indexOf(unit.hash);
      if (at === -1) {
        added.push(unit);
      } else {
        allowed.splice(at, 1);
        kept.push([path, unit.hash]);
      }
    }
  }
  return { added, kept, gone: total - kept.length };
}

function preview(text: string): string {
  const one = text.replaceAll(/\s+/gu, ' ').trim();
  return one.length > 70 ? `${one.slice(0, 67)}...` : one;
}

function readOldBaseline(root: string, base: string): string | null {
  try {
    return git(root, ['show', `${base}:${BASELINE}`]);
  } catch {
    return null;
  }
}

function grownSince(root: string, base: string, baseline: Baseline): number {
  const old = readOldBaseline(root, base);
  if (old === null) {
    return 0;
  }
  const pool: string[] = [];
  for (const [, hashes] of parseBaseline(old)) {
    pool.push(...hashes);
  }
  let grew = 0;
  for (const [, hashes] of baseline) {
    for (const hash of hashes) {
      const at = pool.indexOf(hash);
      if (at === -1) {
        grew += 1;
      } else {
        pool.splice(at, 1);
      }
    }
  }
  return grew;
}

function check(root: string, base: string | undefined): number {
  const baseline = readBaseline(root);
  const { added, gone } = compare(scan(root, []), baseline);
  let failed = 0;
  for (const unit of added) {
    console.error(`${unit.path}:${unit.line}: comment not allowed: ${preview(unit.text)}`);
    failed = 1;
  }
  if (added.length > 0) {
    console.error(
      `comment-lint: ${added.length} new or changed comment(s). Delete them. A decision goes in docs/decisions/, not in a comment.`,
    );
  }
  if (gone > 0) {
    console.error(
      `comment-lint: ${BASELINE} lists ${gone} comment(s) that are gone. Run: bun scripts/comment-lint.ts ratchet`,
    );
    failed = 1;
  }
  if (base !== undefined) {
    const grew = grownSince(root, base, baseline);
    if (grew > 0) {
      console.error(
        `comment-lint: ${BASELINE} has ${grew} entr${grew === 1 ? 'y' : 'ies'} that ${base} does not have. The baseline only gets smaller.`,
      );
      failed = 1;
    }
  }
  if (failed === 0) {
    let left = 0;
    for (const [, hashes] of baseline) {
      left += hashes.length;
    }
    console.log(`comment-lint: no new comments (${left} left in the baseline)`);
  }
  return failed;
}

function ratchet(root: string, init: boolean): number {
  const file = join(root, BASELINE);
  const units = scan(root, []);
  if (init) {
    if (existsSync(file)) {
      console.error(`comment-lint: ${BASELINE} exists. init runs only one time.`);
      return 2;
    }
    const entries = units
      .filter((unit) => !unit.exempt)
      .map((unit): [string, string] => [unit.path, unit.hash]);
    writeFileSync(file, formatBaseline(entries));
    console.log(`comment-lint: wrote ${entries.length} entries`);
    return 0;
  }
  const { kept, gone } = compare(units, readBaseline(root));
  writeFileSync(file, formatBaseline(kept));
  console.log(`comment-lint: removed ${gone} entries, ${kept.length} left`);
  return 0;
}

function list(root: string, only: string[], json: boolean): number {
  const units = scan(root, only).filter((unit) => !unit.exempt);
  if (json) {
    console.log(
      JSON.stringify(
        units.map((unit) => ({
          path: unit.path,
          line: unit.line,
          endLine: unit.endLine,
          kind: unit.kind,
          hash: unit.hash,
          text: unit.text,
        })),
      ),
    );
    return 0;
  }
  for (const unit of units) {
    console.log(`${unit.path}\t${unit.line}\t${unit.hash}\t${unit.kind}\t${preview(unit.text)}`);
  }
  return 0;
}

function readStripList(listFile: string): Map<string, Map<number, string | undefined>> {
  const wanted = new Map<string, Map<number, string | undefined>>();
  for (const line of readFileSync(listFile, 'utf8').split('\n')) {
    if (line === '') {
      continue;
    }
    const [path = '', lineNo, hash] = line.split('\t');
    const picks = wanted.get(path);
    if (picks) {
      picks.set(Number(lineNo), hash);
    } else {
      wanted.set(path, new Map([[Number(lineNo), hash]]));
    }
  }
  return wanted;
}

function stripFiles(root: string, listFile: string, dryRun: boolean): number {
  const wanted = readStripList(listFile);
  let removed = 0;
  let shed = 0;
  let failed = 0;
  for (const [path, picks] of wanted) {
    const lang = langOf(path);
    const file = join(root, path);
    if (lang === undefined || !existsSync(file)) {
      console.error(`comment-lint: ${path}: not a file this lint reads`);
      failed = 1;
      continue;
    }
    const src = readFileSync(file, 'utf8');
    const units = unitsOf(path, lang, src).filter((unit) => !unit.exempt);
    const chosen: Unit[] = [];
    for (const [lineNo, hash] of picks) {
      const found = units.find((unit) => unit.line === lineNo && unit.hash === hash);
      if (found) {
        chosen.push(found);
      } else {
        console.error(`comment-lint: ${path}:${lineNo}: no comment ${hash} there`);
        failed = 1;
      }
    }
    const out = strip(src, chosen);
    const keptBefore = units.filter((unit) => !chosen.includes(unit)).map((unit) => unit.hash);
    const keptAfter = unitsOf(path, lang, out)
      .filter((unit) => !unit.exempt)
      .map((unit) => unit.hash);
    if (
      codeOnly(lang, src) !== codeOnly(lang, out) ||
      keptBefore.join(',') !== keptAfter.join(',')
    ) {
      console.error(
        `comment-lint: ${path}: the result would change more than the comments; left as it is`,
      );
      failed = 1;
      continue;
    }
    removed += chosen.length;
    shed += src.split('\n').length - out.split('\n').length;
    if (!dryRun) {
      writeFileSync(file, out);
    }
  }
  console.log(
    `comment-lint: ${dryRun ? 'would remove' : 'removed'} ${removed} comment(s), ${shed} line(s)`,
  );
  return failed;
}

interface StatsRow {
  files: number;
  withComments: number;
  lines: number;
  units: number;
  full: number;
  trailing: number;
  shed: number;
}

function stats(root: string, only: string[]): number {
  const rows = new Map<string, StatsRow>();
  for (const path of trackedFiles(root, only)) {
    const lang = langOf(path);
    if (lang === undefined) {
      continue;
    }
    const src = readFileSync(join(root, path), 'utf8');
    const units = unitsOf(path, lang, src).filter((unit) => !unit.exempt);
    const row = rows.get(lang) ?? {
      files: 0,
      withComments: 0,
      lines: 0,
      units: 0,
      full: 0,
      trailing: 0,
      shed: 0,
    };
    row.files += 1;
    row.lines += src.split('\n').length - 1;
    row.units += units.length;
    if (units.length > 0) {
      row.withComments += 1;
    }
    for (const unit of units) {
      if (unit.kind === 'full') {
        row.full += unit.endLine - unit.line + 1;
      } else {
        row.trailing += 1;
      }
    }
    row.shed += src.split('\n').length - strip(src, units).split('\n').length;
    rows.set(lang, row);
  }
  console.log(
    'lang\tfiles\twith_comments\tlines\tcomments\tcomment_only_lines\ttrailing\tlines_shed',
  );
  const total: StatsRow = {
    files: 0,
    withComments: 0,
    lines: 0,
    units: 0,
    full: 0,
    trailing: 0,
    shed: 0,
  };
  for (const [lang, row] of [...rows].toSorted((left, right) => right[1].shed - left[1].shed)) {
    console.log(
      `${lang}\t${row.files}\t${row.withComments}\t${row.lines}\t${row.units}\t${row.full}\t${row.trailing}\t${row.shed}`,
    );
    for (const key of Object.keys(total) as (keyof StatsRow)[]) {
      total[key] += row[key];
    }
  }
  console.log(
    `total\t${total.files}\t${total.withComments}\t${total.lines}\t${total.units}\t${total.full}\t${total.trailing}\t${total.shed}`,
  );
  return 0;
}

function usage(): number {
  console.error(
    'usage: bun scripts/comment-lint.ts check [--base REV] | ratchet | list [--json] [PATH...] | strip [--dry-run] LIST | stats [PATH...]',
  );
  return 2;
}

function main(argv: string[]): number {
  const args = [...argv];
  let root = resolve(import.meta.dir, '..');
  const rootAt = args.indexOf('--root');
  if (rootAt !== -1) {
    const rootArg = args[rootAt + 1];
    if (rootArg === undefined) {
      throw new TypeError('comment-lint: --root needs a path');
    }
    root = resolve(rootArg);
    args.splice(rootAt, 2);
  }
  const flag = (name: string): boolean => {
    const at = args.indexOf(name);
    if (at === -1) {
      return false;
    }
    args.splice(at, 1);
    return true;
  };
  const value = (name: string): string | undefined => {
    const at = args.indexOf(name);
    if (at === -1) {
      return;
    }
    const [, found] = args.splice(at, 2);
    return found;
  };
  const cmd = args.shift();
  switch (cmd) {
    case 'check': {
      return check(root, value('--base'));
    }
    case 'ratchet': {
      return ratchet(root, flag('--init'));
    }
    case 'list': {
      return list(
        root,
        args.filter((arg) => arg !== '--json'),
        args.includes('--json'),
      );
    }
    case 'strip': {
      const dry = flag('--dry-run');
      const [listFile] = args;
      if (args.length !== 1 || listFile === undefined) {
        return usage();
      }
      return stripFiles(root, listFile, dry);
    }
    case 'stats': {
      return stats(root, args);
    }
    default: {
      return usage();
    }
  }
}

if (import.meta.main) {
  process.exit(main(process.argv.slice(2)));
}
