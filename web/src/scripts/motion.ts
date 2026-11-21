import { onPage, observe } from './page';

export const reducedMotion = (): boolean => typeof matchMedia === 'function' && matchMedia('(prefers-reduced-motion: reduce)').matches;

const once = (signal: AbortSignal, els: Iterable<Element>, threshold: number, fn: (el: HTMLElement) => void) => {
  const io = observe(
    signal,
    (entries, obs) => {
      for (const e of entries) {
        if (!e.isIntersecting) continue;
        obs.unobserve(e.target);
        fn(e.target as HTMLElement);
      }
    },
    { threshold },
  );
  for (const el of els) io ? io.observe(el) : fn(el as HTMLElement);
};

const inView = (el: Element) => {
  const r = el.getBoundingClientRect();
  return r.top < innerHeight && r.bottom > 0;
};

function reveals(signal: AbortSignal) {
  const els = [...document.querySelectorAll<HTMLElement>('[data-reveal]')];
  if (!els.length) return;
  if (reducedMotion() || !('IntersectionObserver' in window)) {
    els.forEach((el) => el.classList.add('is-in'));
    return;
  }
  const counts = new Map<Element | null, number>();
  els.forEach((el) => {
    const n = counts.get(el.parentElement) ?? 0;
    counts.set(el.parentElement, n + 1);
    el.style.setProperty('--i', String(Math.min(n, 3)));
  });
  const vis = els.filter(inView);
  if (vis.length) {
    const root = document.documentElement;
    root.classList.add('reveal-instant');
    vis.forEach((el) => el.classList.add('is-in'));
    void root.offsetHeight;
    root.classList.remove('reveal-instant');
  }
  once(
    signal,
    els.filter((el) => !el.classList.contains('is-in')),
    0.15,
    (el) => el.classList.add('is-in', 'is-scrolled-in'),
  );
}

const fmt = new Intl.NumberFormat('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const easeInOut = (t: number) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);

function pace(signal: AbortSignal) {
  const card = document.querySelector<HTMLElement>('[data-pace]');
  if (!card || reducedMotion()) return;
  const value = card.querySelector<HTMLElement>('[data-count]');
  const fill = card.querySelector<HTMLElement>('.pace__fill');
  const today = card.querySelector<HTMLElement>('.pace__today');
  const verdict = card.querySelector<HTMLElement>('.pace__verdict');
  if (!value || !fill || !today || !verdict) return;
  const target = Number(value.dataset.count);
  if (card.getBoundingClientRect().top < innerHeight) return;
  card.setAttribute('data-armed', '');
  value.textContent = fmt.format(0);
  once(signal, [card], 0.4, () => {
    const start = performance.now();
    const step = (now: number) => {
      if (signal.aborted) return;
      const t = Math.min(1, (now - start) / 900);
      value.textContent = fmt.format(target * easeInOut(t));
      if (t < 1) requestAnimationFrame(step);
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

function parallax(signal: AbortSignal) {
  if (reducedMotion()) return;
  const els = [...document.querySelectorAll<HTMLElement>('[data-parallax]')];
  if (!els.length) return;
  let ticking = false;
  const update = () => {
    ticking = false;
    const vh = innerHeight;
    for (const el of els) {
      const r = el.getBoundingClientRect();
      if (r.bottom < -100 || r.top > vh + 100) continue;
      const offset = Math.max(-40, Math.min(40, (r.top + r.height / 2 - vh / 2) * 0.06));
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

let started = false;
export function initMotion(): void {
  if (started) return;
  started = true;
  onPage((signal) => {
    reveals(signal);
    pace(signal);
    parallax(signal);
  });
}
