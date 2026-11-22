import { readFileSync, readdirSync } from 'node:fs';

export const LEGAL_STATUSES = ['draft', 'final'];

const ALL_LEGAL_PATHS = ['/privacy', '/terms', '/security', '/support'];

export function legalStatus(name, source) {
  const [, head = '', ...rest] = source.split(/^---$/mu);
  const line = /^status:(.*)$/mu.exec(head)?.[1];
  const status =
    line === undefined
      ? 'draft'
      : line
          .replace(/\s+#.*$/u, '')
          .trim()
          .replace(/^(["'])(.*)\1$/u, '$2');
  if (status !== 'draft' && status !== 'final') {
    throw new Error(
      `docs/legal/${name}: status must be "draft" or "final", not ${JSON.stringify(status)}`,
    );
  }
  const shown = [head.replace(/^draftNote:.*$/mu, ''), ...rest].join('---');
  if (status === 'final' && shown.includes('[[OWNER:')) {
    throw new Error(
      `docs/legal/${name}: a final page cannot have an [[OWNER: ...]] note. Resolve the note, or set status to "draft".`,
    );
  }
  return status;
}

function listFolder(folder) {
  try {
    return readdirSync(folder);
  } catch {
    return null;
  }
}

export function draftLegalPaths(folder) {
  const files = listFolder(folder);
  if (!files) {
    return [...ALL_LEGAL_PATHS];
  }
  return files
    .filter(
      (file) =>
        file.endsWith('.md') &&
        legalStatus(file, readFileSync(new URL(file, folder), 'utf8')) === 'draft',
    )
    .map((file) => `/${file.replace(/\.md$/u, '')}`);
}
