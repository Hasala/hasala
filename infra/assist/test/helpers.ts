import worker from "../src/index";
import type { Env } from "../src/index";

export const OK_ANSWER = {
  model: "clef",
  answers: {
    category: {
      type: "choice",
      choice: "dining",
      probabilities: { groceries: 0.0095, dining: 0.9725, unknown: 0.012 },
      confidence: 0.928,
    },
  },
  usage: { prompt_tokens: 10, completion_tokens: 1 },
};

export const BODY = {
  subject: "CAFE EXAMPLE JBR",
  categories: [
    { id: "groceries", name: "Groceries", hint: "supermarkets and grocery stores" },
    { id: "dining", name: "Dining", hint: null },
  ],
};

export interface Fakes {
  env: Env;
  aiCalls: { model: string; input: unknown; options: unknown }[];
  limitCalls: { binding: string; key: string }[];
}

export function fakes(
  opts: {
    answer?: unknown;
    aiThrows?: boolean;
    perIp?: boolean;
    global?: boolean;
    refused?: string;
    gateway?: string;
  } = {},
): Fakes {
  const aiCalls: Fakes["aiCalls"] = [];
  const limitCalls: Fakes["limitCalls"] = [];
  const env: Env = {
    AI: {
      run(model, input, options) {
        aiCalls.push({ model, input, options });
        if (opts.aiThrows) {return Promise.reject(new Error("model down"));}
        return Promise.resolve(opts.answer === undefined ? OK_ANSWER : opts.answer);
      },
    },
    PER_IP: {
      limit({ key }) {
        limitCalls.push({ binding: "PER_IP", key });
        return Promise.resolve({ success: opts.perIp ?? true });
      },
    },
    GLOBAL: {
      limit({ key }) {
        limitCalls.push({ binding: "GLOBAL", key });
        return Promise.resolve({ success: opts.global ?? true });
      },
    },
    REFUSED_CLIENTS: opts.refused ?? "",
    AI_GATEWAY: opts.gateway ?? "hasala-assist",
  };
  return { env, aiCalls, limitCalls };
}

export function request(
  body: unknown,
  opts: { headers?: Record<string, string | null>; method?: string; path?: string; raw?: string } = {},
): Request {
  const headers = new Headers({
    "hasala-client": "ios/1.4.0",
    "content-type": "application/json",
    "cf-connecting-ip": "192.0.2.10",
  });
  for (const [name, value] of Object.entries(opts.headers ?? {})) {
    if (value === null) {headers.delete(name);}
    else {headers.set(name, value);}
  }
  const method = opts.method ?? "POST";
  const init: RequestInit = { method, headers };
  if (method !== "GET" && method !== "HEAD") {init.body = opts.raw ?? JSON.stringify(body);}
  return new Request(`https://assist.hasala.app${opts.path ?? "/v1/category"}`, init);
}

export function need<T>(value: T | undefined): T {
  if (value === undefined) {throw new Error("the value is missing");}
  return value;
}

export interface ReplyBody {
  error?: string;
  tag?: string;
  choice?: string;
  probabilities?: Record<string, number>;
}

export interface Reply {
  status: number;
  body: ReplyBody;
  res: Response;
}

export async function call(fake: Fakes, req: Request): Promise<Reply> {
  const res = await worker.fetch(req, fake.env);
  const text = await res.text();
  return { status: res.status, body: JSON.parse(text) as ReplyBody, res };
}
