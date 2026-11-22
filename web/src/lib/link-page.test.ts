import { describe, expect, test } from 'bun:test';
import { arriveAtLink, markLinkDone } from './link-page';

const token = 'A'.repeat(43);
const router = { index: 3, scrollX: 0, scrollY: 40 };
const read = (path: string) => Bun.file(new URL(path, import.meta.url)).text();

function tab(hash: string, state: Record<string, unknown> | null = router) {
  const place = { hash };
  const hist = {
    state,
    url: `/freeze${hash}`,
    replaceState(next: unknown, _title: string, url?: string | URL | null) {
      hist.state = next as Record<string, unknown> | null;
      if (url) {hist.url = String(url);}
      if (url) {place.hash = '';}
    },
  };
  return { place, hist };
}

const arrive = (page: 'freeze' | 'confirm' | 'leave', view: ReturnType<typeof tab>) => arriveAtLink(page, '/freeze', view.place, view.hist as unknown as History);
const reload = (view: ReturnType<typeof tab>, page: 'freeze' | 'confirm' | 'leave' = 'freeze') => arrive(page, view);

describe('arriving at a link page', () => {
  test('a whole token asks, and leaves the address bar', () => {
    const view = tab(`#${token}`);
    expect(arrive('freeze', view)).toEqual({ step: 'ask', token });
    expect(view.hist.url).toBe('/freeze');
    expect(view.hist.state).toEqual(router);
  });

  const incomplete = ['', '#', '#short', `#${token}A`, `#${'!'.repeat(43)}`].map((hash) => [JSON.stringify(hash.slice(0, 8)), hash]);
  test.each(incomplete)('the address %s is incomplete and leaves the address bar', (_shown, hash) => {
    const view = tab(hash);
    expect(arrive('freeze', view)).toEqual({ step: 'incomplete' });
    expect(view.hist.url).toBe('/freeze');
  });

  test('a history entry with no state keeps none', () => {
    const view = tab('', null);
    expect(arrive('confirm', view)).toEqual({ step: 'incomplete' });
    expect(view.hist.state).toBeNull();
  });
});

describe('a finished link', () => {
  test.each(['freeze', 'confirm', 'leave'] as const)('%s is still done after a reload', (page) => {
    const view = tab(`#${token}`);
    arrive(page, view);
    markLinkDone(page, view.hist as unknown as History);
    expect(reload(view, page)).toEqual({ step: 'done' });
    expect(reload(view, page)).toEqual({ step: 'done' });
  });

  test('keeps the state the router needs and never the token', () => {
    const view = tab(`#${token}`);
    arrive('confirm', view);
    markLinkDone('confirm', view.hist as unknown as History);
    expect(view.hist.state).toMatchObject(router);
    expect(JSON.stringify(view.hist.state)).not.toContain(token);
  });

  test('a link that failed is not done after a reload', () => {
    const view = tab(`#${token}`);
    arrive('freeze', view);
    expect(reload(view)).toEqual({ step: 'incomplete' });
  });

  test('does not carry to another kind of link', () => {
    const view = tab(`#${token}`);
    arrive('confirm', view);
    markLinkDone('confirm', view.hist as unknown as History);
    expect(reload(view, 'leave')).toEqual({ step: 'incomplete' });
  });

  test('gives way to a new token, and the new one starts unfinished', () => {
    const view = tab(`#${token}`);
    arrive('confirm', view);
    markLinkDone('confirm', view.hist as unknown as History);
    const other = 'B'.repeat(43);
    view.place.hash = `#${other}`;
    expect(arrive('confirm', view)).toEqual({ step: 'ask', token: other });
    expect(view.hist.state).toEqual(router);
    expect(reload(view, 'confirm')).toEqual({ step: 'incomplete' });
  });

  test('does not answer for a broken link opened in the same tab', () => {
    const view = tab(`#${token}`);
    arrive('confirm', view);
    markLinkDone('confirm', view.hist as unknown as History);
    view.place.hash = '#short';
    expect(arrive('confirm', view)).toEqual({ step: 'incomplete' });
  });
});

describe('the link pages', () => {
  test('/freeze reads the link once and records a finished freeze', async () => {
    const source = await read('../pages/freeze.astro');
    expect(source).toContain("arriveAtLink('freeze', '/freeze')");
    expect(source).toContain("markLinkDone('freeze')");
    expect(source).not.toContain('location.hash.slice(1)');
  });

  test('the waitlist links read the link once and record a finished press', async () => {
    const source = await read('../components/WaitlistLink.astro');
    expect(source).toContain('arriveAtLink(kind, location.pathname)');
    expect(source).toContain('markLinkDone(kind)');
    expect(source).not.toContain('location.hash.slice(1)');
  });
});
