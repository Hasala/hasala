export interface FakeHold {
  readonly ms: number;
  readonly finished: Promise<void>;
  waiting: boolean;
  finish: () => void;
  cancel: () => void;
  addEventListener: (type: string, fn: () => void) => void;
}

export interface FakeRoot {
  holds: FakeHold[];
  animate: (frames: null, ms: number) => FakeHold;
  waiting: () => number[];
  finish: (ms?: number) => void;
}

function fakeHold(ms: number): FakeHold {
  const listeners: (() => void)[] = [];
  const settle: { resolve: () => void } = { resolve: () => {} };
  const finished = new Promise<void>((resolve) => {
    settle.resolve = resolve;
  });
  const hold: FakeHold = {
    ms,
    finished,
    waiting: true,
    finish: () => {
      if (!hold.waiting) {
        return;
      }
      hold.waiting = false;
      settle.resolve();
      for (const listener of listeners) {
        listener();
      }
    },
    cancel: () => {
      hold.waiting = false;
    },
    addEventListener: (type, fn) => {
      if (type === 'finish') {
        listeners.push(fn);
      }
    },
  };
  return hold;
}

export function fakeRoot(): FakeRoot {
  const holds: FakeHold[] = [];
  return {
    holds,
    animate: (_frames, ms) => {
      const hold = fakeHold(ms);
      holds.push(hold);
      return hold;
    },
    waiting: () => holds.filter((hold) => hold.waiting).map((hold) => hold.ms),
    finish: (ms) => {
      for (const hold of holds.filter(
        (each) => each.waiting && (ms === undefined || each.ms === ms),
      )) {
        hold.finish();
      }
    },
  };
}

export async function settled(turns = 50): Promise<void> {
  if (turns > 0) {
    await Promise.resolve();
    await settled(turns - 1);
  }
}
export const PENDING = 'pending';

export async function stillPending(): Promise<typeof PENDING> {
  await settled();
  return PENDING;
}

export function keepGlobals(names: readonly string[]): () => void {
  const globals = globalThis as unknown as Record<string, unknown>;
  const present = new Map<string, unknown>();
  for (const name of names) {
    if (name in globals) {
      present.set(name, globals[name]);
    }
  }
  return () => {
    for (const name of names) {
      if (present.has(name)) {
        globals[name] = present.get(name);
      } else {
        Reflect.deleteProperty(globals, name);
      }
    }
  };
}
