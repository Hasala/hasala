export type CopyMode = 'clipboard' | 'manual';

export interface InviteCopy {
  copy: () => Promise<boolean>;
  leave: (event: Pick<Event, 'preventDefault'>, go: () => void) => Promise<void>;
}

export function inviteCopy(write: () => Promise<void>, onManual: () => void): InviteCopy {
  let mode: CopyMode = 'clipboard';
  const copy = async (): Promise<boolean> => {
    try {
      await write();
      return true;
    } catch {
      mode = 'manual';
      onManual();
      return false;
    }
  };
  return {
    copy,
    async leave(event: Pick<Event, 'preventDefault'>, go: () => void): Promise<void> {
      if (mode === 'manual') {
        return;
      }
      event.preventDefault();
      if (await copy()) {
        go();
      }
    },
  };
}
