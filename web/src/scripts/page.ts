export function onPage(init: (signal: AbortSignal) => void): void {
  let ctrl: AbortController | undefined = undefined;
  let stale = false;
  const run = (): void => {
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
    if (stale) {
      run();
    }
  });
  run();
}

export interface PageTimer {
  clear: () => void;
  set: (fn: () => void, ms: number) => void;
}

const hold = (ms: number): Animation => document.documentElement.animate(null, ms);

export const pause = (ms: number): Promise<unknown> => hold(ms).finished;

export function pageTimer(signal: AbortSignal): PageTimer {
  let held: Animation | null = null;
  const clear = (): void => held?.cancel();
  signal.addEventListener('abort', clear, { once: true });
  return {
    clear,
    set: (fn: () => void, ms: number): void => {
      clear();
      held = hold(ms);
      held.addEventListener('finish', fn);
    },
  };
}

export function observe(
  signal: AbortSignal,
  cb: IntersectionObserverCallback,
  opts?: IntersectionObserverInit,
): IntersectionObserver | null {
  if (!('IntersectionObserver' in globalThis)) {
    return null;
  }
  const io = new IntersectionObserver(cb, opts);
  signal.addEventListener('abort', () => io.disconnect(), { once: true });
  return io;
}
