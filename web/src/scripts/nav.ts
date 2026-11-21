import { onPage } from './page';

const root = document.documentElement;
const frost = () => root.classList.toggle('is-scrolled', window.scrollY > 24);
document.addEventListener('astro:after-swap', frost);

onPage((signal) => {
  frost();
  addEventListener('scroll', frost, { passive: true, signal });

  const menu = document.getElementById('site-menu');
  menu?.addEventListener(
    'click',
    (e) => {
      if ((e.target as Element).closest('a')) menu.hidePopover?.();
    },
    { signal },
  );
  signal.addEventListener('abort', () => menu?.matches(':popover-open') && menu.hidePopover(), { once: true });

  const here = location.pathname.replace(/\/$/, '') || '/';
  for (const link of document.querySelectorAll<HTMLAnchorElement>('[data-nav-link]')) {
    if (new URL(link.href).pathname === here) link.setAttribute('aria-current', 'page');
    else link.removeAttribute('aria-current');
  }
});
