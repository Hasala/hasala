import { afterEach, beforeEach, describe, expect, jest, test } from 'bun:test';
import { PENDING, stillPending } from '../scripts/test-fakes';
import { postFreeze } from './freeze';

const token = 'A'.repeat(43);
const answering = (status: number) =>
  (() => Promise.resolve(new Response(null, { status }))) as unknown as typeof fetch;

beforeEach(() => {
  jest.useFakeTimers();
});
afterEach(() => {
  jest.useRealTimers();
});

describe('postFreeze', () => {
  test('only a 204 is done', async () => {
    expect(await postFreeze('https://api.example/api', token, answering(204))).toBe('done');
  });

  test.each([200, 202, 400, 403, 404, 426, 429, 500, 502, 503, 530])(
    'a %i asks for a retry',
    async (status) => {
      expect(await postFreeze('https://api.example/api', token, answering(status))).toBe('retry');
    },
  );

  test('a failed request is unreachable', async () => {
    const failing = (() =>
      Promise.reject(new TypeError('failed to fetch'))) as unknown as typeof fetch;
    expect(await postFreeze('https://api.example/api', token, failing)).toBe('unreachable');
  });

  test('a request that gets no answer stops waiting and asks for a retry', async () => {
    const hanging = ((_u: string, init: RequestInit) =>
      new Promise((_resolve, reject) => {
        init.signal?.addEventListener('abort', () =>
          reject(new DOMException('Aborted', 'AbortError')),
        );
      })) as unknown as typeof fetch;
    const result = postFreeze('https://api.example/api', token, hanging);
    jest.advanceTimersByTime(19_999);
    expect(await Promise.race([result, stillPending()])).toBe(PENDING);
    jest.advanceTimersByTime(1);
    expect(await Promise.race([result, stillPending()])).toBe('retry');
  });

  test('an answer inside the wait counts and ends the wait', async () => {
    const seen: { signal?: AbortSignal | null } = {};
    const quick = ((_u: string, init: RequestInit) => {
      seen.signal = init.signal;
      return Promise.resolve(new Response(null, { status: 204 }));
    }) as unknown as typeof fetch;
    expect(await postFreeze('https://api.example/api', token, quick)).toBe('done');
    jest.advanceTimersByTime(60_000);
    expect(seen.signal?.aborted).toBe(false);
  });

  test('a network failure inside the wait stays unreachable', async () => {
    const failing = (() =>
      Promise.reject(new TypeError('failed to fetch'))) as unknown as typeof fetch;
    expect(await postFreeze('https://api.example/api', token, failing, 1000)).toBe('unreachable');
  });

  test('the request can read the status and stays free of a preflight', async () => {
    let url = '';
    let init: RequestInit = {};
    const capture = ((target: string, options: RequestInit) => {
      url = target;
      init = options;
      return Promise.resolve(new Response(null, { status: 204 }));
    }) as unknown as typeof fetch;
    await postFreeze('https://api.example/api', token, capture);
    expect(url).toBe('https://api.example/api/v1/account/freeze');
    expect(init.method).toBe('POST');
    expect(init.mode).toBe('cors');
    expect(init.credentials).toBe('omit');
    expect(init.referrerPolicy).toBe('no-referrer');
    expect(init.headers).toEqual({ 'content-type': 'text/plain;charset=UTF-8' });
    expect(init.body).toBe(JSON.stringify({ token }));
  });
});
