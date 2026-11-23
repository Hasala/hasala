import { afterEach, describe, expect, test } from 'bun:test';
import { anchorNote } from './anchor-note';

const globals = globalThis as unknown as Record<string, unknown>;
const savedWindow = globals.window;
afterEach(() => {
  globals.window = savedWindow;
});

const works = async () => {};
const refused = () =>
  Promise.reject(new DOMException('Write permission denied', 'NotAllowedError'));

function button() {
  const timers = new Map<number, () => void>();
  let next = 1;
  globals.window = {
    setTimeout: (fn: () => void) => {
      timers.set(next, fn);
      next += 1;
      return next - 1;
    },
    clearTimeout: (id: number) => timers.delete(id),
  };
  const note = { textContent: '' };
  const page = new AbortController();
  const press = anchorNote(note, 'data', page.signal);
  const runTimers = () => [...timers.values()].forEach((fn) => fn());
  return { note, page, press, timers, runTimers };
}

describe('the note beside a legal heading', () => {
  test('says the link was copied, then empties', async () => {
    const target = button();
    await target.press(works);
    expect(target.note.textContent).toBe('#data · link copied');
    target.runTimers();
    expect(target.note.textContent).toBe('');
  });

  test('names the heading when the copy is refused, then empties', async () => {
    const target = button();
    await target.press(refused);
    expect(target.note.textContent).toBe('#data');
    target.runTimers();
    expect(target.note.textContent).toBe('');
  });

  test('a second press drops the first press timer, so the note stays its full time', async () => {
    const target = button();
    await target.press(works);
    const [first] = [...target.timers.keys()];
    await target.press(works);
    expect(target.timers.has(first)).toBe(false);
    expect(target.timers.size).toBe(1);
    expect(target.note.textContent).toBe('#data · link copied');
  });

  test('two presses waiting on the clipboard leave one timer', async () => {
    const target = button();
    await Promise.all([target.press(works), target.press(works)]);
    expect(target.timers.size).toBe(1);
  });

  test('a refused press after a copy that worked leaves one timer', async () => {
    const target = button();
    await target.press(works);
    await target.press(refused);
    expect(target.timers.size).toBe(1);
    expect(target.note.textContent).toBe('#data');
  });

  test('a page swap drops the waiting timer', async () => {
    const target = button();
    await target.press(works);
    target.page.abort();
    expect(target.timers.size).toBe(0);
  });
});

describe('the legal page', () => {
  test('keeps the heading note timer in the one place that clears it', async () => {
    const source = await Bun.file(new URL('../pages/[doc].astro', import.meta.url)).text();
    expect(source).toContain("from '../scripts/anchor-note'");
    expect(source).toContain('anchorNote(');
    expect(source).not.toContain('setTimeout(');
  });
});
