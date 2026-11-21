import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

export type Span = { start: number; end: number };
export type Unit = {
  path: string;
  line: number;
  endLine: number;
  start: number;
  end: number;
  kind: "full" | "trailing" | "inline";
  hash: string;
  exempt: boolean;
  text: string;
};
type Lang = "go" | "swift" | "ts" | "js" | "astro" | "css" | "sh" | "nix" | "yaml" | "toml" | "py" | "sql" | "xcconfig" | "jsonc";

const BASELINE = "scripts/comment-baseline.txt";

const LANGS: Record<string, Lang> = {
  go: "go",
  swift: "swift",
  ts: "ts",
  mts: "ts",
  tsx: "ts",
  js: "js",
  mjs: "js",
  cjs: "js",
  astro: "astro",
  css: "css",
  sh: "sh",
  bash: "sh",
  nix: "nix",
  yml: "yaml",
  yaml: "yaml",
  toml: "toml",
  py: "py",
  sql: "sql",
  xcconfig: "xcconfig",
  jsonc: "jsonc",
};

const EXCLUDED = [
  /^server\/oracle\/v1ref\//,
  /^conformance\//,
  /(^|\/)testdata\//,
  /^LICENSES\//,
  /^ios\/Hasala\.xcodeproj\//,
  /(^|\/)node_modules\//,
  /^ios\/HasalaKit\/Sources\/HasalaDesign\/Generated\//,
  /^ios\/HasalaCore\/Sources\/HasalaCore\/Norm\/CharsetTables\.swift$/,
  /^ios\/HasalaCore\/Sources\/HasalaCore\/Categorize\/DictionaryManifest\.swift$/,
  /^ios\/HasalaCore\/Sources\/HasalaCore\/Crypto\/BIP39English\.swift$/,
  /^ios\/HasalaCore\/Sources\/HasalaCore\/Resources\/(Sample|Templates)Manifest\.swift$/,
  /^infra\/qa\/cloudflared\/config\.golden\.yml$/,
];

export function langOf(path: string): Lang | undefined {
  if (EXCLUDED.some((re) => re.test(path))) return undefined;
  const dot = path.lastIndexOf(".");
  if (dot < 0 || path.lastIndexOf("/") > dot) return undefined;
  return LANGS[path.slice(dot + 1)];
}

function lineEnd(src: string, i: number): number {
  const e = src.indexOf("\n", i);
  return e < 0 ? src.length : e;
}

function skipQuoted(src: string, i: number, quote: string, backslash: boolean, multiline: boolean): number {
  let j = i + 1;
  while (j < src.length) {
    const c = src[j];
    if (backslash && c === "\\") {
      j += 2;
      continue;
    }
    if (c === quote) return j + 1;
    if (!multiline && c === "\n") return j;
    j++;
  }
  return src.length;
}

function lexGo(src: string): Span[] {
  const out: Span[] = [];
  let i = 0;
  while (i < src.length) {
    const c = src[i];
    const d = src[i + 1];
    if (c === "/" && d === "/") {
      const e = lineEnd(src, i);
      out.push({ start: i, end: e });
      i = e;
    } else if (c === "/" && d === "*") {
      const e = src.indexOf("*/", i + 2);
      const end = e < 0 ? src.length : e + 2;
      out.push({ start: i, end });
      i = end;
    } else if (c === '"') i = skipQuoted(src, i, '"', true, false);
    else if (c === "'") i = skipQuoted(src, i, "'", true, false);
    else if (c === "`") i = skipQuoted(src, i, "`", false, true);
    else i++;
  }
  return out;
}

function lexCLike(src: string, lineComments: boolean): Span[] {
  const out: Span[] = [];
  let i = 0;
  while (i < src.length) {
    const c = src[i];
    const d = src[i + 1];
    if (lineComments && c === "/" && d === "/") {
      const e = lineEnd(src, i);
      out.push({ start: i, end: e });
      i = e;
    } else if (c === "/" && d === "*") {
      const e = src.indexOf("*/", i + 2);
      const end = e < 0 ? src.length : e + 2;
      out.push({ start: i, end });
      i = end;
    } else if (c === '"') i = skipQuoted(src, i, '"', true, false);
    else if (c === "'" && !lineComments) i = skipQuoted(src, i, "'", true, false);
    else i++;
  }
  return out;
}

function lexXcconfig(src: string): Span[] {
  const out: Span[] = [];
  let i = 0;
  while (i < src.length) {
    const at = src.indexOf("//", i);
    if (at < 0) break;
    const e = lineEnd(src, at);
    out.push({ start: at, end: e });
    i = e;
  }
  return out;
}

const SWIFT_REGEX_PREV = new Set(["(", ",", ":", "=", "[", "{", "!", "&", "|", "?", ";", ""]);

function lexSwift(src: string): Span[] {
  const out: Span[] = [];
  const n = src.length;

  function blockComment(i: number): number {
    let depth = 1;
    let j = i + 2;
    while (j < n && depth > 0) {
      if (src[j] === "/" && src[j + 1] === "*") {
        depth++;
        j += 2;
      } else if (src[j] === "*" && src[j + 1] === "/") {
        depth--;
        j += 2;
      } else j++;
    }
    return j;
  }

  function string(i: number, hashes: number): number {
    const multi = src.startsWith('"""', i);
    const open = multi ? 3 : 1;
    const close = (multi ? '"""' : '"') + "#".repeat(hashes);
    const escape = "\\" + "#".repeat(hashes);
    let j = i + open;
    while (j < n) {
      if (src.startsWith(escape, j)) {
        const k = j + escape.length;
        if (src[k] === "(") {
          j = code(k + 1, true);
          continue;
        }
        j = k + 1;
        continue;
      }
      if (src.startsWith(close, j)) return j + close.length;
      if (!multi && src[j] === "\n") return j;
      j++;
    }
    return n;
  }

  function regexEnd(i: number): number {
    let j = i + 1;
    let inClass = false;
    while (j < n && src[j] !== "\n") {
      const c = src[j];
      if (c === "\\") {
        j += 2;
        continue;
      }
      if (c === "[") inClass = true;
      else if (c === "]") inClass = false;
      else if (c === "/" && !inClass) return j + 1;
      j++;
    }
    return -1;
  }

  function prevSignificant(i: number): string {
    let j = i - 1;
    while (j >= 0 && (src[j] === " " || src[j] === "\t")) j--;
    if (j < 0 || src[j] === "\n") return "";
    return src[j];
  }

  function code(i: number, untilParen: boolean): number {
    let depth = 0;
    let j = i;
    while (j < n) {
      const c = src[j];
      const d = src[j + 1];
      if (c === "/" && d === "/") {
        const e = lineEnd(src, j);
        out.push({ start: j, end: e });
        j = e;
      } else if (c === "/" && d === "*") {
        const e = blockComment(j);
        out.push({ start: j, end: e });
        j = e;
      } else if (c === '"') j = string(j, 0);
      else if (c === "#") {
        let k = j;
        while (src[k] === "#") k++;
        const hashes = k - j;
        if (src[k] === '"') j = string(k, hashes);
        else if (src[k] === "/") {
          const close = "/" + "#".repeat(hashes);
          const e = src.indexOf(close, k + 1);
          j = e < 0 ? k + 1 : e + close.length;
        } else j = k;
      } else if (c === "/" && d !== " " && d !== "=" && d !== "\n" && SWIFT_REGEX_PREV.has(prevSignificant(j))) {
        const e = regexEnd(j);
        j = e < 0 ? j + 1 : e;
      } else if (untilParen && c === "(") {
        depth++;
        j++;
      } else if (untilParen && c === ")") {
        if (depth === 0) return j + 1;
        depth--;
        j++;
      } else j++;
    }
    return n;
  }

  code(0, false);
  return out;
}

const JS_REGEX_WORDS = new Set(["return", "typeof", "case", "in", "of", "void", "delete", "throw", "new", "else", "do", "await", "yield"]);

function lexJs(src: string): Span[] {
  const out: Span[] = [];
  const n = src.length;

  function template(i: number): number {
    let j = i + 1;
    while (j < n) {
      const c = src[j];
      if (c === "\\") j += 2;
      else if (c === "`") return j + 1;
      else if (c === "$" && src[j + 1] === "{") j = code(j + 2, true);
      else j++;
    }
    return n;
  }

  function regexAllowed(i: number): boolean {
    let j = i - 1;
    while (j >= 0 && /\s/.test(src[j])) j--;
    if (j < 0) return true;
    const c = src[j];
    if (/[A-Za-z0-9_$]/.test(c)) {
      let k = j;
      while (k >= 0 && /[A-Za-z0-9_$]/.test(src[k])) k--;
      return JS_REGEX_WORDS.has(src.slice(k + 1, j + 1));
    }
    return c !== ")" && c !== "]" && c !== "}";
  }

  function regexEnd(i: number): number {
    let j = i + 1;
    let inClass = false;
    while (j < n && src[j] !== "\n") {
      const c = src[j];
      if (c === "\\") {
        j += 2;
        continue;
      }
      if (c === "[") inClass = true;
      else if (c === "]") inClass = false;
      else if (c === "/" && !inClass) return j + 1;
      j++;
    }
    return -1;
  }

  function code(i: number, untilBrace: boolean): number {
    let depth = 0;
    let j = i;
    while (j < n) {
      const c = src[j];
      const d = src[j + 1];
      if (c === "/" && d === "/") {
        const e = lineEnd(src, j);
        out.push({ start: j, end: e });
        j = e;
      } else if (c === "/" && d === "*") {
        const e = src.indexOf("*/", j + 2);
        const end = e < 0 ? n : e + 2;
        out.push({ start: j, end });
        j = end;
      } else if (c === '"') j = skipQuoted(src, j, '"', true, false);
      else if (c === "'") j = skipQuoted(src, j, "'", true, false);
      else if (c === "`") j = template(j);
      else if (c === "/" && regexAllowed(j)) {
        const e = regexEnd(j);
        j = e < 0 ? j + 1 : e;
      } else if (untilBrace && c === "{") {
        depth++;
        j++;
      } else if (untilBrace && c === "}") {
        if (depth === 0) return j + 1;
        depth--;
        j++;
      } else j++;
    }
    return n;
  }

  code(0, false);
  return out;
}

function shift(spans: Span[], by: number): Span[] {
  return spans.map((s) => ({ start: s.start + by, end: s.end + by }));
}

function lexAstro(src: string): Span[] {
  const out: Span[] = [];
  let body = 0;
  if (src.startsWith("---\n")) {
    const close = src.indexOf("\n---", 3);
    if (close >= 0) {
      out.push(...shift(lexJs(src.slice(4, close + 1)), 4));
      body = close + 4;
    }
  }
  let i = body;
  while (i < src.length) {
    if (src.startsWith("<!--", i)) {
      const e = src.indexOf("-->", i + 4);
      const end = e < 0 ? src.length : e + 3;
      out.push({ start: i, end });
      i = end;
      continue;
    }
    const tag = /^<(script|style)\b[^>]*>/i.exec(src.slice(i, i + 400));
    if (tag) {
      const open = i + tag[0].length;
      const closeTag = `</${tag[1].toLowerCase()}`;
      const e = src.toLowerCase().indexOf(closeTag, open);
      const close = e < 0 ? src.length : e;
      const inner = src.slice(open, close);
      out.push(...shift(tag[1].toLowerCase() === "script" ? lexJs(inner) : lexCLike(inner, false), open));
      i = close;
      continue;
    }
    if (src[i] === "{") {
      const m = /^\{\s*\/\*/.exec(src.slice(i, i + 40));
      if (m) {
        const e = src.indexOf("*/", i + m[0].length);
        if (e >= 0) {
          const tail = /^\s*\}/.exec(src.slice(e + 2, e + 42));
          if (tail) {
            const end = e + 2 + tail[0].length;
            out.push({ start: i, end });
            i = end;
            continue;
          }
        }
      }
    }
    i++;
  }
  return out;
}

function lexShell(src: string): Span[] {
  const out: Span[] = [];
  const n = src.length;
  const pending: { word: string; stripTabs: boolean }[] = [];

  function heredocs(i: number): number {
    let j = i;
    while (pending.length > 0 && j < n) {
      const doc = pending.shift()!;
      while (j < n) {
        const e = lineEnd(src, j);
        let line = src.slice(j, e);
        if (doc.stripTabs) line = line.replace(/^\t+/, "");
        j = Math.min(e + 1, n);
        if (line === doc.word) break;
      }
    }
    return j;
  }

  function dquote(i: number): number {
    let j = i + 1;
    while (j < n) {
      const c = src[j];
      if (c === "\\") j += 2;
      else if (c === '"') return j + 1;
      else if (c === "$" && src[j + 1] === "(") j = code(j + 2, ")");
      else if (c === "$" && src[j + 1] === "{") j = code(j + 2, "}");
      else if (c === "`") j = skipQuoted(src, j, "`", true, true);
      else j++;
    }
    return n;
  }

  function code(i: number, until: string): number {
    let depth = 0;
    let j = i;
    while (j < n) {
      const c = src[j];
      if (c === "\\") j += 2;
      else if (c === "\n") {
        j++;
        if (pending.length > 0) j = heredocs(j);
      } else if (c === "'") j = src[j - 1] === "$" ? skipQuoted(src, j, "'", true, true) : skipQuoted(src, j, "'", false, true);
      else if (c === '"') j = dquote(j);
      else if (c === "`") j = skipQuoted(src, j, "`", true, true);
      else if (c === "$" && src[j + 1] === "{") j = code(j + 2, "}");
      else if (c === "$" && src[j + 1] === "(") j = code(j + 2, ")");
      else if (c === "#" && until !== "}" && (j === 0 || /[\s;(|&]/.test(src[j - 1]))) {
        const e = lineEnd(src, j);
        out.push({ start: j, end: e });
        j = e;
      } else if (c === "<" && src[j + 1] === "<" && src[j + 2] !== "<" && src[j - 1] !== "<") {
        const m = /^<<(-?)\s*(?:'([^']+)'|"([^"]+)"|\\?([A-Za-z_][A-Za-z0-9_]*))/.exec(src.slice(j, j + 200));
        if (m) {
          pending.push({ word: m[2] ?? m[3] ?? m[4], stripTabs: m[1] === "-" });
          j += m[0].length;
        } else j += 2;
      } else if (until !== "" && c === (until === ")" ? "(" : "{")) {
        depth++;
        j++;
      } else if (until !== "" && c === until) {
        if (depth === 0) return j + 1;
        depth--;
        j++;
      } else j++;
    }
    return n;
  }

  code(0, "");
  return out;
}

function lexNix(src: string): Span[] {
  const out: Span[] = [];
  const n = src.length;

  function dstring(i: number): number {
    let j = i + 1;
    while (j < n) {
      const c = src[j];
      if (c === "\\") j += 2;
      else if (c === '"') return j + 1;
      else if (c === "$" && src[j + 1] === "{") j = code(j + 2, true);
      else j++;
    }
    return n;
  }

  function istring(i: number): number {
    let j = i + 2;
    while (j < n) {
      if (src.startsWith("''", j)) {
        const next = src[j + 2];
        if (next === "'" || next === "$") j += 3;
        else if (next === "\\") j += 4;
        else return j + 2;
      } else if (src[j] === "$" && src[j + 1] === "$") j += 2;
      else if (src[j] === "$" && src[j + 1] === "{") j = code(j + 2, true);
      else j++;
    }
    return n;
  }

  function code(i: number, untilBrace: boolean): number {
    let depth = 0;
    let j = i;
    while (j < n) {
      const c = src[j];
      if (c === "#") {
        const e = lineEnd(src, j);
        out.push({ start: j, end: e });
        j = e;
      } else if (c === "/" && src[j + 1] === "*") {
        const e = src.indexOf("*/", j + 2);
        const end = e < 0 ? n : e + 2;
        out.push({ start: j, end });
        j = end;
      } else if (c === '"') j = dstring(j);
      else if (c === "'" && src[j + 1] === "'") j = istring(j);
      else if (untilBrace && c === "{") {
        depth++;
        j++;
      } else if (c === "$" && src[j + 1] === "{") j = code(j + 2, true);
      else if (untilBrace && c === "}") {
        if (depth === 0) return j + 1;
        depth--;
        j++;
      } else j++;
    }
    return n;
  }

  code(0, false);
  return out;
}

function lexYaml(src: string): Span[] {
  const out: Span[] = [];
  let i = 0;
  let scalarIndent = -1;
  while (i < src.length) {
    const e = lineEnd(src, i);
    const line = src.slice(i, e);
    const indent = line.length - line.trimStart().length;
    if (scalarIndent >= 0) {
      if (line.trim() === "" || indent > scalarIndent) {
        i = e + 1;
        continue;
      }
      scalarIndent = -1;
    }
    let j = 0;
    let comment = -1;
    while (j < line.length) {
      const c = line[j];
      if (c === "'") {
        j++;
        while (j < line.length && !(line[j] === "'" && line[j + 1] !== "'")) j += line[j] === "'" ? 2 : 1;
        j++;
      } else if (c === '"') j = skipQuoted(line, j, '"', true, false);
      else if (c === "#" && (j === 0 || line[j - 1] === " " || line[j - 1] === "\t")) {
        comment = j;
        break;
      } else j++;
    }
    const codePart = comment < 0 ? line : line.slice(0, comment);
    if (comment >= 0) out.push({ start: i + comment, end: e });
    if (/(^|[\s:-])[|>][+-]?[0-9]?[+-]?\s*$/.test(codePart) && /(:|^\s*-)\s*[|>][+-]?[0-9]?[+-]?\s*$/.test(codePart)) {
      const dashes = /^\s*(-\s+)*/.exec(codePart)![0].length;
      scalarIndent = /^\s*(-\s+)+[|>]/.test(codePart) ? dashes - 1 : dashes;
    }
    i = e + 1;
  }
  return out;
}

function lexHash(src: string, triple: boolean): Span[] {
  const out: Span[] = [];
  const n = src.length;
  let i = 0;
  while (i < n) {
    const c = src[i];
    if (c === "#") {
      const e = lineEnd(src, i);
      out.push({ start: i, end: e });
      i = e;
    } else if (c === '"' || c === "'") {
      const q = c.repeat(3);
      if (triple && src.startsWith(q, i)) {
        let j = i + 3;
        while (j < n && !src.startsWith(q, j)) j += c === '"' && src[j] === "\\" ? 2 : 1;
        i = Math.min(j + 3, n);
      } else i = skipQuoted(src, i, c, c === '"' || !triple, false);
    } else i++;
  }
  return out;
}

function lexSql(src: string): Span[] {
  const out: Span[] = [];
  const n = src.length;
  let i = 0;
  while (i < n) {
    const c = src[i];
    const d = src[i + 1];
    if (c === "-" && d === "-") {
      const e = lineEnd(src, i);
      out.push({ start: i, end: e });
      i = e;
    } else if (c === "/" && d === "*") {
      let depth = 1;
      let j = i + 2;
      while (j < n && depth > 0) {
        if (src[j] === "/" && src[j + 1] === "*") {
          depth++;
          j += 2;
        } else if (src[j] === "*" && src[j + 1] === "/") {
          depth--;
          j += 2;
        } else j++;
      }
      out.push({ start: i, end: j });
      i = j;
    } else if (c === "'") {
      let j = i + 1;
      while (j < n && !(src[j] === "'" && src[j + 1] !== "'")) j += src[j] === "'" ? 2 : 1;
      i = j + 1;
    } else if (c === '"') i = skipQuoted(src, i, '"', false, true);
    else if (c === "$") {
      const m = /^\$[A-Za-z_]*\$/.exec(src.slice(i, i + 64));
      if (m) {
        const e = src.indexOf(m[0], i + m[0].length);
        i = e < 0 ? n : e + m[0].length;
      } else i++;
    } else i++;
  }
  return out;
}

export function lex(lang: Lang, src: string): Span[] {
  switch (lang) {
    case "go":
      return lexGo(src);
    case "swift":
      return lexSwift(src);
    case "ts":
    case "js":
      return lexJs(src);
    case "astro":
      return lexAstro(src);
    case "css":
      return lexCLike(src, false);
    case "jsonc":
      return lexCLike(src, true);
    case "xcconfig":
      return lexXcconfig(src);
    case "sh":
      return lexShell(src);
    case "nix":
      return lexNix(src);
    case "yaml":
      return lexYaml(src);
    case "toml":
      return lexHash(src, true);
    case "py":
      return lexHash(src, true);
    case "sql":
      return lexSql(src);
  }
}

const EXEMPT: Partial<Record<Lang, RegExp[]>> = {
  go: [/^\/\/go:[a-z]+/, /^\/\/ Code generated .* DO NOT EDIT\.$/, /^\/\/nolint\b/, /^\/\/lint:[a-z]+/, /^\/\/ \+build /, /^\/\/export /, /^\/\/line /],
  swift: [/^\/\/ swift-tools-version:/, /^\/\/ ?swiftlint:[a-z]+/, /^\/\/ lint-allow: \S+ \S/, /^\/\/ swift-format-ignore/],
  ts: [/^\/\/ ?@ts-(check|nocheck|expect-error|ignore)\b/, /^\/\/\/ ?<reference /, /^\/\*\s*@vite-ignore\s*\*\/$/, /^(\/\/|\/\*) ?(eslint|biome|prettier)-/],
  js: [
    /^\/\/ ?@ts-(check|nocheck|expect-error|ignore)\b/,
    /^\/\/\/ ?<reference /,
    /^\/\*\s*@vite-ignore\s*\*\/$/,
    /^(\/\/|\/\*) ?(eslint|biome|prettier)-/,
    /^\/\*\*[^]*@(type|typedef|param|returns?|satisfies|template|import)\b/,
  ],
  sh: [/^# ?shellcheck /],
  sql: [/^-- \+goose [A-Za-z]+$/],
  py: [/^# ?(type:|noqa|pragma:)/],
};

function isExempt(lang: Lang, src: string, span: Span, text: string): boolean {
  if ((lang === "sh" || lang === "py") && span.start === 0 && text.startsWith("#!")) return true;
  if (lang === "astro") return (EXEMPT.ts ?? []).some((re) => re.test(text));
  if (lang === "yaml") {
    const ls = src.lastIndexOf("\n", span.start - 1) + 1;
    return /\buses:\s*\S+@[0-9a-f]{40}\s*$/.test(src.slice(ls, span.start)) && /^# ?v?[0-9]/.test(text);
  }
  return (EXEMPT[lang] ?? []).some((re) => re.test(text));
}

function hashOf(text: string): string {
  return createHash("sha256").update(text.replace(/\s+/g, " ").trim()).digest("hex").slice(0, 12);
}

export function unitsOf(path: string, lang: Lang, src: string): Unit[] {
  const spans = lex(lang, src).sort((a, b) => a.start - b.start);
  const lineStarts = [0];
  for (let i = 0; i < src.length; i++) if (src[i] === "\n") lineStarts.push(i + 1);
  const lineOf = (off: number) => {
    let lo = 0;
    let hi = lineStarts.length - 1;
    while (lo < hi) {
      const mid = (lo + hi + 1) >> 1;
      if (lineStarts[mid] <= off) lo = mid;
      else hi = mid - 1;
    }
    return lo + 1;
  };
  const units: Unit[] = [];
  for (const s of spans) {
    const text = src.slice(s.start, s.end);
    const ls = src.lastIndexOf("\n", s.start - 1) + 1;
    const le = lineEnd(src, s.end);
    const before = src.slice(ls, s.start).trim() === "";
    const after = src.slice(s.end, le).trim() === "";
    const kind = before && after ? "full" : after ? "trailing" : "inline";
    const exempt = isExempt(lang, src, s, text);
    const line = lineOf(s.start);
    const endLine = lineOf(Math.max(s.start, s.end - 1));
    const prev = units[units.length - 1];
    if (prev && kind === "full" && prev.kind === "full" && !exempt && !prev.exempt && prev.endLine + 1 === line && src.slice(prev.end, s.start).trim() === "") {
      prev.end = s.end;
      prev.endLine = endLine;
      prev.text = src.slice(prev.start, prev.end);
      prev.hash = hashOf(prev.text);
      continue;
    }
    units.push({ path, line, endLine, start: s.start, end: s.end, kind, hash: hashOf(text), exempt, text });
  }
  return units;
}

const OPENERS = /[{([]\s*$/;
const CLOSERS = /^\s*[})\]]/;

export function strip(src: string, units: Unit[]): string {
  let out = src;
  const sorted = [...units].sort((a, b) => b.start - a.start);
  for (const u of sorted) {
    const ls = out.lastIndexOf("\n", u.start - 1) + 1;
    const le = lineEnd(out, u.end);
    const before = out.slice(ls, u.start);
    const after = out.slice(u.end, le);
    if (before.trim() === "" && after.trim() === "") {
      out = out.slice(0, ls) + out.slice(Math.min(le + 1, out.length));
      out = tidy(out, ls);
    } else if (after.trim() === "") {
      out = out.slice(0, ls) + before.replace(/\s+$/, "") + out.slice(le);
    } else if (before.trim() === "") {
      out = out.slice(0, u.start) + after.replace(/^\s+/, "") + out.slice(le);
    } else if (u.text.includes("\n")) {
      out = out.slice(0, u.start).replace(/[ \t]+$/, "") + "\n" + out.slice(u.end).replace(/^[ \t]+/, "");
    } else {
      const spaced = /\s$/.test(before) && /^\s/.test(after);
      out = out.slice(0, u.start) + out.slice(spaced ? u.end + 1 : u.end);
    }
  }
  return out;
}

function tidy(src: string, at: number): string {
  let out = src;
  const lineAt = (i: number) => out.slice(i, lineEnd(out, i));
  const prevStart = (i: number) => (i <= 0 ? -1 : out.lastIndexOf("\n", i - 2) + 1);
  for (;;) {
    if (at >= out.length) {
      const trimmed = out.replace(/\n+$/, "");
      return trimmed === "" ? "" : trimmed + "\n";
    }
    const next = lineAt(at);
    const ps = prevStart(at);
    const prev = ps < 0 ? "" : lineAt(ps);
    if (next.trim() === "" && (ps < 0 || prev.trim() === "" || OPENERS.test(prev))) {
      out = out.slice(0, at) + out.slice(Math.min(lineEnd(out, at) + 1, out.length));
      continue;
    }
    if (ps >= 0 && prev.trim() === "" && CLOSERS.test(next)) {
      out = out.slice(0, ps) + out.slice(at);
      at = ps;
      continue;
    }
    return out;
  }
}

function codeOnly(lang: Lang, src: string): string {
  const spans = lex(lang, src).sort((a, b) => b.start - a.start);
  let out = src;
  for (const s of spans) out = out.slice(0, s.start) + out.slice(s.end);
  return out.replace(/\s+/g, "");
}

function git(root: string, args: string[]): string {
  return execFileSync("git", ["-C", root, ...args], { encoding: "utf8", maxBuffer: 1 << 28, stdio: ["ignore", "pipe", "ignore"] });
}

function trackedFiles(root: string, only: string[]): string[] {
  const files = git(root, ["ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", ...only])
    .split("\0")
    .filter((f) => f !== "" && langOf(f) !== undefined && existsSync(join(root, f)));
  return [...new Set(files)].sort();
}

function scan(root: string, only: string[]): Unit[] {
  const units: Unit[] = [];
  for (const path of trackedFiles(root, only)) {
    units.push(...unitsOf(path, langOf(path)!, readFileSync(join(root, path), "utf8")));
  }
  return units;
}

type Baseline = Map<string, string[]>;

function parseBaseline(text: string): Baseline {
  const map: Baseline = new Map();
  for (const line of text.split("\n")) {
    if (line === "") continue;
    const tab = line.lastIndexOf("\t");
    if (tab < 0) throw new Error(`${BASELINE}: bad line: ${line}`);
    const path = line.slice(0, tab);
    if (!map.has(path)) map.set(path, []);
    map.get(path)!.push(line.slice(tab + 1));
  }
  return map;
}

function formatBaseline(entries: [string, string][]): string {
  return entries
    .map(([p, h]) => `${p}\t${h}`)
    .sort()
    .map((l) => l + "\n")
    .join("");
}

function readBaseline(root: string): Baseline {
  const file = join(root, BASELINE);
  return existsSync(file) ? parseBaseline(readFileSync(file, "utf8")) : new Map();
}

function byPath(units: Unit[]): Map<string, Unit[]> {
  const map = new Map<string, Unit[]>();
  for (const u of units) {
    if (u.exempt) continue;
    if (!map.has(u.path)) map.set(u.path, []);
    map.get(u.path)!.push(u);
  }
  return map;
}

function compare(units: Unit[], baseline: Baseline): { added: Unit[]; kept: [string, string][]; gone: number } {
  const added: Unit[] = [];
  const kept: [string, string][] = [];
  let total = 0;
  const live = byPath(units);
  for (const [, hashes] of baseline) total += hashes.length;
  for (const [path, list] of live) {
    const allowed = [...(baseline.get(path) ?? [])];
    for (const u of list) {
      const at = allowed.indexOf(u.hash);
      if (at < 0) added.push(u);
      else {
        allowed.splice(at, 1);
        kept.push([path, u.hash]);
      }
    }
  }
  return { added, kept, gone: total - kept.length };
}

function preview(text: string): string {
  const one = text.replace(/\s+/g, " ").trim();
  return one.length > 70 ? one.slice(0, 67) + "..." : one;
}

function check(root: string, base: string | undefined): number {
  const baseline = readBaseline(root);
  const { added, gone } = compare(scan(root, []), baseline);
  let failed = 0;
  for (const u of added) {
    console.error(`${u.path}:${u.line}: comment not allowed: ${preview(u.text)}`);
    failed = 1;
  }
  if (added.length > 0) {
    console.error(`comment-lint: ${added.length} new or changed comment(s). Delete them. A decision goes in docs/decisions/, not in a comment.`);
  }
  if (gone > 0) {
    console.error(`comment-lint: ${BASELINE} lists ${gone} comment(s) that are gone. Run: bun scripts/comment-lint.ts ratchet`);
    failed = 1;
  }
  if (base !== undefined) {
    let old: string | undefined;
    try {
      old = git(root, ["show", `${base}:${BASELINE}`]);
    } catch {
      old = undefined;
    }
    if (old !== undefined) {
      const pool: string[] = [];
      for (const [, hashes] of parseBaseline(old)) pool.push(...hashes);
      let grew = 0;
      for (const [, hashes] of baseline) {
        for (const h of hashes) {
          const at = pool.indexOf(h);
          if (at < 0) grew++;
          else pool.splice(at, 1);
        }
      }
      if (grew > 0) {
        console.error(`comment-lint: ${BASELINE} has ${grew} entr${grew === 1 ? "y" : "ies"} that ${base} does not have. The baseline only gets smaller.`);
        failed = 1;
      }
    }
  }
  if (failed === 0) {
    let left = 0;
    for (const [, hashes] of baseline) left += hashes.length;
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
    const entries = units.filter((u) => !u.exempt).map((u) => [u.path, u.hash] as [string, string]);
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
  const units = scan(root, only).filter((u) => !u.exempt);
  if (json) {
    console.log(JSON.stringify(units.map(({ start, end, exempt, ...rest }) => rest)));
    return 0;
  }
  for (const u of units) console.log(`${u.path}\t${u.line}\t${u.hash}\t${u.kind}\t${preview(u.text)}`);
  return 0;
}

function stripFiles(root: string, listFile: string, dryRun: boolean): number {
  const wanted = new Map<string, Map<number, string>>();
  for (const line of readFileSync(listFile, "utf8").split("\n")) {
    if (line === "") continue;
    const [path, lineNo, hash] = line.split("\t");
    if (!wanted.has(path)) wanted.set(path, new Map());
    wanted.get(path)!.set(Number(lineNo), hash);
  }
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
    const src = readFileSync(file, "utf8");
    const units = unitsOf(path, lang, src).filter((u) => !u.exempt);
    const chosen: Unit[] = [];
    for (const [lineNo, hash] of picks) {
      const u = units.find((x) => x.line === lineNo && x.hash === hash);
      if (!u) {
        console.error(`comment-lint: ${path}:${lineNo}: no comment ${hash} there`);
        failed = 1;
      } else chosen.push(u);
    }
    const out = strip(src, chosen);
    const keptBefore = units.filter((u) => !chosen.includes(u)).map((u) => u.hash);
    const keptAfter = unitsOf(path, lang, out)
      .filter((u) => !u.exempt)
      .map((u) => u.hash);
    if (codeOnly(lang, src) !== codeOnly(lang, out) || keptBefore.join() !== keptAfter.join()) {
      console.error(`comment-lint: ${path}: the result would change more than the comments; left as it is`);
      failed = 1;
      continue;
    }
    removed += chosen.length;
    shed += src.split("\n").length - out.split("\n").length;
    if (!dryRun) writeFileSync(file, out);
  }
  console.log(`comment-lint: ${dryRun ? "would remove" : "removed"} ${removed} comment(s), ${shed} line(s)`);
  return failed;
}

function stats(root: string, only: string[]): number {
  const rows = new Map<string, { files: number; withComments: number; lines: number; units: number; full: number; trailing: number; shed: number }>();
  for (const path of trackedFiles(root, only)) {
    const lang = langOf(path)!;
    const src = readFileSync(join(root, path), "utf8");
    const units = unitsOf(path, lang, src).filter((u) => !u.exempt);
    const row = rows.get(lang) ?? { files: 0, withComments: 0, lines: 0, units: 0, full: 0, trailing: 0, shed: 0 };
    row.files++;
    row.lines += src.split("\n").length - 1;
    row.units += units.length;
    if (units.length > 0) row.withComments++;
    for (const u of units) {
      if (u.kind === "full") row.full += u.endLine - u.line + 1;
      else row.trailing++;
    }
    row.shed += src.split("\n").length - strip(src, units).split("\n").length;
    rows.set(lang, row);
  }
  console.log("lang\tfiles\twith_comments\tlines\tcomments\tcomment_only_lines\ttrailing\tlines_shed");
  const total = { files: 0, withComments: 0, lines: 0, units: 0, full: 0, trailing: 0, shed: 0 };
  for (const [lang, r] of [...rows].sort((a, b) => b[1].shed - a[1].shed)) {
    console.log(`${lang}\t${r.files}\t${r.withComments}\t${r.lines}\t${r.units}\t${r.full}\t${r.trailing}\t${r.shed}`);
    for (const k of Object.keys(total) as (keyof typeof total)[]) total[k] += r[k];
  }
  console.log(`total\t${total.files}\t${total.withComments}\t${total.lines}\t${total.units}\t${total.full}\t${total.trailing}\t${total.shed}`);
  return 0;
}

function main(argv: string[]): number {
  const args = [...argv];
  let root = resolve(import.meta.dir, "..");
  const rootAt = args.indexOf("--root");
  if (rootAt >= 0) {
    root = resolve(args[rootAt + 1]);
    args.splice(rootAt, 2);
  }
  const flag = (name: string) => {
    const at = args.indexOf(name);
    if (at < 0) return false;
    args.splice(at, 1);
    return true;
  };
  const value = (name: string) => {
    const at = args.indexOf(name);
    if (at < 0) return undefined;
    const v = args[at + 1];
    args.splice(at, 2);
    return v;
  };
  const cmd = args.shift();
  switch (cmd) {
    case "check":
      return check(root, value("--base"));
    case "ratchet":
      return ratchet(root, flag("--init"));
    case "list":
      return list(root, args.filter((a) => a !== "--json"), args.includes("--json"));
    case "strip": {
      const dry = flag("--dry-run");
      if (args.length !== 1) break;
      return stripFiles(root, args[0], dry);
    }
    case "stats":
      return stats(root, args);
  }
  console.error("usage: bun scripts/comment-lint.ts check [--base REV] | ratchet | list [--json] [PATH...] | strip [--dry-run] LIST | stats [PATH...]");
  return 2;
}

if (import.meta.main) process.exit(main(process.argv.slice(2)));
