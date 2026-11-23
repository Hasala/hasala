import { afterEach, beforeEach, describe, expect, test } from 'bun:test';
import type { postJson, postWithTurnstile, renderTurnstile } from './api';

interface Api {
  postJson: typeof postJson;
  postWithTurnstile: typeof postWithTurnstile;
  renderTurnstile: typeof renderTurnstile;
}
interface FakeScript { dataset: Record<string, string>; src?: string; removed?: boolean; fail?: () => void; remove: () => void; addEventListener: (type: string, fn: () => void) => void }
interface Callbacks { callback: (token: string) => void; 'expired-callback': () => void }

const globals = globalThis as unknown as Record<string, unknown>;
const saved = { window: globals.window, document: globals.document, fetch: globals.fetch };
afterEach(() => {
  globals.window = saved.window;
  globals.document = saved.document;
  globals.fetch = saved.fetch;
});

const loads = { count: 0 };
const loadApi = async (): Promise<Api> => {
  loads.count += 1;
  const loaded: unknown = await import(`./api.ts?turnstile=${loads.count}`);
  return loaded as Api;
};

function fakeTurnstile() {
  const turnstile = {
    opts: undefined as unknown as Callbacks,
    renders: 0,
    resets: [] as string[],
    removes: [] as string[],
    render(el: { childElementCount: number }, opts: Callbacks) {
      el.childElementCount = 1;
      turnstile.opts = opts;
      turnstile.renders += 1;
      return `widget-${turnstile.renders}`;
    },
    reset: (id: string) => turnstile.resets.push(id),
    remove: (id: string) => turnstile.removes.push(id),
  };
  return turnstile;
}

function page(turnstile?: ReturnType<typeof fakeTurnstile>) {
  const scripts: FakeScript[] = [];
  const win: Record<string, unknown> = { turnstile };
  globals.window = win;
  globals.document = {
    createElement: () => {
      const script: FakeScript = {
        dataset: {},
        remove: () => (script.removed = true),
        addEventListener: (type, fn) => {
          if (type === 'error') {script.fail = fn;}
        },
      };
      return script;
    },
    head: { append: (script: FakeScript) => scripts.push(script) },
    addEventListener: () => {},
  };
  const form = { querySelector: () => ({ dataset: { sitekey: 'synthetic-site-key' }, childElementCount: 0 }) } as unknown as HTMLFormElement;
  return { scripts, win, form };
}

const PENDING = 'pending';
const state = <T>(promise: Promise<T>) => Promise.race([promise, 
    new Promise<typeof PENDING>((resolve) => {
      setTimeout(() => {
        resolve(PENDING);
      }, 5);
    }),
  ]);

describe('renderTurnstile', () => {
  test('a form with no widget needs no token', async () => {
    const { renderTurnstile } = await loadApi();
    page();
    const form = { querySelector: () => null } as unknown as HTMLFormElement;
    const gate = renderTurnstile(form, 'waitlist', new AbortController().signal);
    expect(await gate.check()).toEqual({ state: 'off' });
    gate.reset();
  });

  test('a submit before the token waits for it', async () => {
    const { renderTurnstile } = await loadApi();
    const turnstile = fakeTurnstile();
    const gate = renderTurnstile(page(turnstile).form, 'waitlist', new AbortController().signal);
    const check = gate.check();
    expect(await state(check)).toBe(PENDING);
    turnstile.opts.callback('token-1');
    expect(await check).toEqual({ state: 'ready', token: 'token-1' });
  });

  test('a retry right after a reset waits for a new token', async () => {
    const { renderTurnstile } = await loadApi();
    const turnstile = fakeTurnstile();
    const gate = renderTurnstile(page(turnstile).form, 'waitlist', new AbortController().signal);
    turnstile.opts.callback('token-1');
    expect(await gate.check()).toEqual({ state: 'ready', token: 'token-1' });
    gate.reset();
    expect(turnstile.resets).toEqual(['widget-1']);
    const retry = gate.check();
    expect(await state(retry)).toBe(PENDING);
    turnstile.opts.callback('token-2');
    expect(await retry).toEqual({ state: 'ready', token: 'token-2' });
  });

  test('an expired token is not offered', async () => {
    const { renderTurnstile } = await loadApi();
    const turnstile = fakeTurnstile();
    const gate = renderTurnstile(page(turnstile).form, 'waitlist', new AbortController().signal);
    turnstile.opts.callback('token-1');
    turnstile.opts['expired-callback']();
    expect(await state(gate.check())).toBe(PENDING);
  });

  test('no token in time is reported as missing', async () => {
    const { renderTurnstile } = await loadApi();
    const gate = renderTurnstile(page(fakeTurnstile()).form, 'waitlist', new AbortController().signal, 1);
    expect(await gate.check()).toEqual({ state: 'missing' });
  });

  test('a script that cannot load is missing at once, and the next check loads it again', async () => {
    const { renderTurnstile } = await loadApi();
    const { scripts, win, form } = page();
    const gate = renderTurnstile(form, 'waitlist', new AbortController().signal);
    expect(scripts.length).toBe(1);
    const first = gate.check();
    expect(await state(first)).toBe(PENDING);
    scripts[0].fail?.();
    expect(await first).toEqual({ state: 'missing' });
    expect(scripts[0].removed).toBe(true);

    const second = gate.check();
    expect(scripts.length).toBe(2);
    const turnstile = fakeTurnstile();
    win.turnstile = turnstile;
    (win.hasalaTurnstileReady as () => void)();
    expect(turnstile.renders).toBe(1);
    turnstile.opts.callback('token-1');
    expect(await second).toEqual({ state: 'ready', token: 'token-1' });
  });

  test('a page swap removes the widget once and a late reset does not touch it', async () => {
    const { renderTurnstile } = await loadApi();
    const turnstile = fakeTurnstile();
    const ctrl = new AbortController();
    const gate = renderTurnstile(page(turnstile).form, 'waitlist', ctrl.signal);
    const pending = gate.check();
    ctrl.abort();
    expect(turnstile.removes).toEqual(['widget-1']);
    expect(await pending).toEqual({ state: 'missing' });
    gate.reset();
    expect(turnstile.resets).toEqual([]);
    expect(await gate.check()).toEqual({ state: 'missing' });
  });
});

const noAnswer = (signal?: AbortSignal | null) =>
  new Promise<never>((_resolve, reject) => {
    signal?.addEventListener('abort', () => {
      reject(signal.reason);
    });
  });

const answering = (sent: unknown[]) =>
  ((_url: string, init: RequestInit) => {
    sent.push(JSON.parse(String(init.body)));
    return Promise.resolve(new Response('{}', { status: 202 }));
  }) as unknown as typeof fetch;

describe('postJson', () => {
  const URL = 'https://api.example/api/v1/waitlist/confirm';
  const realTimeout = AbortSignal.timeout;
  const wait = { ms: 0, expire: (): void => {} };

  beforeEach(() => {
    const stop = new AbortController();
    wait.ms = 0;
    wait.expire = () => {
      stop.abort(new DOMException('The operation timed out.', 'TimeoutError'));
    };
    AbortSignal.timeout = (ms: number) => {
      wait.ms = ms;
      return stop.signal;
    };
  });
  afterEach(() => {
    AbortSignal.timeout = realTimeout;
  });

  test('a request that gets no answer stops waiting and reads as a network failure', async () => {
    const { postJson } = await loadApi();
    globals.fetch = ((_u: string, init: RequestInit) => noAnswer(init.signal)) as unknown as typeof fetch;
    const answer = postJson(URL, { token: 't' });
    expect(await state(answer)).toBe(PENDING);
    wait.expire();
    expect(await state(answer)).toEqual({ status: 0, error: 'network', data: {}, retryAfter: 0 });
  });

  test('it waits for 20 seconds', async () => {
    const { postJson } = await loadApi();
    globals.fetch = (() => Promise.resolve(new Response('{}', { status: 200 }))) as unknown as typeof fetch;
    await postJson(URL, { token: 't' });
    expect(wait.ms).toBe(20_000);
  });

  test('an answer whose body never ends still counts by its status', async () => {
    const { postJson } = await loadApi();
    globals.fetch = ((_u: string, init: RequestInit) => Promise.resolve({ status: 200, headers: new Headers(), json: () => noAnswer(init.signal) })) as unknown as typeof fetch;
    const answer = postJson(URL, { token: 't' });
    await Bun.sleep(1);
    wait.expire();
    expect(await state(answer)).toEqual({ status: 200, error: '', data: {}, retryAfter: 0 });
  });

  test('an answer inside the wait counts', async () => {
    const { postJson } = await loadApi();
    globals.fetch = (() => Promise.resolve(new Response('{"status":"confirmed"}', { status: 200 }))) as unknown as typeof fetch;
    expect(await postJson(URL, { token: 't' })).toEqual({ status: 200, error: '', data: { status: 'confirmed' }, retryAfter: 0 });
  });

  test('a network failure inside the wait reads the same', async () => {
    const { postJson } = await loadApi();
    globals.fetch = (() => Promise.reject(new TypeError('failed to fetch'))) as unknown as typeof fetch;
    const answer = await postJson(URL, { token: 't' });
    expect(answer.status).toBe(0);
  });

  test('a browser with no timed signal still sends the request', async () => {
    const { postJson } = await loadApi();
    (AbortSignal as unknown as Record<string, unknown>).timeout = undefined;
    globals.fetch = (() => Promise.resolve(new Response('{}', { status: 200 }))) as unknown as typeof fetch;
    const answer = await postJson(URL, { token: 't' });
    expect(answer.status).toBe(200);
  });
});

describe('postWithTurnstile', () => {
  test('with no token nothing is sent, and the answer is the refusal the form already shows', async () => {
    const { postWithTurnstile } = await loadApi();
    const sent: unknown[] = [];
    globals.fetch = answering(sent);
    const answer = await postWithTurnstile('https://api.example/api/v1/waitlist', { email: 'a@example.com' }, { check: () => Promise.resolve({ state: 'missing' }), reset: () => {} });
    expect(sent).toEqual([]);
    expect(answer).toEqual({ status: 403, error: 'turnstile_failed', data: {}, retryAfter: 0 });
  });

  test('a token travels with the body', async () => {
    const { postWithTurnstile } = await loadApi();
    const sent: unknown[] = [];
    globals.fetch = answering(sent);
    await postWithTurnstile('https://api.example/api/v1/waitlist', { email: 'a@example.com' }, { check: () => Promise.resolve({ state: 'ready', token: 'token-1' }), reset: () => {} });
    expect(sent).toEqual([{ email: 'a@example.com', turnstileToken: 'token-1' }]);
  });

  test('a form with no widget sends no token field', async () => {
    const { postWithTurnstile } = await loadApi();
    const sent: unknown[] = [];
    globals.fetch = answering(sent);
    await postWithTurnstile('https://api.example/api/v1/waitlist', { email: 'a@example.com' }, { check: () => Promise.resolve({ state: 'off' }), reset: () => {} });
    expect(sent).toEqual([{ email: 'a@example.com' }]);
  });
});
