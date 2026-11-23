import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

interface Step {
  name: string;
  conclusion: string | null;
  started_at: string | null;
  completed_at: string | null;
}
interface Job {
  name: string;
  conclusion: string | null;
  run_attempt: number;
  created_at: string;
  started_at: string | null;
  completed_at: string | null;
  labels: string[];
  steps?: Step[];
}
interface Run {
  id: number;
  event: string;
  conclusion: string | null;
  created_at: string;
  run_attempt: number;
  head_branch: string | null;
}

const SETUP_STEPS = [
  /^Set up job$/u,
  /^Run actions\/checkout@/u,
  /^Run DeterminateSystems\/nix-installer-action@/u,
  /cache$/iu,
  /caches/iu,
  /^Build the devShell$/u,
  /^Install /u,
  /^Let the NixOS VM test use KVM$/u,
  /^Select the newest Xcode$/u,
  /^Toolchain$/u,
  /^Post /u,
  /^Complete job$/u,
  /^Upload /u,
];

function usage(): never {
  console.error(
    'usage: bun scripts/ci-timing.ts [--runs N] [--workflow FILE] [--event EVENT] [--branch NAME] [--dir DIR] [--steps]',
  );
  process.exit(2);
}

const args = process.argv.slice(2);
const opt = (name: string, fallback: string): string => {
  const at = args.indexOf(name);
  if (at === -1) {
    return fallback;
  }
  const value = args[at + 1];
  if (value === undefined) {
    usage();
  }
  args.splice(at, 2);
  return value;
};
const flag = (name: string): boolean => {
  const at = args.indexOf(name);
  if (at === -1) {
    return false;
  }
  args.splice(at, 1);
  return true;
};
const wantRuns = Number(opt('--runs', '150'));
const workflow = opt('--workflow', 'ci.yml');
const onlyEvent = opt('--event', '');
const onlyBranch = opt('--branch', '');
const dir = opt('--dir', join(tmpdir(), 'hasala-ci-timing'));
const showSteps = flag('--steps');
if (args.length > 0 || !Number.isInteger(wantRuns) || wantRuns < 1) {
  usage();
}

const gh = (path: string): unknown =>
  JSON.parse(execFileSync('gh', ['api', path], { encoding: 'utf8', maxBuffer: 256 * 1024 * 1024 }));
const repo = execFileSync(
  'gh',
  ['repo', 'view', '--json', 'nameWithOwner', '--jq', '.nameWithOwner'],
  { encoding: 'utf8' },
).trim();
mkdirSync(join(dir, 'jobs'), { recursive: true });

const runs: Run[] = [];
for (let page = 1; runs.length < wantRuns && page <= 20; page += 1) {
  const query = [
    `per_page=100`,
    `page=${page}`,
    onlyEvent ? `event=${onlyEvent}` : '',
    onlyBranch ? `branch=${encodeURIComponent(onlyBranch)}` : '',
  ]
    .filter(Boolean)
    .join('&');
  const got = (
    gh(`repos/${repo}/actions/workflows/${workflow}/runs?${query}`) as { workflow_runs: Run[] }
  ).workflow_runs;
  if (got.length === 0) {
    break;
  }
  runs.push(...got.filter((run) => run.conclusion !== null));
}
runs.length = Math.min(runs.length, wantRuns);

function jobsOf(run: Run): Job[] {
  const file = join(dir, 'jobs', `${run.id}-${run.run_attempt}.json`);
  if (!existsSync(file)) {
    const got = (
      gh(`repos/${repo}/actions/runs/${run.id}/attempts/${run.run_attempt}/jobs?per_page=100`) as {
        jobs: Job[];
      }
    ).jobs;
    writeFileSync(file, JSON.stringify(got));
  }
  return JSON.parse(readFileSync(file, 'utf8')) as Job[];
}

const seconds = (from: string | null, to: string | null): number =>
  from && to ? (Date.parse(to) - Date.parse(from)) / 1000 : Number.NaN;
function quantile(values: number[], fraction: number): number {
  const sorted = values
    .filter((value) => !Number.isNaN(value))
    .toSorted((left, right) => left - right);
  if (sorted.length === 0) {
    return Number.NaN;
  }
  const at = (sorted.length - 1) * fraction;
  const low = Math.floor(at);
  const high = Math.ceil(at);
  return sorted[low] + (sorted[high] - sorted[low]) * (at - low);
}
const show = (value: number): string => (Number.isNaN(value) ? '-' : String(Math.round(value)));
const pair = (values: number[]): string =>
  `${show(quantile(values, 0.5))} / ${show(quantile(values, 0.95))}`;
const isSetup = (name: string): boolean => SETUP_STEPS.some((re) => re.test(name));

interface Timing {
  wait: number;
  setup: number;
  work: number;
  total: number;
}
const byJob = new Map<string, Timing[]>();
const outcomes = new Map<string, Map<string, number>>();
const bySteps = new Map<string, number[]>();
const prResult: number[] = [];
const prAll: number[] = [];
let runnerSeconds = 0;
const runnerSecondsByLabel = new Map<string, number>();

for (const run of runs) {
  const jobs = jobsOf(run);
  for (const job of jobs) {
    const conclusion = job.conclusion ?? 'none';
    const counts = outcomes.get(job.name) ?? new Map<string, number>();
    counts.set(conclusion, (counts.get(conclusion) ?? 0) + 1);
    outcomes.set(job.name, counts);
    const total = seconds(job.started_at, job.completed_at);
    if (conclusion !== 'skipped' && !Number.isNaN(total) && (job.steps?.length ?? 0) > 0) {
      runnerSeconds += total;
      const label = job.labels.join(',');
      runnerSecondsByLabel.set(label, (runnerSecondsByLabel.get(label) ?? 0) + total);
    }
    if (conclusion !== 'success') {
      continue;
    }
    let setup = 0;
    let work = 0;
    for (const step of job.steps ?? []) {
      const took = seconds(step.started_at, step.completed_at);
      if (Number.isNaN(took)) {
        continue;
      }
      if (isSetup(step.name)) {
        setup += took;
      } else {
        work += took;
      }
      const key = `${job.name}\t${isSetup(step.name) ? 'setup' : 'run'}\t${step.name}`;
      const list = bySteps.get(key) ?? [];
      list.push(took);
      bySteps.set(key, list);
    }
    const list = byJob.get(job.name) ?? [];
    list.push({ wait: seconds(job.created_at, job.started_at), setup, work, total });
    byJob.set(job.name, list);
  }
  if (
    run.event === 'pull_request' &&
    run.run_attempt === 1 &&
    (run.conclusion === 'success' || run.conclusion === 'failure')
  ) {
    const gateDone = jobs.find((job) => job.name === 'ci-ok')?.completed_at ?? null;
    const ends = jobs
      .filter((job) => job.conclusion !== 'skipped' && job.completed_at)
      .map((job) => Date.parse(job.completed_at as string));
    prResult.push(seconds(run.created_at, gateDone));
    if (ends.length > 0) {
      prAll.push((Math.max(...ends) - Date.parse(run.created_at)) / 1000);
    }
  }
}

const first = runs.at(-1);
const [last] = runs;
console.log(`# CI timing: ${repo}, ${workflow}`);
console.log('');
console.log(
  `${runs.length} completed runs, ${first?.created_at ?? '-'} to ${last?.created_at ?? '-'}. All times are seconds, p50 / p95.`,
);
console.log('');
console.log("## A pull request's result");
console.log('');
console.log('| Measure | Runs | p50 / p95 | Max |');
console.log('| --- | --- | --- | --- |');
console.log(
  `| Run created to \`ci-ok\` done | ${prResult.filter((value) => !Number.isNaN(value)).length} | ${pair(prResult)} | ${show(Math.max(...prResult.filter((value) => !Number.isNaN(value))))} |`,
);
console.log(
  `| Run created to the last job done | ${prAll.length} | ${pair(prAll)} | ${show(Math.max(...prAll))} |`,
);
console.log('');
console.log('## Jobs (successful jobs only)');
console.log('');
console.log('| Job | Jobs | Waiting | Setup | Running | Total |');
console.log('| --- | --- | --- | --- | --- | --- |');
for (const [name, list] of [...byJob].toSorted(([left], [right]) => left.localeCompare(right))) {
  const column = (key: keyof Timing): string => pair(list.map((timing) => timing[key]));
  console.log(
    `| \`${name}\` | ${list.length} | ${column('wait')} | ${column('setup')} | ${column('work')} | ${column('total')} |`,
  );
}
console.log('');
console.log('## Outcomes');
console.log('');
console.log('| Job | Success | Failure | Cancelled | Skipped |');
console.log('| --- | --- | --- | --- | --- |');
for (const [name, counts] of [...outcomes].toSorted(([left], [right]) =>
  left.localeCompare(right),
)) {
  const count = (key: string): number => counts.get(key) ?? 0;
  console.log(
    `| \`${name}\` | ${count('success')} | ${count('failure')} | ${count('cancelled')} | ${count('skipped')} |`,
  );
}
console.log('');
console.log('## Runner time');
console.log('');
console.log('| Runner | Minutes |');
console.log('| --- | --- |');
for (const [label, total] of [...runnerSecondsByLabel].toSorted(([left], [right]) =>
  left.localeCompare(right),
)) {
  console.log(`| \`${label}\` | ${Math.round(total / 60)} |`);
}
console.log(`| All | ${Math.round(runnerSeconds / 60)} |`);
if (showSteps) {
  console.log('');
  console.log('## Steps (successful jobs only, p95 of 3 s or more)');
  console.log('');
  console.log('| Job | Kind | Step | Steps | p50 / p95 |');
  console.log('| --- | --- | --- | --- | --- |');
  for (const [key, list] of [...bySteps].toSorted(([left], [right]) => left.localeCompare(right))) {
    if (quantile(list, 0.95) < 3) {
      continue;
    }
    const [job, kind, step] = key.split('\t');
    console.log(
      `| \`${job}\` | ${kind} | ${step.replaceAll('|', String.raw`\|`)} | ${list.length} | ${pair(list)} |`,
    );
  }
}
