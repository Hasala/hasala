/**
 * The review deck (components/detail/Review.astro), on the landing and on
 * /how-it-works. Motion moment D, "Review · the swipe loop": the first time
 * the stage is in view, three cards are swiped (each to its own direction)
 * and the deck rests on the fourth. It plays once, in under five seconds, and
 * stops for good on hover, focus, a hidden tab or any interaction, so nothing
 * moves on its own for long (WCAG 2.2.2). After that the visitor sorts: drag
 * or flick the top card, tap a pill, a legend chip or Use, or press an arrow
 * key on the focused deck. After the last card the deck says "All caught up"
 * and offers Start again; Undo puts the last card back. Only the visitor's
 * own choices are announced to screen readers. With reduced motion nothing
 * plays on its own and a choice crossfades to the next card.
 */
import { reducedMotion } from './motion';
import { observe, onPage } from './page';

type Dir = 'need' | 'want' | 'save' | 'transfer';
const DIRS: Dir[] = ['need', 'want', 'save', 'transfer'];
const LABEL: Record<Dir, string> = {
  need: 'Need',
  want: 'Want',
  save: 'Save',
  transfer: 'Transfer',
};
const KEYS: Record<string, Dir> = {
  ArrowRight: 'need',
  ArrowLeft: 'want',
  ArrowDown: 'save',
  ArrowUp: 'transfer',
};
const OUT: Record<Dir, [number, number, number]> = {
  need: [1.4, 0, 16],
  want: [-1.4, 0, -16],
  save: [0, 1.2, 4],
  transfer: [0, -1.2, -4],
};
const EASE_OUT = 'cubic-bezier(.22,1,.36,1)';
const enum Phase {
  Idle = 0,
  Dragging = 1,
  Leaving = 2,
}
const wait = (ms: number): Promise<unknown> =>
  new Promise((resolve) => {
    setTimeout(resolve, ms);
  });

const tint = (card: HTMLElement, dir: Dir, amount: number): void => {
  const layer = card.querySelector<HTMLElement>(`.rcard__tint--${dir}`);
  if (layer) {
    layer.style.opacity = String(amount);
  }
};

const appear = (el: HTMLElement): void => {
  if (!reducedMotion()) {
    el.animate(
      [
        { opacity: 0, transform: 'scale(.96)' },
        { opacity: 1, transform: 'none' },
      ],
      { duration: 240, easing: 'ease-out' },
    );
  }
};

const band = (delta: number): number => {
  const over = Math.abs(delta) - 140;
  return over <= 0 ? delta : Math.sign(delta) * (140 + (over * 0.55 * 300) / (300 + 0.55 * over));
};

export function initReview(): void {
  onPage(setup);
}

function setup(signal: AbortSignal): void {
  const stage = document.querySelector<HTMLElement>('[data-review]');
  if (!stage) {
    return;
  }
  const find = <T extends HTMLElement>(selector: string): T | null =>
    stage.querySelector<T>(selector);
  const cards = [...stage.querySelectorAll<HTMLElement>('.rcard')];
  const count = cards.length;
  const total = Number(stage.dataset.total) || count + 1;
  const deck = find('.deck')!;
  const done = find('[data-review-done]')!;
  const toast = find('.toast')!;
  const toastText = find('[data-toast-text]')!;
  const counter = find('[data-review-count]');
  const progress = find('[data-review-progress]');
  const live = find('[data-review-live]');
  const pills = new Map<Dir, HTMLElement>();
  stage
    .querySelectorAll<HTMLElement>('[data-sort]')
    .forEach((button) => pills.set(button.dataset.sort as Dir, button));
  // The legend beside the stage: lights up with the swipe and sorts on tap.
  const section = stage.closest('section') ?? document;
  const legends = new Map<Dir, HTMLElement>();
  DIRS.forEach((dir) => {
    const legend = section.querySelector<HTMLElement>(`.dir--${dir}`);
    if (legend) {
      legends.set(dir, legend);
    }
  });

  let top = 0;
  let phase: Phase = Phase.Idle;
  let undoAsked = false;
  let timer = 0;
  let inView = false;
  let paused = false;
  let played = false;
  // The demo's lean, while it runs: a touch on the card cancels it.
  let autoLean: (() => void) | null = null;

  const say = (text: string): string | null => live && (live.textContent = text);
  const lit = (dir: Dir | null): void =>
    DIRS.forEach((each) => legends.get(each)?.toggleAttribute('data-active', each === dir));

  const layout = (): void => {
    cards.forEach((card, index) => {
      let pos = 'x';
      if (index === top) {
        pos = '0';
      } else if (index === top + 1) {
        pos = '1';
      }
      card.dataset.pos = pos;
      card.style.transform = '';
      card.style.opacity = '';
      if (pos === '0') {
        card.removeAttribute('aria-hidden');
      } else {
        card.setAttribute('aria-hidden', 'true');
      }
      card
        .querySelectorAll<HTMLElement>('.rcard__tint')
        .forEach((layer) => (layer.style.opacity = ''));
    });
    const end = top >= count;
    deck.dataset.left = String(count - top);
    done.hidden = !end;
    stage.toggleAttribute('data-done', end);
    legends.forEach((legend) => legend.toggleAttribute('aria-disabled', end));
    const at = Math.min(top + 2, total); // "2 of 6" for the first card, as in the app
    if (counter) {
      counter.textContent = String(at);
    }
    // The first card's 2/6 is the stylesheet's, so nothing moves on load.
    if (progress) {
      progress.style.clipPath = top
        ? `inset(0 ${((1 - (end ? 1 : at / total)) * 100).toFixed(3)}% 0 0 round 3px)`
        : '';
    }
  };

  const showToast = (dir: Dir, announce: boolean): void => {
    toastText.textContent = `Sorted as ${LABEL[dir]}`;
    if (announce) {
      say(
        `Sorted as ${LABEL[dir]}. ${top + 1 >= count ? 'All caught up. ' : ''}Undo is available.`,
      );
    }
    toast.toggleAttribute('data-show', true);
    window.clearTimeout(Number(toast.dataset.t));
    toast.dataset.t = String(window.setTimeout(() => toast.removeAttribute('data-show'), 2200));
  };

  // The next card, or the "All caught up" panel, settles into place.
  const advance = (): void => {
    top += 1;
    lit(null);
    layout();
    if (top >= count) {
      done.animate(
        [
          { opacity: 0, transform: 'scale(.96)' },
          { opacity: 1, transform: 'none' },
        ],
        { duration: 240, easing: EASE_OUT },
      );
    }
  };

  async function swipe(
    dir: Dir,
    opts: { drag?: boolean; auto?: boolean; speed?: number } = {},
  ): Promise<void> {
    if (phase !== Phase.Idle || top >= count) {
      return;
    }
    phase = Phase.Leaving;
    undoAsked = false;
    const card = cards[top];
    const next = cards[top + 1];
    const pill = pills.get(dir);
    if (reducedMotion()) {
      const fade = card.animate([{ opacity: 1 }, { opacity: 0 }], {
        duration: 200,
        fill: 'forwards',
      });
      await fade.finished;
      showToast(dir, !opts.auto);
      advance();
      fade.cancel();
      (cards[top] ?? done).animate([{ opacity: 0 }, { opacity: 1 }], { duration: 200 });
      settle();
      return;
    }
    const width = stage!.clientWidth;
    const [ox, oy, rot] = OUT[dir];
    if (!opts.drag) {
      // 700 → 1220 ms: the drag. The card leans, the tint grows, the pill swells.
      pill?.toggleAttribute('data-active', true);
      lit(dir);
      const lean = card.animate(
        [
          { transform: 'none' },
          { transform: `translate(${ox * 40}px, ${oy * 40}px) rotate(${rot * 0.38}deg)` },
        ],
        { duration: 520, easing: EASE_OUT, fill: 'forwards' },
      );
      card
        .querySelector<HTMLElement>(`.rcard__tint--${dir}`)
        ?.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 520, fill: 'forwards' });
      if (opts.auto) {
        autoLean = () => {
          autoLean = null;
          card.getAnimations({ subtree: true }).forEach((animation) => animation.cancel());
          pill?.removeAttribute('data-active');
          lit(null);
          phase = Phase.Idle;
        };
      }
      const leaned = await lean.finished.then(
        () => true,
        () => false,
      );
      autoLean = null;
      if (!leaned) {
        return;
      } // grabbed mid-lean: the card is the visitor's now
    }
    // 1220 → 1500 ms: commit. Out it goes; the toast rises with Undo. A
    // drag leaves from where the finger let go at the finger's speed: this
    // curve starts at 2× its average speed, so 2·distance / release speed
    // (clamped to 180–320 ms) carries the flick on without a lurch. The
    // demo, starting from rest, accelerates away.
    const from =
      card.getAnimations().length > 0
        ? getComputedStyle(card).transform
        : card.style.transform || 'none';
    const tx = ox * width;
    const ty = oy * 600;
    let duration = 280;
    if (opts.drag) {
      const matrix = new DOMMatrixReadOnly(from === 'none' ? undefined : from);
      const dist = Math.hypot(tx - matrix.e, ty - matrix.f);
      duration = Math.min(320, Math.max(180, (2 * dist) / Math.max(opts.speed ?? 0, 1)));
    }
    const fly = card.animate(
      [
        { transform: from, opacity: 1 },
        { transform: `translate(${tx}px, ${ty}px) rotate(${rot}deg)`, opacity: 0 },
      ],
      {
        duration,
        easing: opts.drag ? 'cubic-bezier(.3,.6,.4,1)' : 'cubic-bezier(.5,0,.75,0)',
        fill: 'forwards',
      },
    );
    showToast(dir, !opts.auto);
    // 1500 → 1740 ms: the peek card scales up and lifts into place.
    next?.animate([{ transform: 'translateY(10px) scale(0.96)' }, { transform: 'none' }], {
      duration: 240,
      delay: 200,
      easing: EASE_OUT,
      fill: 'forwards',
    });
    await fly.finished;
    await wait(240);
    pill?.removeAttribute('data-active');
    card.getAnimations({ subtree: true }).forEach((animation) => animation.cancel());
    next?.getAnimations().forEach((animation) => animation.cancel());
    advance();
    settle();
  }

  const settle = (): void => {
    phase = Phase.Idle;
    if (undoAsked) {
      undo();
    }
  };

  const undo = (): void => {
    undoAsked = phase === Phase.Leaving;
    if (phase !== Phase.Idle || !top) {
      return;
    }
    top -= 1;
    layout();
    toast.removeAttribute('data-show');
    say('Undone.');
    appear(cards[top]);
  };

  const restart = (): void => {
    top = 0;
    layout();
    toast.removeAttribute('data-show');
    // The button that was pressed is gone; keep focus on the deck.
    deck.focus();
    say(`Back to the first card, ${cards[0].querySelector('.rcard__merchant')?.textContent}.`);
    appear(cards[0]);
  };

  // Autoplay, once: the first three cards, each to its own direction.
  const PLAN = cards.slice(0, 3).map((card) => card.dataset.to as Dir);
  let running = false;
  async function play(): Promise<void> {
    if (played || running) {
      return;
    }
    running = true;
    for (const dir of PLAN) {
      await wait(500);
      if (!canPlay()) {
        break;
      }
      played = true; // once a card has moved, the demo never starts again
      await swipe(dir, { auto: true });
    }
    running = false;
  }
  const canPlay = (): boolean =>
    !signal.aborted && inView && !paused && !document.hidden && !reducedMotion();
  signal.addEventListener('abort', () => {
    window.clearTimeout(timer);
    window.clearTimeout(Number(toast.dataset.t));
  });
  const schedule = (): void => {
    window.clearTimeout(timer);
    if (!played && canPlay()) {
      timer = window.setTimeout(play, 300);
    }
  };

  // Hover, focus or a touch stops the demo for good: the visitor is in charge.
  const stop = (): boolean => (paused = true);
  stage.addEventListener('pointerenter', (event) => {
    if (event.pointerType === 'mouse') {
      stop();
    }
  });
  stage.addEventListener('focusin', stop);
  document.addEventListener('visibilitychange', schedule, { signal });

  observe(
    signal,
    ([entry]) => {
      inView = entry.isIntersecting;
      schedule();
    },
    { threshold: 0.4 },
  )?.observe(stage);

  // Pills in the stage and legend chips beside it.
  section.querySelectorAll<HTMLElement>('[data-sort]').forEach((btn) =>
    btn.addEventListener('click', () => {
      stop();
      void swipe(btn.dataset.sort as Dir);
    }),
  );
  find('[data-undo]')?.addEventListener('click', undo);
  find('[data-review-restart]')?.addEventListener('click', restart);
  // Use takes Hasala's guess: the card goes where it belongs.
  stage.addEventListener('click', (event) => {
    const card = (event.target as Element)
      .closest('[data-use]')
      ?.closest<HTMLElement>('.rcard[data-pos="0"]');
    if (card) {
      void swipe(card.dataset.to as Dir);
    }
  });
  deck.addEventListener('keydown', (event) => {
    const dir = KEYS[event.key];
    if (!dir || event.target !== deck) {
      return;
    }
    event.preventDefault();
    stop();
    void swipe(dir);
  });

  // Drag to try. A flick commits as well as a long drag: the release speed
  // comes from the last few pointer samples. Past 140 px the card drags with
  // rising resistance. A second finger is ignored.
  let startX = 0;
  let startY = 0;
  let dx = 0;
  let dy = 0;
  let id = 0;
  let samples: [number, number, number][] = [];
  stage.addEventListener('pointerdown', (event) => {
    // Use is a tap, not a drag: no capture, so its click lands on it.
    stop();
    if ((event.target as Element).closest('[data-use]')) {
      return;
    }
    const card = (event.target as Element).closest<HTMLElement>('.rcard[data-pos="0"]');
    if (!card) {
      return;
    }
    autoLean?.();
    if (phase !== Phase.Idle) {
      return;
    }
    phase = Phase.Dragging;
    id = event.pointerId;
    startX = event.clientX;
    startY = event.clientY;
    dx = 0;
    dy = 0;
    samples = [[0, 0, event.timeStamp]];
    card.setPointerCapture(event.pointerId);
  });
  stage.addEventListener('pointermove', (event) => {
    if (phase !== Phase.Dragging || event.pointerId !== id) {
      return;
    }
    dx = event.clientX - startX;
    dy = event.clientY - startY;
    samples = [...samples.slice(-2), [dx, dy, event.timeStamp]];
    const card = cards[top];
    const x = band(dx);
    card.style.transform = `translate(${x}px, ${band(dy)}px) rotate(${x / 14}deg)`;
    const dir = dirFor(dx, dy);
    const dist = Math.hypot(dx, dy);
    DIRS.forEach((each) => tint(card, each, each === dir ? Math.min(1, dist / 120) : 0));
    // The legend beside the stage answers the drag, as it does the pills.
    lit(dist > 24 ? dir : null);
  });
  const end = (event: PointerEvent): void => {
    if (phase !== Phase.Dragging || event.pointerId !== id) {
      return;
    }
    phase = Phase.Idle;
    const card = cards[top];
    const [[sx, sy, st]] = samples;
    const speed = Math.hypot(dx - sx, dy - sy) / Math.max(1, event.timeStamp - st);
    // A flick needs some travel too, so a tap that jitters never commits, and
    // a cancel (the page took over to scroll) is never a flick.
    const flick = event.type === 'pointerup' && speed > 0.11 && Math.hypot(dx, dy) > 24;
    const dir = dirFor(dx, dy);
    const commit = Math.hypot(dx, dy) > 90 || flick;
    // The chosen direction's legend stays lit until the card has gone.
    lit(commit ? dir : null);
    if (commit) {
      void swipe(dir, { drag: true, speed });
    } else if (dx || dy) {
      card.animate([{ transform: card.style.transform }, { transform: 'none' }], {
        duration: 240,
        easing: 'cubic-bezier(.34,1.56,.64,1)',
      });
      card.style.transform = '';
      DIRS.forEach((each) => tint(card, each, 0));
    }
  };
  stage.addEventListener('pointerup', end);
  stage.addEventListener('pointercancel', end);

  layout();
}

function dirFor(dx: number, dy: number): Dir {
  if (Math.abs(dx) >= Math.abs(dy)) {
    return dx > 0 ? 'need' : 'want';
  }
  return dy > 0 ? 'save' : 'transfer';
}
