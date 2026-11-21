export function onPage(init: (signal: AbortSignal) => void): void {
  let ctrl: AbortController | undefined;
  let stale = false;
  const run = () => {
    ctrl?.abort();
    ctrl = new AbortController();
    stale = false;
    init(ctrl.signal);
  };
  document.addEventListener('astro:before-swap', () => {
    ctrl?.abort();
    ctrl = undefined;
    stale = true;
  });
  document.addEventListener('astro:page-load', () => {
    if (stale) run();
  });
  run();
}

export function pageTimer(signal: AbortSignal) {
  let id = 0;
  const clear = () => window.clearTimeout(id);
  signal.addEventListener('abort', clear, { once: true });
  return {
    clear,
    set: (fn: () => void, ms: number) => {
      clear();
      id = window.setTimeout(fn, ms);
    },
  };
}

export function observe(
  signal: AbortSignal,
  cb: IntersectionObserverCallback,
  opts?: IntersectionObserverInit,
): IntersectionObserver | null {
  if (!('IntersectionObserver' in window)) return null;
  const io = new IntersectionObserver(cb, opts);
  signal.addEventListener('abort', () => io.disconnect(), { once: true });
  return io;
}
