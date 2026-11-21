type Event = { Action: string; Package?: string; Test?: string; Output?: string };

const [listFile, ...recordFiles] = process.argv.slice(2);
if (!listFile || recordFiles.length === 0) {
  console.error("usage: bun scripts/gotest-ran.ts LIST.json RECORD.json...");
  process.exit(2);
}

const events = async (file: string): Promise<Event[]> =>
  (await Bun.file(file).text())
    .split("\n")
    .filter((l) => l.startsWith("{"))
    .map((l) => JSON.parse(l) as Event);

const listed = new Map<string, string[]>();
for (const e of await events(listFile)) {
  if (!e.Package) continue;
  if (!listed.has(e.Package)) listed.set(e.Package, []);
  const name = e.Action === "output" ? (e.Output ?? "").trim() : "";
  if (/^(Test|Fuzz|Example)\w*$/.test(name)) listed.get(e.Package)!.push(name);
}

const pkgResult = new Map<string, string>();
const testResult = new Map<string, string>();
const testOutput = new Map<string, string>();
for (const file of recordFiles) {
  for (const e of await events(file)) {
    if (e.Action === "output" && e.Package && e.Test !== undefined && !e.Test.includes("/")) {
      const k = `${e.Package} ${e.Test}`;
      testOutput.set(k, (testOutput.get(k) ?? "") + (e.Output ?? ""));
    }
    if (!e.Package || !["pass", "fail", "skip"].includes(e.Action)) continue;
    if (e.Test === undefined) pkgResult.set(e.Package, e.Action);
    else if (!e.Test.includes("/")) testResult.set(`${e.Package} ${e.Test}`, e.Action);
  }
}

const expectedSkip = (pkg: string, test: string): boolean => {
  const said = testOutput.get(`${pkg} ${test}`) ?? "";
  return said.includes("[real-corpus]") || (test.startsWith("TestWrite") && said.includes("HASALA_WRITE_CONFORMANCE"));
};

const proven = (pkg: string, test: string): boolean => {
  const result = testResult.get(`${pkg} ${test}`);
  return result === "pass" || (result === "skip" && expectedSkip(pkg, test));
};

const problems: string[] = [];
if (listed.size === 0) problems.push(`${listFile} lists no package`);
let total = 0;
for (const [pkg, tests] of listed) {
  if (tests.length === 0) {
    problems.push(`${pkg}: lists no test`);
    continue;
  }
  if (pkgResult.get(pkg) !== "pass") {
    problems.push(`${pkg}: ${pkgResult.has(pkg) ? pkgResult.get(pkg) : "not run"} in step 4, not pass`);
    continue;
  }
  const missing = tests.filter((t) => !proven(pkg, t));
  for (const t of missing) {
    const result = testResult.get(`${pkg} ${t}`) ?? "did not run";
    problems.push(`${pkg} ${t}: ${result} in step 4${result === "skip" ? ", and it is neither a real-corpus test nor a fixture writer" : ""}`);
  }
  total += tests.length;
}
if (problems.length > 0) {
  console.error("gotest-ran: the conformance packages did not all run in step 4:");
  for (const p of problems) console.error(`  ${p}`);
  process.exit(1);
}
console.log(`go: every test of the ${listed.size} conformance packages ran in step 4 (${total} tests)`);
