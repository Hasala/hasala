import { afterEach, beforeAll, beforeEach, describe, expect, test } from 'bun:test';

type Fn = (event: Record<string, unknown>) => void;

const globals = globalThis as unknown as Record<string, unknown>;
const saved = Object.fromEntries(
  [
    'document',
    'window',
    'matchMedia',
    'getComputedStyle',
    'DOMMatrixReadOnly',
    'IntersectionObserver',
  ].map((key) => [key, globals[key]]),
);
const reduce = { matches: false };
const page: { initReview: () => void; loads: Fn[] } = { initReview: () => {}, loads: [] };
function DOMMatrixReadOnly(): object {
  return { e: 0, f: 0 };
}
const demoTimer = (task: () => void, ms: number): number => {
  if (ms === 300) {
    task();
  }
  return 1;
};

class FakeAnimation {
  done = false;
  finished: Promise<void>;
  private resolve!: () => void;
  private reject!: (reason: unknown) => void;
  private owner: FakeElement;
  constructor(owner: FakeElement) {
    this.owner = owner;
    this.finished = new Promise((resolve, reject) => {
      this.resolve = resolve;
      this.reject = reject;
    });
    void Promise.allSettled([this.finished]);
  }
  finish() {
    if (this.done) {
      return;
    }
    this.done = true;
    this.owner.running = this.owner.running.filter((other) => other !== this);
    this.resolve();
  }
  cancel() {
    if (this.done) {
      return;
    }
    this.done = true;
    this.owner.running = this.owner.running.filter((other) => other !== this);
    this.reject(new DOMException('Aborted', 'AbortError'));
  }
}

class FakeElement {
  style: Record<string, string> = {};
  hidden = false;
  textContent = '';
  clientWidth = 320;
  running: FakeAnimation[] = [];
  parent: FakeElement | null = null;
  private attrs = new Set<string>();
  private handlers = new Map<string, Fn[]>();
  dataset: Record<string, string>;
  children: FakeElement[];
  private tag: string;
  private classes: string[];
  constructor(
    tag: string,
    classes: string[],
    dataset: Record<string, string>,
    children: FakeElement[] = [],
  ) {
    this.tag = tag;
    this.classes = classes;
    this.dataset = dataset;
    this.children = children;
    children.forEach((child) => (child.parent = this));
  }
  private matches(selector: string): boolean {
    return (selector.match(/^[a-z]+|\.[\w-]+|\[[^\]]+\]/gu) ?? []).every((part) => {
      if (part[0] === '.') {
        return this.classes.includes(part.slice(1));
      }
      if (part[0] !== '[') {
        return this.tag === part;
      }
      const [, name = '', value] = /^\[data-([\w-]+)(?:="(.*)")?\]$/u.exec(part) ?? [];
      const key = name.replaceAll(/-(\w)/gu, (_, letter: string) => letter.toUpperCase());
      return value === undefined ? key in this.dataset : this.dataset[key] === value;
    });
  }
  querySelectorAll(selector: string): FakeElement[] {
    return this.children.flatMap((child) => [
      ...(child.matches(selector) ? [child] : []),
      ...child.querySelectorAll(selector),
    ]);
  }
  querySelector(selector: string): FakeElement | null {
    return this.querySelectorAll(selector)[0] ?? null;
  }
  closest(selector: string): FakeElement | null {
    return this.matches(selector) ? this : (this.parent?.closest(selector) ?? null);
  }
  addEventListener(type: string, fn: Fn) {
    this.handlers.set(type, [...(this.handlers.get(type) ?? []), fn]);
  }
  fire(type: string, event: Record<string, unknown> = {}) {
    this.bubble(type, { target: this, preventDefault: () => {}, ...event });
  }
  private bubble(type: string, full: Record<string, unknown>): void {
    this.handlers.get(type)?.forEach((handler) => handler(full));
    this.parent?.bubble(type, full);
  }
  hasAttribute(name: string) {
    return this.attrs.has(name);
  }
  setAttribute(name: string) {
    this.attrs.add(name);
  }
  removeAttribute(name: string) {
    this.attrs.delete(name);
  }
  toggleAttribute(name: string, on: boolean) {
    if (on) {
      this.attrs.add(name);
    } else {
      this.attrs.delete(name);
    }
    return on;
  }
  animate() {
    const animation = new FakeAnimation(this);
    this.running.push(animation);
    return animation;
  }
  getAnimations() {
    return [...this.running];
  }
  setPointerCapture() {}
  focus() {}
}

const el = (classes: string, dataset: Record<string, string> = {}, children: FakeElement[] = []) =>
  new FakeElement('div', classes.split(' ').filter(Boolean), dataset, children);

const DIRS = ['need', 'want', 'save', 'transfer'];

function mount(count = 3) {
  const cards = Array.from({ length: count }, (_, index) =>
    el('rcard', { to: DIRS[index % 4] }, [
      ...DIRS.map((dir) => el(`rcard__tint rcard__tint--${dir}`)),
      el('rcard__merchant'),
      el('rcard__use', { use: '' }),
    ]),
  );
  const done = el('deck__done', { reviewDone: '' });
  const deck = el('deck', {}, [...cards, done]);
  const undo = el('toast__undo', { undo: '' });
  const toast = el('toast', {}, [el('', { toastText: '' }), undo]);
  const live = el('', { reviewLive: '' });
  const restart = el('', { reviewRestart: '' });
  const pills = DIRS.map((dir) => el(`rpill rpill--${dir}`, { sort: dir }));
  const stage = el('', { review: '', total: String(count + 1) }, [
    deck,
    toast,
    live,
    restart,
    ...pills,
  ]);
  const legends = DIRS.map((dir) => el(`dir dir--${dir}`, { sort: dir }));
  const section = new FakeElement('section', [], {}, [stage, ...legends]);
  globals.document = {
    hidden: false,
    querySelector: (selector: string) => (selector === '[data-review]' ? stage : null),
    addEventListener: (type: string, fn: Fn) => type === 'astro:page-load' && page.loads.push(fn),
  };
  page.initReview();

  const position = { x: 0, y: 0 };
  const point = (id: number, time: number) => ({
    pointerId: id,
    clientX: position.x,
    clientY: position.y,
    timeStamp: time,
    pointerType: 'mouse',
  });
  const held = { card: cards[0], time: 0 };
  return {
    section,
    cards,
    deck,
    toast,
    live,
    undo,
    restart,
    left: () => deck.dataset.left,
    legend: (dir: string) => legends[DIRS.indexOf(dir)],
    pill: (dir: string) => pills[DIRS.indexOf(dir)],
    key: (key: string) => deck.fire('keydown', { key }),
    grab(card: FakeElement) {
      held.card = card;
      position.x = 0;
      position.y = 0;
      card.fire('pointerdown', point(1, (held.time += 400)));
    },
    move(x: number, y = 0) {
      position.x = x;
      position.y = y;
      held.card.fire('pointermove', point(1, (held.time += 400)));
    },
    release() {
      held.card.fire('pointerup', point(1, (held.time += 400)));
    },
  };
}

const tick = () => Bun.sleep(1);
async function until(ok: () => boolean) {
  const deadline = Date.now() + 1000;
  while (!ok()) {
    if (Date.now() > deadline) {
      throw new Error('the deck did not settle');
    }
    await Bun.sleep(2);
  }
}
const finishCard = async (card: FakeElement) => {
  card.getAnimations().forEach((animation) => animation.finish());
  await tick();
};

beforeAll(async () => {
  globals.matchMedia = () => reduce;
  ({ initReview: page.initReview } = await import('./review'));
});

beforeEach(() => {
  reduce.matches = false;
  globals.matchMedia = () => reduce;
  page.loads = [];
  globals.window = { setTimeout: () => 1, clearTimeout: () => {} };
  globals.getComputedStyle = () => ({ transform: 'none' });
  globals.DOMMatrixReadOnly = DOMMatrixReadOnly;
});

afterEach(() => {
  for (const [key, value] of Object.entries(saved)) {
    globals[key] = value;
  }
});

describe('the legend chip', () => {
  test('stays lit until a dragged card has gone', async () => {
    const deck = mount();
    deck.grab(deck.cards[0]);
    deck.move(200);
    deck.release();
    expect(deck.legend('need').hasAttribute('data-active')).toBe(true);
    await finishCard(deck.cards[0]);
    await until(() => deck.left() === '2');
    expect(deck.legend('need').hasAttribute('data-active')).toBe(false);
  });

  test('goes out after a committed drag with reduced motion', async () => {
    reduce.matches = true;
    const deck = mount();
    deck.grab(deck.cards[0]);
    deck.move(200);
    deck.release();
    expect(deck.legend('need').hasAttribute('data-active')).toBe(true);
    await finishCard(deck.cards[0]);
    await until(() => deck.left() === '2');
    expect(deck.legend('need').hasAttribute('data-active')).toBe(false);
  });
});

type Deck = ReturnType<typeof mount>;
const SETTLE_MS = 300;
const sortByKey = async (deck: Deck, card: FakeElement, key = 'ArrowRight') => {
  deck.key(key);
  await finishCard(card);
  await finishCard(card);
  await Bun.sleep(SETTLE_MS);
};

describe('while a card is held', () => {
  const presses: [string, (deck: Deck) => void][] = [
    ['an arrow key', (deck) => deck.key('ArrowRight')],
    ['a pill', (deck) => deck.pill('want').fire('click')],
    ['a legend chip', (deck) => deck.legend('want').fire('click')],
    ['Use', (deck) => deck.cards[0].querySelector('[data-use]')?.fire('click')],
  ];

  test.each(presses)('%s does not start a sort', (_name, press) => {
    const deck = mount();
    deck.grab(deck.cards[0]);
    deck.move(30);
    press(deck);
    expect(deck.cards[0].getAnimations()).toEqual([]);
    expect(deck.toast.hasAttribute('data-show')).toBe(false);
  });

  test('a key press leaves the finger on the same card', async () => {
    const deck = mount();
    deck.grab(deck.cards[0]);
    deck.move(30);
    await sortByKey(deck, deck.cards[0]);
    deck.move(60);
    expect(deck.left()).toBe('3');
    expect(deck.cards[0].style.transform).toContain('translate(60px');
    expect(deck.cards[1].style.transform).toBe('');
  });

  test('a key press on the last card cannot break the drag', async () => {
    const deck = mount(1);
    deck.grab(deck.cards[0]);
    deck.move(30);
    await sortByKey(deck, deck.cards[0]);
    expect(() => deck.move(60)).not.toThrow();
    expect(() => deck.move(0)).not.toThrow();
    expect(() => deck.release()).not.toThrow();
    expect(deck.left()).toBe('1');
  });

  test('Undo leaves the held card where it is', async () => {
    const deck = mount();
    await sortByKey(deck, deck.cards[0]);
    expect(deck.left()).toBe('2');
    deck.grab(deck.cards[1]);
    deck.move(30);
    deck.undo.fire('click');
    expect(deck.left()).toBe('2');
    deck.move(60);
    expect(deck.cards[1].style.transform).toContain('translate(60px');
    expect(deck.cards[0].style.transform).toBe('');
  });

  test('a second finger is ignored', () => {
    const deck = mount();
    deck.grab(deck.cards[0]);
    deck.move(30);
    deck.cards[0].fire('pointerdown', { pointerId: 2, clientX: 200, clientY: 0, timeStamp: 1 });
    deck.cards[0].fire('pointermove', { pointerId: 2, clientX: 200, clientY: 0, timeStamp: 2 });
    deck.cards[0].fire('pointerup', { pointerId: 2, clientX: 200, clientY: 0, timeStamp: 3 });
    expect(deck.cards[0].style.transform).toContain('translate(30px');
    expect(deck.cards[0].getAnimations()).toEqual([]);
  });

  test('the drag still commits once after an ignored press', async () => {
    const deck = mount();
    deck.grab(deck.cards[0]);
    deck.move(200);
    deck.key('ArrowLeft');
    deck.release();
    expect(deck.cards[0].getAnimations().length).toBe(1);
    await finishCard(deck.cards[0]);
    await until(() => deck.left() === '2');
    expect(deck.cards[0].style.transform).toBe('');
  });

  test('a short release puts the card back and the keys work again', async () => {
    const deck = mount();
    deck.grab(deck.cards[0]);
    deck.move(30);
    deck.move(30);
    deck.release();
    await Bun.sleep(1);
    deck.cards[0].getAnimations().forEach((animation) => animation.cancel());
    await sortByKey(deck, deck.cards[0]);
    expect(deck.left()).toBe('2');
  });
});

describe('the toast', () => {
  test.each([
    ['Need', 'ArrowRight'],
    ['Want', 'ArrowLeft'],
    ['Save', 'ArrowDown'],
    ['Transfer', 'ArrowUp'],
  ])('names %s and announces it', async (word, key) => {
    const deck = mount();
    deck.key(key);
    await finishCard(deck.cards[0]);
    expect(deck.toast.querySelector('[data-toast-text]')?.textContent).toBe(`Sorted as ${word}`);
    expect(deck.live.textContent).toBe(`Sorted as ${word}. Undo is available.`);
  });
});

describe('while a card is leaving', () => {
  test('a press does not start another sort', async () => {
    const deck = mount();
    deck.key('ArrowRight');
    deck.key('ArrowLeft');
    deck.pill('save').fire('click');
    await finishCard(deck.cards[0]);
    await finishCard(deck.cards[0]);
    await Bun.sleep(SETTLE_MS);
    expect(deck.left()).toBe('2');
  });

  test('a card cannot be grabbed', () => {
    const deck = mount();
    deck.key('ArrowRight');
    deck.grab(deck.cards[0]);
    deck.move(60);
    expect(['', undefined]).toContain(deck.cards[0].style.transform);
  });

  test("Undo during a dragged card's flight puts it back once it has gone", async () => {
    const deck = mount();
    deck.grab(deck.cards[0]);
    deck.move(200);
    deck.release();
    expect(deck.toast.hasAttribute('data-show')).toBe(true);
    deck.undo.fire('click');
    await finishCard(deck.cards[0]);
    await Bun.sleep(SETTLE_MS);
    expect(deck.left()).toBe('3');
    expect(deck.cards[0].dataset.pos).toBe('0');
    expect(deck.toast.hasAttribute('data-show')).toBe(false);
    expect(deck.live.textContent).toBe('Undone.');
  });

  test("Undo during a pressed card's flight puts it back once it has gone", async () => {
    const deck = mount();
    deck.key('ArrowRight');
    await finishCard(deck.cards[0]);
    expect(deck.toast.hasAttribute('data-show')).toBe(true);
    deck.undo.fire('click');
    await finishCard(deck.cards[0]);
    await Bun.sleep(SETTLE_MS);
    expect(deck.left()).toBe('3');
    expect(deck.cards[0].dataset.pos).toBe('0');
  });

  test('Undo during the fade with reduced motion puts the card back', async () => {
    reduce.matches = true;
    const deck = mount();
    deck.key('ArrowRight');
    deck.undo.fire('click');
    await finishCard(deck.cards[0]);
    await tick();
    expect(deck.left()).toBe('3');
    expect(deck.live.textContent).toBe('Undone.');
  });

  test('one Undo takes back one card, and the next sort stays sorted', async () => {
    const deck = mount();
    deck.key('ArrowRight');
    await finishCard(deck.cards[0]);
    deck.undo.fire('click');
    deck.undo.fire('click');
    await finishCard(deck.cards[0]);
    await Bun.sleep(SETTLE_MS);
    expect(deck.left()).toBe('3');
    await sortByKey(deck, deck.cards[0], 'ArrowLeft');
    expect(deck.left()).toBe('2');
  });

  test('Undo after the card has gone still works', async () => {
    const deck = mount();
    await sortByKey(deck, deck.cards[0]);
    deck.undo.fire('click');
    expect(deck.left()).toBe('3');
  });

  test('Undo with nothing sorted does nothing', () => {
    const deck = mount();
    deck.undo.fire('click');
    expect(deck.left()).toBe('3');
    expect(deck.live.textContent).toBe('');
  });
});

describe('Start again', () => {
  test('goes back to the first card with the toast gone', async () => {
    const deck = mount(1);
    await sortByKey(deck, deck.cards[0]);
    expect(deck.left()).toBe('0');
    deck.restart.fire('click');
    expect(deck.left()).toBe('1');
    expect(deck.cards[0].dataset.pos).toBe('0');
    expect(deck.toast.hasAttribute('data-show')).toBe(false);
    expect(deck.live.textContent).toStartWith('Back to the first card');
  });
});

describe('the demo', () => {
  test('hands the card over when it is grabbed mid-lean', async () => {
    const watching: { seen: (entries: { isIntersecting: boolean }[]) => void } = { seen: () => {} };
    class Observer {
      constructor(notify: typeof watching.seen) {
        watching.seen = notify;
      }
      observe() {}
      disconnect() {}
    }
    globals.IntersectionObserver = Observer;
    globals.window = {
      IntersectionObserver: Observer,
      setTimeout: demoTimer,
      clearTimeout: () => {},
    };
    const deck = mount();
    watching.seen([{ isIntersecting: true }]);
    await until(() => deck.cards[0].getAnimations().length > 0);
    deck.grab(deck.cards[0]);
    await tick();
    expect(deck.cards[0].getAnimations()).toEqual([]);
    deck.move(30);
    expect(deck.cards[0].style.transform).toContain('translate(30px');
    deck.move(0);
    deck.release();
    await sortByKey(deck, deck.cards[0]);
    expect(deck.left()).toBe('2');
  });
});
