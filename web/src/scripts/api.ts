import { pageTimer } from './page';

export interface ApiAnswer {
  status: number;
  error: string;
  data: Record<string, unknown>;
  retryAfter: number;
}

const API_WAIT_MS = 20_000;

export async function postJson(url: string, body: unknown): Promise<ApiAnswer> {
  try {
    const res = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
      body: JSON.stringify(body),
      credentials: 'omit',
      mode: 'cors',
      referrerPolicy: 'no-referrer',
      cache: 'no-store',
      signal: AbortSignal.timeout?.(API_WAIT_MS),
    });
    const data: Record<string, unknown> = await res.json().catch(() => ({}));
    const retryAfter = Number.parseInt(res.headers.get('Retry-After') ?? '', 10);
    return {
      status: res.status,
      error: typeof data.error === 'string' ? data.error : '',
      data,
      retryAfter: Number.isFinite(retryAfter) && retryAfter > 0 ? retryAfter : 0,
    };
  } catch {
    return { status: 0, error: 'network', data: {}, retryAfter: 0 };
  }
}

export function waitText(seconds: number): string {
  if (!(seconds > 0)) {
    return 'a few minutes';
  }
  if (seconds <= 90) {
    return 'a minute';
  }
  const min = Math.ceil(seconds / 60);
  if (min < 60) {
    return `${min} minutes`;
  }
  const hours = Math.ceil(min / 60);
  return hours === 1 ? 'an hour' : `${hours} hours`;
}

export function bankText(value: string): string | null {
  const text = value.trim().replaceAll(/\s+/gu, ' ');
  if (!text) {
    return '';
  }
  return [...text].length <= 64 && /^[\p{L}\p{M}\p{Nd} &.'()/-]+$/u.test(text) ? text : null;
}

interface Turnstile {
  render: (el: HTMLElement, opts: Record<string, unknown>) => string;
  reset: (id: string) => void;
  remove: (id: string) => void;
}
declare global {
  var turnstile: Turnstile | undefined;
  var hasalaTurnstileReady: (() => void) | undefined;
}
const waiting: ((loaded: boolean) => void)[] = [];
let requested = false;
let keepsTag = false;
const settleLoad = (loaded: boolean): void => waiting.splice(0).forEach((waiter) => waiter(loaded));

function loadTurnstile(): void {
  if (requested) {
    return;
  }
  requested = true;
  globalThis.hasalaTurnstileReady = () => settleLoad(true);
  const script = document.createElement('script');
  script.src =
    'https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit&onload=hasalaTurnstileReady';
  script.async = true;
  script.dataset.astroTransitionPersist = 'turnstile';
  script.dataset.astroExec = '';
  script.addEventListener('error', () => {
    script.remove();
    requested = false;
    settleLoad(false);
  });
  document.head.append(script);
  if (keepsTag) {
    return;
  }
  keepsTag = true;
  document.addEventListener('astro:before-swap', (event) => {
    const keep = event.newDocument.createElement('meta');
    keep.dataset.astroTransitionPersist = 'turnstile';
    event.newDocument.head.append(keep);
  });
}

export type TurnstileCheck =
  | { state: 'off' }
  | { state: 'ready'; token: string }
  | { state: 'missing' };
export interface TurnstileGate {
  check: () => Promise<TurnstileCheck>;
  reset: () => void;
}
const MISSING: TurnstileCheck = { state: 'missing' };

export function renderTurnstile(
  form: HTMLFormElement,
  action: 'waitlist' | 'bank_request',
  signal: AbortSignal,
  waitMs = 15_000,
): TurnstileGate {
  const box = form.querySelector<HTMLElement>('.cf-turnstile');
  if (!box?.dataset.sitekey) {
    return { check: () => Promise.resolve({ state: 'off' }), reset: () => {} };
  }
  let id = '';
  let token = '';
  const waiters = new Set<(check: TurnstileCheck) => void>();
  const settle = (check: TurnstileCheck): void => waiters.forEach((waiter) => waiter(check));
  const give = (fresh: string): void => {
    token = fresh;
    if (fresh) {
      settle({ state: 'ready', token: fresh });
    }
  };
  const draw = (): void => {
    if (signal.aborted || id || !globalThis.turnstile || box.childElementCount) {
      return;
    }
    id = globalThis.turnstile.render(box, {
      sitekey: box.dataset.sitekey,
      action,
      theme: 'light',
      size: 'flexible',
      appearance: 'interaction-only',
      callback: give,
      'expired-callback': () => give(''),
    });
  };
  const load = (): void => {
    if (globalThis.turnstile) {
      draw();
    } else {
      waiting.push((loaded) => (loaded ? draw() : settle(MISSING)));
      loadTurnstile();
    }
  };
  signal.addEventListener(
    'abort',
    () => {
      if (id) {
        globalThis.turnstile?.remove(id);
      }
      id = '';
      token = '';
      settle(MISSING);
    },
    { once: true },
  );
  load();
  return {
    check: () =>
      new Promise((resolve) => {
        if (signal.aborted) {
          resolve(MISSING);
          return;
        }
        if (token) {
          resolve({ state: 'ready', token });
          return;
        }
        const deadline = pageTimer(signal);
        const finish = (check: TurnstileCheck): void => {
          deadline.clear();
          waiters.delete(finish);
          resolve(check);
        };
        deadline.set(() => finish(MISSING), waitMs);
        waiters.add(finish);
        if (!id) {
          load();
        }
      }),
    reset: () => {
      token = '';
      if (id) {
        globalThis.turnstile?.reset(id);
      }
    },
  };
}

export async function postWithTurnstile(
  url: string,
  body: Record<string, string>,
  turnstile: TurnstileGate,
): Promise<ApiAnswer> {
  const check = await turnstile.check();
  if (check.state === 'missing') {
    return { status: 403, error: 'turnstile_failed', data: {}, retryAfter: 0 };
  }
  return postJson(url, check.state === 'ready' ? { ...body, turnstileToken: check.token } : body);
}
