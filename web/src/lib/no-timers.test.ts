import { describe, expect, test } from 'bun:test';

const TIMER = /\bset(?:Timeout|Interval|Immediate)\b/u;
const SRC = new URL('../', import.meta.url);

const astroFiles = async (): Promise<string[]> => {
  const found: string[] = [];
  for await (const path of new Bun.Glob('**/*.astro').scan({ cwd: SRC.pathname })) {
    found.push(path);
  }
  return found.toSorted();
};

describe('timers in .astro files', () => {
  test('there are .astro files to read', async () => {
    const files = await astroFiles();
    expect(files.length).toBeGreaterThan(0);
  });

  test('no .astro file names a timer, in its markup or anywhere else', async () => {
    const files = await astroFiles();
    const read = await Promise.all(
      files.map(async (path) => ({ path, text: await Bun.file(new URL(path, SRC)).text() })),
    );
    const named = read.filter(({ text }) => TIMER.test(text)).map(({ path }) => path);
    expect(named).toEqual([]);
  });

  test('the scan sees a timer in a markup expression and in a handler string', () => {
    expect(TIMER.test('<p data-x={setTimeout(() => undefined, 1)}></p>')).toBe(true);
    expect(TIMER.test('<button onclick="setInterval(run, 1)">x</button>')).toBe(true);
    expect(TIMER.test('<p>settle, timeout</p>')).toBe(false);
  });
});
