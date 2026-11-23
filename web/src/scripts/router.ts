import { onPage } from './page';

const root = document.documentElement;
const CSP = 'meta[http-equiv="content-security-policy" i]';
const FULL_LOAD = /^\/(?:i|freeze)(?:\/|$)|^\/waitlist\//u;

function heroSeen(): boolean {
  try {
    return Boolean(sessionStorage.getItem('hasala:hero'));
  } catch {
    return false;
  }
}

document.addEventListener('astro:before-preparation', (event) => {
  if (FULL_LOAD.test(event.to.pathname)) {
    return event.preventDefault();
  }
  const load = event.loader;
  event.loader = async () => {
    await load();
    if (event.newDocument === document) {
      return;
    }
    const csp = (doc: Document): string | null | undefined =>
      doc.querySelector(CSP)?.getAttribute('content');
    if (csp(event.newDocument) !== csp(document)) {
      event.preventDefault();
    }
  };
});

document.addEventListener('astro:before-swap', (event) => {
  const next = event.newDocument.documentElement.classList;
  next.add('vt-swap', 'routed');
  if (root.classList.contains('js')) {
    next.add('js');
  }
  if (root.classList.contains('hero-seen') || heroSeen()) {
    next.add('hero-seen');
  }
});

onPage(() => root.classList.remove('vt-swap'));
