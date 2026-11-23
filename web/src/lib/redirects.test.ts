import { expect, test } from 'bun:test';

const parse = (text: string): string[][] =>
  text
    .split('\n')
    .filter((line) => line.trim() && !line.trim().startsWith('#'))
    .map((line) => line.trim().split(/\s+/u));

test('/testflight sends email readers to TestFlight on the App Store', async () => {
  const text = await Bun.file(new URL('../../public/_redirects', import.meta.url)).text();
  const rules = parse(text);
  expect(rules).toContainEqual([
    '/testflight',
    'https://apps.apple.com/app/testflight/id899247664',
    '302',
  ]);
});
