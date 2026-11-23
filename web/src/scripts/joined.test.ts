import { describe, expect, test } from 'bun:test';
import { landJoined } from './joined';

function page(startsOnError: boolean, search: string) {
  const ok = { hidden: startsOnError };
  const error = { hidden: !startsOnError };
  const text = { textContent: 'We couldn’t add you to the list.' as string | null };
  const panel = { dataset: { state: startsOnError ? 'error' : 'success' } as Record<string, string> };
  const found: Record<string, unknown> = {
    '[data-joined-ok]': ok,
    '[data-joined-error]': error,
    '[data-joined-error-text]': text,
    '.joined__panel': panel,
  };
  const doc = { title: 'Hasala · start', querySelector: (selector: string) => found[selector] ?? null };
  const went: string[] = [];
  const at = { search, replace: (url: string) => void went.push(url) };
  landJoined(doc as unknown as Parameters<typeof landJoined>[0], at);
  return { ok, error, text, panel, doc, went };
}

describe('/joined once its script runs', () => {
  test('a build with a site key sends a visit with no error to the invite form', () => {
    const view = page(true, '');
    expect(view.went).toEqual(['/#invite']);
  });

  test('a build with a site key sends a visit with other query words to the invite form', () => {
    expect(page(true, '?ref=mail').went).toEqual(['/#invite']);
  });

  test('a build with a site key shows the reason for a refused post', () => {
    const view = page(true, '?error=bad_email');
    expect(view.went).toEqual([]);
    expect(view.ok.hidden).toBe(true);
    expect(view.error.hidden).toBe(false);
    expect(view.text.textContent).toBe('We couldn’t use that email address. Check it and try again.');
    expect(view.panel.dataset.state).toBe('error');
    expect(view.doc.title).toBe('Hasala · That didn’t go through');
  });

  test('a build with a site key keeps the error card for an empty error', () => {
    const view = page(true, '?error=');
    expect(view.went).toEqual([]);
    expect(view.error.hidden).toBe(false);
    expect(view.text.textContent).toBe('We couldn’t add you to the list.');
  });

  test('an unknown error code shows the general reason', () => {
    const view = page(true, '?error=something_new');
    expect(view.went).toEqual([]);
    expect(view.text.textContent).toBe('Something went wrong on our side. Try again in a minute.');
  });

  test('a build with no site key keeps the success card for a visit with no error', () => {
    const view = page(false, '');
    expect(view.went).toEqual([]);
    expect(view.ok.hidden).toBe(false);
    expect(view.error.hidden).toBe(true);
    expect(view.panel.dataset.state).toBe('success');
    expect(view.doc.title).toBe('Hasala · start');
  });

  test('a build with no site key shows the reason for a refused post', () => {
    const view = page(false, '?error=rate_limited');
    expect(view.went).toEqual([]);
    expect(view.ok.hidden).toBe(true);
    expect(view.error.hidden).toBe(false);
    expect(view.text.textContent).toBe('Too many tries from here. Wait a few minutes, then try again.');
  });

  test('the email mode page has no cards to change and goes nowhere', () => {
    const went: string[] = [];
    const doc = { title: 'Hasala · Email us to join', querySelector: () => null };
    landJoined(doc as unknown as Parameters<typeof landJoined>[0], { search: '', replace: (url: string) => void went.push(url) });
    expect(went).toEqual([]);
    expect(doc.title).toBe('Hasala · Email us to join');
  });
});

describe('the /joined page', () => {
  test('runs landJoined on each page load', async () => {
    const source = await Bun.file(new URL('../pages/joined.astro', import.meta.url)).text();
    expect(source).toContain("onPage(() => landJoined(document, location));");
  });
});
