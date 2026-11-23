import { onPage } from './page';

const root = document.documentElement;

function at(y: number): string {
  for (const el of document.querySelectorAll('main > *, body > footer')) {
    const rect = el.getBoundingClientRect();
    if (rect.top <= y && y < rect.bottom) {
      const style = getComputedStyle(el);
      return `color-mix(in srgb, ${style.getPropertyValue('--edge-t')}, ${style.getPropertyValue('--edge-b')} ${Math.round(((y - rect.top) / rect.height) * 100)}%)`;
    }
  }
  return '';
}

const set = (el: HTMLElement | null, name: string, color: string): void => {
  if (color) {
    el?.style.setProperty(name, color);
  } else {
    el?.style.removeProperty(name);
  }
};

onPage((signal) => {
  let frame = 0;
  let last = '';
  const stripTop = document.querySelector<HTMLElement>('.edge-top');
  const stripBottom = document.querySelector<HTMLElement>('.edge-bottom');
  const update = (): void => {
    frame = 0;
    const top = at(0);
    const bottom = at(innerHeight - 1);
    if (top + bottom === last) {
      return;
    }
    last = top + bottom;
    set(root, 'background-color', top);
    set(stripTop, '--edge-top', top);
    set(stripBottom, '--edge-bottom', bottom);
    document
      .querySelector('meta[name="theme-color"]')
      ?.setAttribute('content', getComputedStyle(root).backgroundColor);
  };
  const queue = (): number => (frame ||= requestAnimationFrame(update));
  const opts = { passive: true, signal };
  addEventListener('scroll', queue, opts);
  addEventListener('resize', queue, opts);
  signal.addEventListener('abort', () => cancelAnimationFrame(frame));
  update();
});
