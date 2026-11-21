import { onPage } from './page';

const root = document.documentElement;
const CSP = 'meta[http-equiv="content-security-policy" i]';
const FULL_LOAD = /^\/(?:i|freeze)(?:\/|$)|^\/waitlist\//;

document.addEventListener('astro:before-preparation', (e) => {
  if (FULL_LOAD.test(e.to.pathname)) return e.preventDefault();
  const load = e.loader;
  e.loader = async () => {
    await load();
    if (e.newDocument === document) return;
    const csp = (d: Document) => d.querySelector(CSP)?.getAttribute('content');
    if (csp(e.newDocument) !== csp(document)) e.preventDefault();
  };
});

document.addEventListener('astro:before-swap', (e) => {
  const next = e.newDocument.documentElement.classList;
  next.add('vt-swap', 'routed');
  if (root.classList.contains('js')) next.add('js');
  let seen = root.classList.contains('hero-seen');
  try {
    seen ||= !!sessionStorage.getItem('hasala:hero');
  } catch {
  }
  if (seen) next.add('hero-seen');
});

onPage(() => root.classList.remove('vt-swap'));
