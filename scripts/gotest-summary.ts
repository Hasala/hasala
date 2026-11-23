interface Event {
  Action: string;
  Package?: string;
  ImportPath?: string;
  Test?: string;
  Output?: string;
  Elapsed?: number;
}

const output = new Map<string, string[]>();
const failed: string[] = [];
const failedPackages: string[] = [];
const skipped: string[] = [];
const totals = { pass: 0, fail: 0, skip: 0 };
const packages = { ok: 0, fail: 0, noTests: 0 };
const key = (event: Event): string => `${event.Package ?? ''} ${event.Test ?? ''}`;
const REAL_CORPUS = '[real-corpus]';
const realCorpus = { ran: 0, skipped: 0 };
const marked = (id: string): boolean =>
  (output.get(id) ?? []).some((line) => line.includes(REAL_CORPUS));
const seeds = new Map<string, string>();
const SEED = /^-test\.shuffle (\d+)\s*$/u;
const order = (pkg: string | undefined): string => {
  const seed = seeds.get(pkg ?? '');
  return seed === undefined ? '' : ` -shuffle=${seed}`;
};

for await (const line of console) {
  if (!line.startsWith('{')) {
    if (line.trim() !== '') {
      console.log(line);
    }
    continue;
  }
  const event = JSON.parse(line) as Event;
  if (event.Action === 'build-output') {
    process.stdout.write(event.Output ?? '');
    continue;
  }
  if (event.Action === 'output') {
    const id = key(event);
    const seed = event.Test === undefined ? SEED.exec(event.Output ?? '') : null;
    if (seed?.[1] !== undefined) {
      seeds.set(event.Package ?? '', seed[1]);
    }
    const lines = output.get(id) ?? [];
    lines.push(event.Output ?? '');
    output.set(id, lines);
    continue;
  }
  if (event.Test === undefined) {
    if (event.Action === 'pass') {
      packages.ok += 1;
      console.log(`ok    ${event.Package} (${event.Elapsed ?? 0}s)`);
    } else if (event.Action === 'fail') {
      packages.fail += 1;
      console.log(`FAIL  ${event.Package} (${event.Elapsed ?? 0}s)${order(event.Package)}`);
      failed.push(key(event));
      failedPackages.push(event.Package ?? '');
    } else if (event.Action === 'skip') {
      packages.noTests += 1;
    }
    continue;
  }
  if (event.Action === 'pass' || event.Action === 'fail' || event.Action === 'skip') {
    totals[event.Action] += 1;
    if (event.Action === 'fail') {
      failed.push(key(event));
    }
    if (event.Action === 'skip') {
      skipped.push(key(event));
    }
    if (marked(key(event))) {
      if (event.Action === 'skip') {
        realCorpus.skipped += 1;
      } else {
        realCorpus.ran += 1;
      }
    }
  }
}

const reason = (id: string): string => {
  const lines = (output.get(id) ?? [])
    .map((line) => line.trim())
    .filter((line) => line !== '' && !line.startsWith('--- SKIP') && !line.startsWith('=== '));
  return lines.at(-1) ?? '(no reason given)';
};

if (skipped.length > 0) {
  console.log(`\nskipped (${skipped.length}):`);
  for (const id of skipped) {
    console.log(`  ${id}\n      ${reason(id)}`);
  }
}
if (failed.length > 0) {
  console.log(`\nfailed (${failed.length}):`);
  for (const id of failed) {
    console.log(`\n=== ${id}`);
    process.stdout.write((output.get(id) ?? ['(no output)\n']).join(''));
  }
}
console.log(
  `\ngo test: ${totals.pass} passed, ${totals.fail} failed, ${totals.skip} skipped (tests and subtests); ` +
    `${packages.ok} packages ok, ${packages.fail} failed, ${packages.noTests} without tests`,
);
console.log(
  `go test: real corpus (HASALA_PRIVATE_FIXTURES): ${realCorpus.ran} tests ran against it, ${realCorpus.skipped} skipped without it`,
);
const countsFile = process.env['REALCORPUS_COUNTS'];
if (countsFile) {
  await Bun.write(countsFile, `${realCorpus.ran} ${realCorpus.skipped}\n`);
}
if (failedPackages.length > 0) {
  console.log('\nto run a failed package again in the same order:');
  for (const pkg of failedPackages) {
    console.log(`  go test -count=1${order(pkg)} ${pkg}`);
  }
}
if (failed.length > 0 || packages.fail > 0) {
  process.exit(1);
}
if (totals.pass === 0) {
  console.log('go test: nothing ran; refusing to call that a pass');
  process.exit(1);
}
