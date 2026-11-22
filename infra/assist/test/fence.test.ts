import { describe, expect, test } from "bun:test";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { need } from "./helpers";

const ROOT = join(import.meta.dir, "..");

function stripJsonc(text: string): string {
  let out = "";
  let index = 0;
  let inString = false;
  while (index < text.length) {
    const ch = text[index] ?? "";
    const next = text[index + 1];
    if (inString) {
      out += ch;
      if (ch === "\\") {
        out += next ?? "";
        index += 2;
        continue;
      }
      if (ch === '"') {inString = false;}
      index += 1;
      continue;
    }
    if (ch === '"') {
      inString = true;
      out += ch;
      index += 1;
      continue;
    }
    if (ch === "/" && next === "/") {
      while (index < text.length && text[index] !== "\n") {index += 1;}
      continue;
    }
    if (ch === "/" && next === "*") {
      index += 2;
      while (index < text.length && !(text[index] === "*" && text[index + 1] === "/")) {index += 1;}
      index += 2;
      continue;
    }
    out += ch;
    index += 1;
  }
  return out.replaceAll(/,(\s*[}\]])/gu, "$1");
}

function files(dir: string): string[] {
  const out: string[] = [];
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) {out.push(...files(path));}
    else {out.push(path);}
  }
  return out;
}

const rawConfig = readFileSync(join(ROOT, "wrangler.jsonc"), "utf8");
interface RateLimit {
  name: string;
  namespace_id: string;
  simple: { limit: number; period: number };
}

interface WranglerConfig {
  name?: string;
  env?: unknown;
  logpush?: unknown;
  observability?: { enabled?: unknown; logs?: unknown; traces?: unknown };
  ai?: unknown;
  ratelimits: RateLimit[];
  vars: Record<string, unknown>;
  routes?: unknown;
}

const config = JSON.parse(stripJsonc(rawConfig)) as WranglerConfig;

const FORBIDDEN = [
  "kv_namespaces",
  "d1_databases",
  "r2_buckets",
  "durable_objects",
  "queues",
  "vectorize",
  "analytics_engine_datasets",
  "services",
  "tail_consumers",
  "hyperdrive",
  "workflows",
  "dispatch_namespaces",
  "mtls_certificates",
  "browser",
  "send_email",
  "pipelines",
  "secrets_store_secrets",
  "unsafe",
  "migrations",
  "logfwdr",
  "streaming_tail_consumers",
];

function keysDeep(value: unknown, out = new Set<string>()): Set<string> {
  if (Array.isArray(value)) {for (const x of value) {keysDeep(x, out);}}
  else if (typeof value === "object" && value !== null) {
    for (const [key, x] of Object.entries(value)) {
      out.add(key);
      keysDeep(x, out);
    }
  }
  return out;
}

describe("wrangler.jsonc fence", () => {
  test("the JSONC stripper keeps strings intact", () => {
    expect(JSON.parse(stripJsonc('{"a": "x // y", /* c */ "b": [1,], // z\n}'))).toEqual({ a: "x // y", b: [1] });
  });

  test("no storage, queue, service or tail binding at any level", () => {
    const keys = keysDeep(config);
    for (const key of FORBIDDEN) {expect(keys.has(key)).toBe(false);}
  });

  test("no env overrides", () => {
    expect(config.env).toBeUndefined();
  });

  test("logpush is off", () => {
    expect(config.logpush).toBe(false);
  });

  test("observability is off", () => {
    expect(config.observability?.enabled).toBe(false);
    expect(config.observability?.logs).toBeUndefined();
    expect(config.observability?.traces).toBeUndefined();
  });

  test("the only AI Gateway mention is the AI_GATEWAY var, and it names a dedicated gateway", () => {
    expect(rawConfig.match(/gateway/giu)).toEqual(["GATEWAY"]);
    expect(rawConfig).toContain('"AI_GATEWAY": "hasala-assist"');
    expect(config.vars.AI_GATEWAY).toBe("hasala-assist");
  });

  test("the bindings are exactly AI, PER_IP, GLOBAL and REFUSED_CLIENTS", () => {
    expect(config.name).toBe("hasala-assist");
    expect(config.ai).toEqual({ binding: "AI" });
    expect(config.ratelimits.map((limit) => limit.name).toSorted()).toEqual(["GLOBAL", "PER_IP"]);
    const perIp = need(config.ratelimits.find((limit) => limit.name === "PER_IP"));
    const global = need(config.ratelimits.find((limit) => limit.name === "GLOBAL"));
    expect(perIp.simple).toEqual({ limit: 30, period: 60 });
    expect(global.simple).toEqual({ limit: 600, period: 60 });
    expect(global.simple.limit).toBeGreaterThanOrEqual(20 * perIp.simple.limit);
    expect(perIp.namespace_id).not.toBe(global.namespace_id);
    expect(config.vars).toEqual({ REFUSED_CLIENTS: "", AI_GATEWAY: "hasala-assist" });
    const allowedTop = new Set([
      "$schema",
      "name",
      "main",
      "compatibility_date",
      "compatibility_flags",
      "routes",
      "workers_dev",
      "preview_urls",
      "observability",
      "logpush",
      "send_metrics",
      "ai",
      "ratelimits",
      "vars",
    ]);
    expect(Object.keys(config).filter((key) => !allowedTop.has(key))).toEqual([]);
  });

  test("the route is the assist.hasala.app placeholder", () => {
    expect(config.routes).toEqual([{ pattern: "assist.hasala.app", custom_domain: true }]);
  });
});

const GATEWAY_ALLOWED = [
  "options: { gateway: { id: string; skipCache: true; collectLog: false } }",
  "AI_GATEWAY?: string;",
  'const gatewayId = (env.AI_GATEWAY ?? "").trim();',
  'if (gatewayId === "") {return refusal(HTTP.unavailable, "model_unavailable");}',
  "{ gateway: { id: gatewayId, skipCache: true, collectLog: false } }",
];

describe("source fence", () => {
  const sources = files(join(ROOT, "src")).map((path) => ({ path, text: readFileSync(path, "utf8") }));

  test("there is source to scan", () => {
    expect(sources.length).toBeGreaterThan(0);
  });

  test("no console calls", () => {
    for (const { path, text } of sources) {expect(`${path}: ${/\bconsole\s*\./u.test(text)}`).toBe(`${path}: false`);}
  });

  test("no queueRequest or batch", () => {
    for (const { path, text } of sources) {
      expect(`${path}: ${/queueRequest/u.test(text)}`).toBe(`${path}: false`);
      expect(`${path}: ${/\bbatch\b/iu.test(text)}`).toBe(`${path}: false`);
    }
  });

  test("AI Gateway only in the allowed form: id from AI_GATEWAY, cache off, logging off", () => {
    const index = join(ROOT, "src", "index.ts");
    const indexText = need(sources.find(({ path }) => path === index)).text;
    let rest = indexText;
    for (const allowed of GATEWAY_ALLOWED) {
      expect(`${allowed}: ${indexText.split(allowed).length - 1}`).toBe(`${allowed}: 1`);
      rest = rest.split(allowed).join("");
    }
    expect(`${index}: ${/gateway/iu.test(rest)}`).toBe(`${index}: false`);
    for (const { path, text } of sources.filter((source) => source.path !== index)) {
      expect(`${path}: ${/gateway/iu.test(text)}`).toBe(`${path}: false`);
    }
    for (const { path, text } of sources) {
      for (const re of [/\bcacheTtl\b/u, /\bcacheKey\b/u, /\bmetadata\b/u, /\beventId\b/u, /cf-aig-/iu, /\bcollectLog\s*:\s*true\b/u, /\bskipCache\s*:\s*false\b/u, /\bdefault"/u]) {
        expect(`${path}: ${re} ${re.test(text)}`).toBe(`${path}: ${re} false`);
      }
    }
    expect(sources.some(({ path }) => path === index)).toBe(true);
  });

  test("the AI_GATEWAY check rejects a gateway mention outside the allowed form", () => {
    const bad = [
      '{ gateway: { id: gatewayId, skipCache: true, collectLog: true } }',
      '{ gateway: { id: "default", skipCache: true, collectLog: false } }',
      '{ gateway: { id: gatewayId } }',
    ];
    for (const snippet of bad) {
      let rest = snippet;
      for (const allowed of GATEWAY_ALLOWED) {rest = rest.split(allowed).join("");}
      expect(/gateway/iu.test(rest)).toBe(true);
    }
  });

  test("no storage or network APIs", () => {
    for (const { path, text } of sources) {
      for (const re of [/(?<!async\s)\bfetch\s*\(/u,/\bcaches\b/u, /\bwaitUntil\b/u, /\blocalStorage\b/u, /\bindexedDB\b/u]) {
        expect(`${path}: ${re} ${re.test(text)}`).toBe(`${path}: ${re} false`);
      }
    }
  });
});
