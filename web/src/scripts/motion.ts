/**
 * The page's small dynamic layer ("13 · Dynamic layer"): scroll-linked
 * reveals (B), the pace bar (C) and phone parallax.
 * Nothing loops, nothing moves while text is being read, and everything has
 * a still version: with reduced motion the page is simply shown in its final
 * state.
 */
import { observe, onPage } from './page';

export const reducedMotion = (): boolean => typeof matchMedia === 'function' && matchMedia('(prefers-reduced-motion: reduce)').matches;

const once = (signal: AbortSignal, els: Iterable<Element>, threshold: number, fn: (el: HTMLElement) => void): void => {
  const io = observe(
    signal,
    (entries, obs) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) {continue;}
        obs.unobserve(entry.target);
        fn(entry.target as HTMLElement);
      }
    },
    { threshold },
  );
  for (const el of els) {
    if (io) {io.observe(el);}
    else {fn(el as HTMLElement);}
  }
};

const inView = (el: Element): boolean => {
  const rect = el.getBoundingClientRect();
  return rect.top < innerHeight && rect.bottom > 0;
};

/** B: each section enters once, when 15% of it is in view. Stagger 60 ms, max 4. */
function reveals(signal: AbortSignal): void {
  const els = [...document.querySelectorAll<HTMLElement>('[data-reveal]')];
  if (els.length === 0) {return;}
  if (reducedMotion() || !('IntersectionObserver' in window)) {
    els.forEach((el) => el.classList.add('is-in'));
    return;
  }
  const counts = new Map<Element | null, number>();
  els.forEach((el) => {
    const count = counts.get(el.parentElement) ?? 0;
    counts.set(el.parentElement, count + 1);
    el.style.setProperty('--i', String(Math.min(count, 3)));
  });
  // Already on screen (a deep link, a restored scroll, a client-side
  // navigation): shown as is, with no transition. The hidden state is in
  // force from the first paint (.js, set in <head>), so measuring has already
  // resolved it; switching to is-in under .reveal-instant (transitions off)
  // and flushing styles before lifting it means nothing animates, including
  // the step stories and the plan bar keyed on is-in. Read first, then write.
  const vis = els.filter((el) => inView(el));
  if (vis.length > 0) {
    const root = document.documentElement;
    root.classList.add('reveal-instant');
    vis.forEach((el) => el.classList.add('is-in'));
    void root.offsetHeight;
    root.classList.remove('reveal-instant');
  }
  // is-scrolled-in marks what entered while being watched, so a one-off
  // keyframe moment (the invite coin) never plays on content that was
  // already on screen when the page arrived.
  once(
    signal,
    els.filter((el) => !el.classList.contains('is-in')),
    0.15,
    (el) => el.classList.add('is-in', 'is-scrolled-in'),
  );
}

const fmt = new Intl.NumberFormat('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const easeInOut = (progress: number): number => (progress < 0.5 ? 4 * progress * progress * progress : 1 - (-2 * progress + 2) ** 3 / 2);

/** C: the figure counts up with the bar (900 ms, ease-in-out), the today marker drops in, the verdict lands last. */
function pace(signal: AbortSignal): void {
  const card = document.querySelector<HTMLElement>('[data-pace]');
  if (!card || reducedMotion()) {return;}
  const value = card.querySelector<HTMLElement>('[data-count]');
  const fill = card.querySelector<HTMLElement>('.pace__fill');
  const today = card.querySelector<HTMLElement>('.pace__today');
  const verdict = card.querySelector<HTMLElement>('.pace__verdict');
  if (!value || !fill || !today || !verdict) {return;}
  const target = Number(value.dataset.count);
  // Only arm it if it starts out of view, so nobody sees it reset.
  if (card.getBoundingClientRect().top < innerHeight) {return;}
  card.setAttribute('data-armed', '');
  value.textContent = fmt.format(0);
  once(signal, [card], 0.4, () => {
    const start = performance.now();
    const step = (now: number): void => {
      if (signal.aborted) {return;}
      const progress = Math.min(1, (now - start) / 900);
      value.textContent = fmt.format(target * easeInOut(progress));
      if (progress < 1) {requestAnimationFrame(step);}
    };
    requestAnimationFrame(step);
    fill.animate([{ transform: 'scaleX(0)' }, { transform: 'scaleX(1)' }], { duration: 900, easing: 'cubic-bezier(.65,0,.35,1)', fill: 'forwards' });
    today.animate(
      [
        { opacity: 0, transform: 'translateY(-8px)' },
        { opacity: 1, transform: 'none' },
      ],
      { duration: 160, delay: 900, easing: 'cubic-bezier(.22,1,.36,1)', fill: 'forwards' },
    );
    verdict.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 200, delay: 1100, fill: 'forwards' });
  });
}

/** Phones drift at 0.94× scroll speed, at most 40 px. */
function parallax(signal: AbortSignal): void {
  if (reducedMotion()) {return;}
  const els = [...document.querySelectorAll<HTMLElement>('[data-parallax]')];
  if (els.length === 0) {return;}
  let ticking = false;
  const update = (): void => {
    ticking = false;
    const vh = innerHeight;
    for (const el of els) {
      const rect = el.getBoundingClientRect();
      if (rect.bottom < -100 || rect.top > vh + 100) {continue;}
      const offset = Math.max(-40, Math.min(40, (rect.top + rect.height / 2 - vh / 2) * 0.06));
      el.style.transform = `translate3d(0, ${offset.toFixed(1)}px, 0)`;
    }
  };
  addEventListener(
    'scroll',
    () => {
      if (!ticking) {
        ticking = true;
        requestAnimationFrame(update);
      }
    },
    { passive: true, signal },
  );
  update();
}

/**
 * Once per document: the footer calls it on every page (its top reveals), and
 * the pages with sections of their own call it too. onPage re-runs it after
 * each client-side navigation, so a second registration would run it twice.
 */
let started = false;
export function initMotion(): void {
  if (started) {return;}
  started = true;
  onPage((signal) => {
    reveals(signal);
    pace(signal);
    parallax(signal);
  });
}
