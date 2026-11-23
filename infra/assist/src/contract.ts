export const MODEL = "@cf/cloudflare/clef";
export const TAG = "cf-clef/1";
export const MAX_BODY_BYTES = 8192;
export const UNKNOWN = "unknown";
export const UNKNOWN_CRITERION = "the name alone does not say what kind of business this is";

const CLIENT_RE = /^ios\/[0-9]{1,4}(\.[0-9]{1,4}){0,3}$/u;
const ID_RE = /^[a-z][a-z0-9_]{0,31}$/u;
const LAST_C0_CONTROL = 0x1F;
const DELETE = 0x7F;
const MAX_SUBJECT = 128;
const MAX_CATEGORIES = 32;
const MAX_NAME = 64;
const MAX_HINT = 200;
const MAX_ANSWER_DEPTH = 3;
const LONE_SURROGATE_RE = /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/u;

export interface Category {
  id: string;
  name: string;
  hint: string | null;
}

export interface Suggestion {
  subject: string;
  categories: Category[];
}

export interface ClefBody {
  model: "clef";
  state: string;
  questions: {
    category: {
      type: "choice";
      instructions: string;
      criteria: Record<string, string>;
    };
  };
}

export interface Answer {
  tag: string;
  choice: string;
  probabilities: Record<string, number>;
}

export function validClient(value: string | null): value is string {
  return value !== null && CLIENT_RE.test(value);
}

export function refusedClients(list: string | undefined): Set<string> {
  return new Set(
    (list ?? "")
      .split(",")
      .map((part) => part.trim())
      .filter((part) => part.length > 0),
  );
}

function scalars(text: string): number {
  let count = 0;
  for (const _ of text) {count += 1;}
  return count;
}

function withoutControls(text: string): string {
  let out = "";
  for (const scalar of text) {
    const code = scalar.codePointAt(0) ?? 0;
    if (code > LAST_C0_CONTROL && code !== DELETE) {out += scalar;}
  }
  return out;
}

function clean(text: string): string | null {
  if (LONE_SURROGATE_RE.test(text)) {return null;}
  return withoutControls(text).trim();
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function onlyKeys(record: Record<string, unknown>, required: string[], optional: string[] = []): boolean {
  const allowed = new Set([...required, ...optional]);
  for (const key of Object.keys(record)) {if (!allowed.has(key)) {return false;}}
  for (const key of required) {if (!Object.hasOwn(record, key)) {return false;}}
  return true;
}

function boundedText(value: unknown, max: number): string | null {
  if (typeof value !== "string") {return null;}
  const text = clean(value);
  if (text === null) {return null;}
  const count = scalars(text);
  return count >= 1 && count <= max ? text : null;
}

export function parseSuggestion(body: unknown): Suggestion | null {
  if (!isPlainObject(body) || !onlyKeys(body, ["subject", "categories"])) {return null;}
  const subject = boundedText(body.subject, MAX_SUBJECT);
  if (subject === null) {return null;}
  const raw = body.categories;
  if (!Array.isArray(raw) || raw.length === 0 || raw.length > MAX_CATEGORIES) {return null;}
  const seen = new Set<string>();
  const categories: Category[] = [];
  for (const entry of raw) {
    if (!isPlainObject(entry) || !onlyKeys(entry, ["id", "name"], ["hint"])) {return null;}
    const {id} = entry;
    if (typeof id !== "string" || !ID_RE.test(id) || id === UNKNOWN || seen.has(id)) {return null;}
    seen.add(id);
    const name = boundedText(entry.name, MAX_NAME);
    if (name === null) {return null;}
    let hint: string | null = null;
    if (entry.hint !== undefined && entry.hint !== null) {
      hint = boundedText(entry.hint, MAX_HINT);
      if (hint === null) {return null;}
    }
    categories.push({ id, name, hint });
  }
  return { subject, categories };
}

export function clefBody(suggestion: Suggestion): ClefBody {
  const criteria: Record<string, string> = {};
  for (const entry of suggestion.categories) {criteria[entry.id] = entry.hint ?? entry.name;}
  criteria[UNKNOWN] = UNKNOWN_CRITERION;
  return {
    model: "clef",
    state: `The merchant name on a card payment from a bank in the United Arab Emirates: ${JSON.stringify(suggestion.subject)}`,
    questions: {
      category: {
        type: "choice",
        instructions: "Which spending category does a payment to this merchant belong to?",
        criteria,
      },
    },
  };
}

function categoryAnswer(result: unknown): Record<string, unknown> | null {
  let current: unknown = result;
  for (let depth = 0; depth < MAX_ANSWER_DEPTH && isPlainObject(current); depth += 1) {
    const {answers} = current;
    if (isPlainObject(answers) && isPlainObject(answers.category)) {return answers.category;}
    current = current.result;
  }
  return null;
}

export function mapAnswer(result: unknown, suggestion: Suggestion): Answer | null {
  const category = categoryAnswer(result);
  if (category === null) {return null;}
  const ids = [...suggestion.categories.map((entry) => entry.id), UNKNOWN];
  const allowed = new Set(ids);
  const {choice} = category;
  if (typeof choice !== "string" || !allowed.has(choice)) {return null;}
  const raw = category.probabilities;
  if (!isPlainObject(raw)) {return null;}
  const probabilities: Record<string, number> = {};
  for (const id of ids) {
    if (!Object.hasOwn(raw, id)) {continue;}
    const score = raw[id];
    if (typeof score === "number" && Number.isFinite(score) && score >= 0 && score <= 1) {probabilities[id] = score;}
  }
  return { tag: TAG, choice, probabilities };
}
