/**
 * The legal Markdown carries notes for the owner, written [[OWNER: ...]],
 * and placeholders like [OPERATOR LEGAL NAME]. While a page is a draft they
 * are shown as marked notes so reviewers can find them; this plugin turns
 * them into <mark> elements. (Pages with notes left must not be published:
 * the legal pages stay noindex while their status is "draft".)
 */
const NOTE = /\[\[OWNER:\s*([\s\S]*?)\]\]/gu;
const PLACEHOLDER = /\[([A-Z][A-Z0-9 ,.'’&/()-]{3,})\]/gu;

const escape = (text) => text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

function transformText(value) {
  if (!NOTE.test(value) && !PLACEHOLDER.test(value)) {return null;}
  NOTE.lastIndex = 0;
  PLACEHOLDER.lastIndex = 0;
  const html = escape(value)
    .replace(NOTE, (_, note) => `<mark class="owner-note"><b>Owner:</b> ${note}</mark>`)
    .replace(PLACEHOLDER, (match) => `<mark class="placeholder">${match}</mark>`);
  return { type: 'html', value: html };
}

/**
 * A note can span several inline nodes: GFM turns an email address or URL
 * inside it into a link, which splits the text. Fold each such run (from the
 * text that opens "[[OWNER:" to the text that closes "]]") into one text node
 * first, so the whole note is marked. Links inside a note become plain text.
 */
function mergeSplitNotes(node) {
  const kids = node.children;
  for (let index = 0; index < kids.length; index += 1) {
    const start = kids[index];
    if (start.type !== 'text') {continue;}
    const open = start.value.lastIndexOf('[[OWNER:');
    if (open === -1 || start.value.includes(']]', open)) {continue;}
    let end = index + 1;
    while (end < kids.length && !(kids[end].type === 'text' && kids[end].value.includes(']]'))) {end += 1;}
    if (end >= kids.length) {continue;}
    const value = kids.slice(index, end + 1).map((kid) => textOf(kid)).join('');
    kids.splice(index, end - index + 1, { type: 'text', value });
  }
}

function walk(node) {
  if (!node.children) {return;}
  mergeSplitNotes(node);
  for (let index = 0; index < node.children.length; index += 1) {
    const child = node.children[index];
    if (child.type === 'text') {
      const replacement = transformText(child.value);
      if (replacement) {node.children[index] = replacement;}
    } else if (child.type !== 'code' && child.type !== 'inlineCode') {
      walk(child);
    }
  }
}

const slugify = (text) =>
  text
    .toLowerCase()
    .replaceAll(/[^a-z0-9\s-]/gu, '')
    .trim()
    .replaceAll(/\s+/gu, '-');
const textOf = (node) => (node.value ?? '') + (node.children ?? []).map((kid) => textOf(kid)).join('');

/** plainWords may also be a map of section slug -> summary: each one becomes an "In plain words" callout under its heading. */
function sectionCallouts(tree, plainWords) {
  if (!plainWords || typeof plainWords !== 'object') {return;}
  for (let index = tree.children.length - 1; index >= 0; index -= 1) {
    const node = tree.children[index];
    if (node.type !== 'heading' || node.depth !== 2) {continue;}
    const summary = plainWords[slugify(textOf(node))];
    if (!summary) {continue;}
    tree.children.splice(index + 1, 0, {
      type: 'html',
      value: `<aside class="plain-words" aria-label="In plain words"><span class="plain-words__coin" aria-hidden="true"></span><div><p class="plain-words__title">In plain words</p><p>${escape(summary)}</p></div></aside>`,
    });
  }
}

export function remarkOwnerNotes() {
  return (tree, file) => {
    walk(tree);
    sectionCallouts(tree, file.data?.astro?.frontmatter?.plainWords);
  };
}
