interface Event {
  Action: string;
  Package?: string;
  Test?: string;
  Output?: string;
}

const [listFile, ...recordFiles] = process.argv.slice(2);
if (!listFile || recordFiles.length === 0) {
  console.error('usage: bun scripts/gotest-ran.ts LIST.json RECORD.json...');
  process.exit(2);
}

const events = async (file: string): Promise<Event[]> => {
  const text = await Bun.file(file).text();
  return text
    .split('\n')
    .filter((line) => line.startsWith('{'))
    .map((line) => JSON.parse(line) as Event);
};

const listed = new Map<string, string[]>();
for (const event of await events(listFile)) {
  if (!event.Package) {
    continue;
  }
  const names = listed.get(event.Package) ?? [];
  listed.set(event.Package, names);
  const name = event.Action === 'output' ? (event.Output ?? '').trim() : '';
  if (/^(Test|Fuzz|Example)\w*$/u.test(name)) {
    names.push(name);
  }
}

const pkgResult = new Map<string, string>();
const testResult = new Map<string, string>();
const testOutput = new Map<string, string>();
const records = await Promise.all(recordFiles.map((file) => events(file)));
for (const record of records) {
  for (const event of record) {
    if (
      event.Action === 'output' &&
      event.Package &&
      event.Test !== undefined &&
      !event.Test.includes('/')
    ) {
      const key = `${event.Package} ${event.Test}`;
      testOutput.set(key, (testOutput.get(key) ?? '') + (event.Output ?? ''));
    }
    if (!event.Package || !['pass', 'fail', 'skip'].includes(event.Action)) {
      continue;
    }
    if (event.Test === undefined) {
      pkgResult.set(event.Package, event.Action);
    } else if (!event.Test.includes('/')) {
      testResult.set(`${event.Package} ${event.Test}`, event.Action);
    }
  }
}

const expectedSkip = (pkg: string, test: string): boolean => {
  const said = testOutput.get(`${pkg} ${test}`) ?? '';
  return (
    said.includes('[real-corpus]') ||
    (test.startsWith('TestWrite') && said.includes('HASALA_WRITE_CONFORMANCE'))
  );
};

const proven = (pkg: string, test: string): boolean => {
  const result = testResult.get(`${pkg} ${test}`);
  return result === 'pass' || (result === 'skip' && expectedSkip(pkg, test));
};

const problems: string[] = [];
if (listed.size === 0) {
  problems.push(`${listFile} lists no package`);
}
let total = 0;
for (const [pkg, tests] of listed) {
  if (tests.length === 0) {
    problems.push(`${pkg}: lists no test`);
    continue;
  }
  if (pkgResult.get(pkg) !== 'pass') {
    problems.push(
      `${pkg}: ${pkgResult.has(pkg) ? pkgResult.get(pkg) : 'not run'} in step 4, not pass`,
    );
    continue;
  }
  const missing = tests.filter((name) => !proven(pkg, name));
  for (const name of missing) {
    const result = testResult.get(`${pkg} ${name}`) ?? 'did not run';
    problems.push(
      `${pkg} ${name}: ${result} in step 4${result === 'skip' ? ', and it is neither a real-corpus test nor a fixture writer' : ''}`,
    );
  }
  total += tests.length;
}
if (problems.length > 0) {
  console.error('gotest-ran: the conformance packages did not all run in step 4:');
  for (const problem of problems) {
    console.error(`  ${problem}`);
  }
  process.exit(1);
}
console.log(
  `go: every test of the ${listed.size} conformance packages ran in step 4 (${total} tests)`,
);
