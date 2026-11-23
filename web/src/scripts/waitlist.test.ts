import { afterEach, describe, expect, test } from 'bun:test';
import { initWaitlist } from './waitlist';

type Handler = (event: Record<string, unknown>) => unknown;

const globals = globalThis as unknown as Record<string, unknown>;
const saved = Object.fromEntries(
  ['window', 'document', 'history', 'location', 'fetch', 'requestAnimationFrame', 'navigator'].map(
    (key) => [key, globals[key]],
  ),
);
afterEach(() => {
  for (const [key, value] of Object.entries(saved)) {
    globals[key] = value;
  }
});

class El {
  hidden = false;
  disabled = false;
  readOnly = false;
  noValidate = false;
  value = '';
  textContent = '';
  offsetWidth = 200;
  focused = 0;
  style: Record<string, string> = {};
  dataset: Record<string, string> = {};
  elements = { namedItem: (_: string): unknown => null };
  activeElement: unknown = null;
  private attrs = new Map<string, string>();
  private listeners = new Map<string, { fn: Handler; signal?: AbortSignal }[]>();
  private parts = new Map<string, unknown>();
  private lists = new Map<string, unknown[]>();

  with(selector: string, part: unknown) {
    this.parts.set(selector, part);
    return this;
  }
  withAll(selector: string, parts: unknown[]) {
    this.lists.set(selector, parts);
    return this;
  }
  querySelector(selector: string) {
    return this.parts.get(selector) ?? null;
  }
  querySelectorAll(selector: string) {
    return this.lists.get(selector) ?? [];
  }
  getElementById() {
    return new El();
  }
  createElement() {
    return new El();
  }
  addEventListener(type: string, fn: Handler, opts?: { signal?: AbortSignal }) {
    this.listeners.set(type, [...(this.listeners.get(type) ?? []), { fn, signal: opts?.signal }]);
  }
  fire(type: string, event: Record<string, unknown> = {}) {
    const live = (this.listeners.get(type) ?? []).filter((listener) => !listener.signal?.aborted);
    return Promise.all(live.map((listener) => listener.fn({ preventDefault: () => {}, ...event })));
  }
  setAttribute(name: string, value: string) {
    this.attrs.set(name, value);
  }
  removeAttribute(name: string) {
    this.attrs.delete(name);
  }
  getAttribute(name: string) {
    return this.attrs.get(name) ?? null;
  }
  toggleAttribute(name: string, on: boolean) {
    if (on) {
      this.attrs.set(name, '');
    } else {
      this.attrs.delete(name);
    }
  }
  focus() {
    this.focused += 1;
  }
  scrollIntoView() {}
  contains() {
    return false;
  }
  append() {}
  requestSubmit() {}
}

function field() {
  return new El().with('.field__error', new El().with('span', new El()));
}

const allowCopy = () => {
  globals.navigator = { clipboard: { writeText: async () => {} } };
};

const refuseCopy = () => {
  globals.navigator = {
    clipboard: {
      writeText: () =>
        Promise.reject(new DOMException('Write permission denied', 'NotAllowedError')),
    },
  };
};

function start(arrival: { hash?: string; bank?: string } = {}) {
  allowCopy();
  const email = new El();
  const bank = new El();
  const other = new El();
  const honeypot = new El();
  bank.value = arrival.bank ?? '';
  const otherField = field();
  otherField.hidden = true;
  const status = new El();
  const label = new El();
  const submit = new El().with('.wl-submit__label', label).with('.spinner', new El());
  const named: Record<string, El> = {
    'wl-email': email,
    'wl-bank': bank,
    'wl-other': other,
    'wl-website': honeypot,
  };
  const form = new El()
    .with('[data-field="email"]', field())
    .with('[data-field="bank"]', field())
    .with('[data-field="other"]', otherField)
    .with('.wl-submit', submit)
    .with('.wl-status', status);
  form.elements = { namedItem: (name: string) => named[name] };
  const done = new El().with('[data-done-bank]', new El()).with('#wl-done-title', new El());
  done.hidden = true;
  const root = new El().with('[data-waitlist-form]', form).with('.wl-done', done);
  root.dataset = { state: 'default', api: 'https://api.test' };
  const cta = new El();
  const copyText = new El();
  copyText.textContent = 'Copy link for a friend';
  const copy = new El().with('span', copyText);
  copy.dataset = { copy: 'https://hasala.test/#invite' };
  const document = new El()
    .with('[data-waitlist]', root)
    .withAll('[data-copy]', [copy])
    .withAll('a[href="#invite"], a[href="/#invite"]', [cta]);
  const timers = new Map<number, () => void>();
  let nextTimer = 1;
  const replaced: string[] = [];
  const location = { hash: arrival.hash ?? '', href: '' };
  globals.document = document;
  globals.location = location;
  globals.history = {
    state: null,
    replaceState: (_: unknown, __: string, url: string) => {
      replaced.push(url);
      location.hash = url;
    },
  };
  globals.requestAnimationFrame = () => 0;
  globals.window = {
    location,
    setTimeout: (fn: () => void) => {
      timers.set(nextTimer, fn);
      nextTimer += 1;
      return nextTimer - 1;
    },
    clearTimeout: (id: number) => timers.delete(id),
  };
  initWaitlist();
  const runTimers = () => [...timers.values()].forEach((fn) => fn());
  const send = () => {
    email.value = 'person@example.test';
    bank.value = 'dib';
    return form.fire('submit');
  };
  return {
    document,
    root,
    form,
    done,
    email,
    bank,
    other,
    otherField,
    status,
    submit,
    cta,
    copy,
    copyText,
    timers,
    runTimers,
    replaced,
    location,
    send,
  };
}

function holdFetch() {
  const held: { answer: (response: Response) => void } = { answer: () => {} };
  globals.fetch = () =>
    new Promise<Response>((resolve) => {
      held.answer = resolve;
    });
  return (status: number, body = '{}') => held.answer(new Response(body, { status }));
}

const tick = () => Bun.sleep(1);

describe('work that ends with the page', () => {
  test('pressing a request button twice leaves one focus waiting', () => {
    const view = start();
    view.cta.fire('click');
    view.cta.fire('click');
    expect(view.timers.size).toBe(1);
    view.runTimers();
    expect(view.email.focused).toBe(1);
  });

  test('a page swap drops the focus a press left waiting', () => {
    const view = start();
    view.cta.fire('click');
    view.document.fire('astro:before-swap');
    expect(view.timers.size).toBe(0);
  });

  test('a page swap drops the focus an arrival left waiting', () => {
    const view = start({ hash: '#invite' });
    expect(view.timers.size).toBe(1);
    view.document.fire('astro:before-swap');
    expect(view.timers.size).toBe(0);
  });

  test('pressing copy twice leaves one restore waiting, and the label comes back', async () => {
    const view = start();
    await view.copy.fire('click');
    await view.copy.fire('click');
    expect(view.timers.size).toBe(1);
    view.runTimers();
    expect(view.copyText.textContent).toBe('Copy link for a friend');
  });

  test('a page swap drops the copy restore', async () => {
    const view = start();
    await view.copy.fire('click');
    view.document.fire('astro:before-swap');
    expect(view.timers.size).toBe(0);
  });

  test('a page swap during a send drops the still-trying note', async () => {
    const view = start();
    holdFetch();
    view.send();
    await tick();
    expect(view.timers.size).toBe(1);
    view.document.fire('astro:before-swap');
    expect(view.timers.size).toBe(0);
  });

  test('an accepted answer after a page swap leaves the old form alone', async () => {
    const view = start();
    const reply = holdFetch();
    const sending = view.send();
    await tick();
    view.document.fire('astro:before-swap');
    reply(202);
    await sending;
    expect(view.done.hidden).toBe(true);
    expect(view.form.hidden).toBe(false);
    expect(view.root.dataset.state).toBe('default');
  });

  test('a refused answer after a page swap leaves the old form alone', async () => {
    const view = start();
    const reply = holdFetch();
    const sending = view.send();
    await tick();
    view.document.fire('astro:before-swap');
    reply(400, '{"error":"bad_email"}');
    await sending;
    expect(view.root.dataset.state).toBe('default');
    expect(view.email.getAttribute('aria-invalid')).toBeNull();
  });

  test('an accepted answer on the same page shows the done card and clears the note', async () => {
    const view = start();
    const reply = holdFetch();
    const sending = view.send();
    await tick();
    reply(202);
    await sending;
    expect(view.done.hidden).toBe(false);
    expect(view.form.hidden).toBe(true);
    expect(view.root.dataset.state).toBe('success');
    expect(view.timers.size).toBe(0);
  });
});

describe('a copy the browser refuses', () => {
  const link = 'https://hasala.test/#invite';

  test('the link stays on the button with no restore waiting', async () => {
    const view = start();
    refuseCopy();
    await view.copy.fire('click');
    expect(view.copyText.textContent).toBe(link);
    expect(view.timers.size).toBe(0);
    view.runTimers();
    expect(view.copyText.textContent).toBe(link);
  });

  test('a browser with no clipboard keeps the link on the button', async () => {
    const view = start();
    globals.navigator = {};
    await view.copy.fire('click');
    expect(view.copyText.textContent).toBe(link);
    expect(view.timers.size).toBe(0);
  });

  test('a refusal right after a copy that worked drops the waiting restore', async () => {
    const view = start();
    await view.copy.fire('click');
    expect(view.copyText.textContent).toBe('Copied');
    expect(view.timers.size).toBe(1);
    refuseCopy();
    await view.copy.fire('click');
    expect(view.timers.size).toBe(0);
    view.runTimers();
    expect(view.copyText.textContent).toBe(link);
  });

  test('a copy that works after a refusal brings the label back', async () => {
    const view = start();
    refuseCopy();
    await view.copy.fire('click');
    allowCopy();
    await view.copy.fire('click');
    expect(view.copyText.textContent).toBe('Copied');
    expect(view.timers.size).toBe(1);
    view.runTimers();
    expect(view.copyText.textContent).toBe('Copy link for a friend');
  });
});

describe('the invite hash', () => {
  test('a press on a request button leaves no hash for a later reload', () => {
    const view = start();
    view.cta.fire('click');
    expect(view.replaced).toEqual([]);
    expect(view.location.hash).toBe('');
    view.runTimers();
    expect(view.email.focused).toBe(1);
    const reloaded = start({ hash: view.location.hash });
    expect(reloaded.timers.size).toBe(0);
  });

  test('a link that arrives with the hash still focuses Email', () => {
    const view = start({ hash: '#invite' });
    view.runTimers();
    expect(view.email.focused).toBe(1);
  });
});

describe('a restored form', () => {
  test('a select restored to Another bank shows Which one?', () => {
    expect(start({ bank: 'other' }).otherField.hidden).toBe(false);
  });

  test('a select restored to a listed bank keeps Which one? hidden', () => {
    expect(start({ bank: 'dib' }).otherField.hidden).toBe(true);
  });

  test('an untouched select keeps Which one? hidden', () => {
    expect(start().otherField.hidden).toBe(true);
  });
});

describe('the coin after a failed send', () => {
  test('a field error fixed before a failed send does not leave the coin in error', async () => {
    const view = start();
    view.email.value = 'not-an-address';
    view.bank.value = 'dib';
    await view.form.fire('submit');
    expect(view.root.dataset.state).toBe('error');
    const reply = holdFetch();
    const sending = view.send();
    await tick();
    expect(view.root.dataset.state).toBe('default');
    reply(500);
    await sending;
    expect(view.root.dataset.state).toBe('default');
    expect(view.status.dataset.tone).toBe('error');
    expect(view.submit.disabled).toBe(false);
  });
});
