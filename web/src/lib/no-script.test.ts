import { describe, expect, test } from 'bun:test';

const read = (path: string) => Bun.file(new URL(path, import.meta.url)).text();

describe('the message for a page whose script never ran', () => {
  const pages = [
    ['/freeze', '../pages/freeze.astro'],
    ['/waitlist links', '../components/WaitlistLink.astro'],
  ];

  test.each(pages)('%s shows it in the page, not in a noscript element', async (_name, path) => {
    const source = await read(path);
    expect(source).not.toContain('<noscript');
    expect(source).toMatch(/<p [^>]*data-no-script[^>]*>[^<]*This page needs JavaScript/u);
  });

  test.each(pages)('%s takes it away once its own script has run', async (_name, path) => {
    expect(await read(path)).toContain("root.querySelector('[data-no-script]')?.remove();");
  });

  test('a running script hides it', async () => {
    expect(await read('../styles/global.css')).toMatch(
      /\.js \[data-no-script\]\s*\{\s*display: none;/u,
    );
  });
});
