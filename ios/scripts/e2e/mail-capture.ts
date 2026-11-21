import { mkdirSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";

function arg(name: string, fallback?: string): string {
  const i = Bun.argv.indexOf(`--${name}`);
  if (i >= 0 && i + 1 < Bun.argv.length) return Bun.argv[i + 1];
  if (fallback !== undefined) return fallback;
  console.error(`mail-capture: --${name} is required`);
  process.exit(2);
}

const port = Number(arg("port"));
const dir = arg("dir");
const token = arg("token", "e2e");
if (!Number.isInteger(port) || port <= 0 || port > 65535) {
  console.error("mail-capture: --port must be a TCP port");
  process.exit(2);
}
mkdirSync(dir, { recursive: true });

const SEND = /^\/client\/v4\/accounts\/[0-9a-f]{32}\/email\/sending\/send$/;
let count = 0;

function failure(status: number, code: number, message: string): Response {
  return Response.json({ success: false, errors: [{ code, message }], messages: [], result: null }, { status });
}

const server = Bun.serve({
  hostname: "127.0.0.1",
  port,
  async fetch(req) {
    const url = new URL(req.url);
    if (req.method === "GET" && url.pathname === "/healthz") return new Response("ok\n");
    if (!SEND.test(url.pathname)) return failure(404, 7003, "No route for that URI");
    if (req.method !== "POST") return failure(405, 7001, "Method not allowed");
    if (req.headers.get("authorization") !== `Bearer ${token}`) {
      return failure(401, 10000, "Authentication error");
    }
    let body: { to?: unknown; from?: unknown; subject?: unknown; text?: unknown };
    try {
      body = await req.json();
    } catch {
      return failure(400, 10001, "Invalid JSON");
    }
    const { to, from, subject, text } = body;
    if (typeof to !== "string" || typeof from !== "string" || typeof subject !== "string" || typeof text !== "string") {
      return failure(400, 10001, "to, from, subject and text are required");
    }
    count += 1;
    const id = `e2e-${count}`;
    const name = String(count).padStart(5, "0");
    const record = { to, from, subject, text, received_at: new Date().toISOString() };
    const tmp = join(dir, `.${name}.tmp`);
    writeFileSync(tmp, JSON.stringify(record, null, 2) + "\n");
    renameSync(tmp, join(dir, `${name}.json`));
    console.log(`mail-capture: ${name} to=${to} subject=${JSON.stringify(subject)}`);
    return Response.json({
      success: true,
      errors: [],
      messages: [],
      result: { delivered: [to], permanent_bounces: [], queued: [], message_id: id },
    });
  },
});

console.log(`mail-capture: listening on http://127.0.0.1:${server.port}, writing to ${dir}`);
