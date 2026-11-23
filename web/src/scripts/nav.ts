import { onPage } from './page';

const root = document.documentElement;
const frost = (): boolean => root.classList.toggle('is-scrolled', scrollY > 24);
document.addEventListener('astro:after-swap', frost);

onPage((signal) => {
  frost();
  addEventListener('scroll', frost, { passive: true, signal });

  const menu = document.querySelector<HTMLElement>('#site-menu');
  menu?.addEventListener(
    'click',
    (event) => {
      if ((event.target as Element).closest('a')) {
        menu.hidePopover?.();
      }
    },
    { signal },
  );
  signal.addEventListener('abort', () => menu?.matches(':popover-open') && menu.hidePopover(), {
    once: true,
  });

  const here = location.pathname.replace(/\/$/u, '') || '/';
  for (const link of document.querySelectorAll<HTMLAnchorElement>('[data-nav-link]')) {
    if (new URL(link.href).pathname === here) {
      link.setAttribute('aria-current', 'page');
    } else {
      link.removeAttribute('aria-current');
    }
  }
});
