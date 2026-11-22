import {
  MAX_BODY_BYTES,
  MODEL,
  clefBody,
  mapAnswer,
  parseSuggestion,
  refusedClients,
  validClient,
} from './contract';

export interface AiBinding {
  run(
    model: string,
    input: unknown,
    options: { gateway: { id: string; skipCache: true; collectLog: false } },
  ): Promise<unknown>;
}

export interface RateLimiter {
  limit(options: { key: string }): Promise<{ success: boolean }>;
}

export interface Env {
  AI: AiBinding;
  PER_IP: RateLimiter;
  GLOBAL: RateLimiter;
  REFUSED_CLIENTS?: string;
  AI_GATEWAY?: string;
}

const PATH = '/v1/category';
const HTTP = {
  ok: 200,
  badRequest: 400,
  forbidden: 403,
  notFound: 404,
  methodNotAllowed: 405,
  tooLarge: 413,
  rateLimited: 429,
  badAnswer: 502,
  unavailable: 503,
} as const;
const IPV6_GROUPS = 8;
const IPV6_PREFIX_GROUPS = 4;
const MODEL_FAILED = Symbol('model failed');

function json(status: number, body: unknown, extra: Record<string, string> = {}): Response {
  return Response.json(body, {
    status,
    headers: {
      'cache-control': 'no-store',
      'content-type': 'application/json',
      ...extra,
    },
  });
}

function refusal(status: number, code: string, extra: Record<string, string> = {}): Response {
  return json(status, { error: code }, extra);
}

function jsonContentType(value: string | null): boolean {
  if (value === null) {
    return false;
  }
  const [type, ...params] = value.split(';').map((part) => part.trim().toLowerCase());
  if (type !== 'application/json') {
    return false;
  }
  return params.every((param) => param === '' || param === 'charset=utf-8');
}

class TooLargeError extends Error {
  override name = 'TooLargeError';
}

async function readCapped(request: Request): Promise<Uint8Array> {
  const declared = request.headers.get('content-length');
  if (declared !== null && (!/^[0-9]+$/u.test(declared) || Number(declared) > MAX_BODY_BYTES)) {
    throw new TooLargeError();
  }
  if (request.body === null) {
    return new Uint8Array(0);
  }
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) {
      break;
    }
    total += value.byteLength;
    if (total > MAX_BODY_BYTES) {
      await reader.cancel();
      throw new TooLargeError();
    }
    chunks.push(value);
  }
  const out = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return out;
}

async function readBody(request: Request): Promise<Uint8Array | Response> {
  try {
    return await readCapped(request);
  } catch (error) {
    if (error instanceof TooLargeError) {
      return refusal(HTTP.tooLarge, 'too_large');
    }
    return refusal(HTTP.badRequest, 'bad_request');
  }
}

function parseJson(bytes: Uint8Array): unknown {
  try {
    return JSON.parse(new TextDecoder('utf-8', { fatal: true, ignoreBOM: false }).decode(bytes));
  } catch {
    return undefined;
  }
}

async function allowed(limiter: RateLimiter, key: string): Promise<boolean> {
  try {
    const { success } = await limiter.limit({ key });
    return success === true;
  } catch {
    return false;
  }
}

export function ipKey(ip: string | null): string {
  const value = (ip ?? '').trim().toLowerCase();
  if (value === '') {
    return 'none';
  }
  if (!value.includes(':')) {
    return value;
  }
  const [, mapped] = /^::ffff:(\d{1,3}(?:\.\d{1,3}){3})$/u.exec(value) ?? [];
  if (mapped !== undefined) {
    return mapped;
  }
  const [first = '', second, ...more] = value.split('::');
  if (more.length > 0) {
    return value;
  }
  const head = first === '' ? [] : first.split(':');
  const tail = second === undefined || second === '' ? [] : second.split(':');
  if (tail.at(-1)?.includes('.')) {
    tail.splice(-1, 1, '0', '0');
  }
  const missing = second === undefined ? 0 : IPV6_GROUPS - head.length - tail.length;
  if (missing < 0) {
    return value;
  }
  const groups = [...head, ...Array.from({ length: missing }, () => '0'), ...tail];
  if (groups.length !== IPV6_GROUPS || !groups.every((group) => /^[0-9a-f]{1,4}$/u.test(group))) {
    return value;
  }
  const prefix = groups
    .slice(0, IPV6_PREFIX_GROUPS)
    .map((group) => group.replace(/^0+(?=.)/u, ''))
    .join(':');
  return `${prefix}::/64`;
}

export async function handle(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  if (url.pathname !== PATH) {
    return refusal(HTTP.notFound, 'not_found');
  }
  if (request.method !== 'POST') {
    return refusal(HTTP.methodNotAllowed, 'method_not_allowed', { allow: 'POST' });
  }

  const client = request.headers.get('hasala-client');
  if (!validClient(client)) {
    return refusal(HTTP.badRequest, 'bad_request');
  }
  if (refusedClients(env.REFUSED_CLIENTS).has(client)) {
    return refusal(HTTP.forbidden, 'client_refused');
  }
  if (!jsonContentType(request.headers.get('content-type'))) {
    return refusal(HTTP.badRequest, 'bad_request');
  }

  const bytes = await readBody(request);
  if (bytes instanceof Response) {
    return bytes;
  }

  const suggestion = parseSuggestion(parseJson(bytes));
  if (suggestion === null) {
    return refusal(HTTP.badRequest, 'bad_request');
  }

  if (!(await allowed(env.PER_IP, ipKey(request.headers.get('cf-connecting-ip'))))) {
    return refusal(HTTP.rateLimited, 'rate_limited');
  }
  if (!(await allowed(env.GLOBAL, 'global'))) {
    return refusal(HTTP.rateLimited, 'rate_limited');
  }

  const gatewayId = (env.AI_GATEWAY ?? '').trim();
  if (gatewayId === '') {
    return refusal(HTTP.unavailable, 'model_unavailable');
  }

  const runModel = async (): Promise<unknown> => {
    try {
      return await env.AI.run(MODEL, clefBody(suggestion), {
        gateway: { id: gatewayId, skipCache: true, collectLog: false },
      });
    } catch {
      return MODEL_FAILED;
    }
  };
  const result = await runModel();
  if (result === MODEL_FAILED) {
    return refusal(HTTP.unavailable, 'model_unavailable');
  }

  const answer = mapAnswer(result, suggestion);
  if (answer === null) {
    return refusal(HTTP.badAnswer, 'bad_model_answer');
  }
  return json(HTTP.ok, answer);
}

const worker = {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      return await handle(request, env);
    } catch {
      return refusal(HTTP.unavailable, 'model_unavailable');
    }
  },
};

export default worker;
