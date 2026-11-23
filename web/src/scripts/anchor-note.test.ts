import { afterEach, describe, expect, test } from 'bun:test';
import { anchorNote } from './anchor-note';
import { fakeRoot, keepGlobals } from './test-fakes';

const globals = globalThis as unknown as Record<string, unknown>;
afterEach(keepGlobals(['document']));

const works = async () => {};
const refused = () =>
  Promise.reject(new DOMException('Write permission denied', 'NotAllowedError'));

function button() {
  const root = fakeRoot();
  globals.document = { documentElement: root };
  const note = { textContent: '' };
  const page = new AbortController();
  const press = anchorNote(note, 'data', page.signal);
  return { note, page, press, root };
}

describe('the note beside a legal heading', () => {
  test('says the link was copied, then empties', async () => {
    const target = button();
    await target.press(works);
    expect(target.note.textContent).toBe('#data · link copied');
    target.root.finish();
    expect(target.note.textContent).toBe('');
  });

  test('names the heading when the copy is refused, then empties', async () => {
    const target = button();
    await target.press(refused);
    expect(target.note.textContent).toBe('#data');
    target.root.finish();
    expect(target.note.textContent).toBe('');
  });

  test('a second press drops the first press timer, so the note stays its full time', async () => {
    const target = button();
    await target.press(works);
    const [first] = target.root.holds;
    await target.press(works);
    expect(first?.waiting).toBe(false);
    expect(target.root.waiting()).toEqual([2400]);
    expect(target.note.textContent).toBe('#data · link copied');
  });

  test('two presses waiting on the clipboard leave one timer', async () => {
    const target = button();
    await Promise.all([target.press(works), target.press(works)]);
    expect(target.root.waiting()).toEqual([2400]);
  });

  test('a refused press after a copy that worked leaves one timer', async () => {
    const target = button();
    await target.press(works);
    await target.press(refused);
    expect(target.root.waiting()).toEqual([2400]);
    expect(target.note.textContent).toBe('#data');
  });

  test('a page swap drops the waiting timer', async () => {
    const target = button();
    await target.press(works);
    target.page.abort();
    expect(target.root.waiting()).toEqual([]);
  });
});

describe('the legal page', () => {
  test('keeps the heading note timer in the one place that clears it', async () => {
    const source = await Bun.file(new URL('../pages/[doc].astro', import.meta.url)).text();
    expect(source).toContain("from '../scripts/anchor-note'");
    expect(source).toContain('anchorNote(');
    expect(source).not.toContain('setTimeout(');
    expect(source).not.toContain('.animate(null');
  });
});
