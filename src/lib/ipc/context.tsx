// React wiring for the IPC bundle. Screens use `useIpc()` and `useIpcEvent()` from "@/lib/ipc". The two ports are
// handed out only by ./approval (rule 9) and ./pty-input (rule 3); `useIpcBundle` is internal to src/lib/ipc
// (ESLint import zone + src/test/ipc-boundaries.test.ts).

import { createContext, useContext, useEffect, useRef, type ReactNode } from "react";

import type { IpcBundle, IpcClient, IpcEventName, IpcEvents } from "./contract";

const IpcContext = createContext<IpcBundle | null>(null);

export function IpcProvider({ bundle, children }: { bundle: IpcBundle; children: ReactNode }) {
  return <IpcContext.Provider value={bundle}>{children}</IpcContext.Provider>;
}

/** Internal to src/lib/ipc: the whole bundle, ports included. */
export function useIpcBundle(): IpcBundle {
  const bundle = useContext(IpcContext);
  if (bundle === null) throw new Error("useIpc must be used inside <IpcProvider>");
  return bundle;
}

/** The general client. It has no generic invoke and no approve_plan or pty_write. */
export function useIpc(): IpcClient {
  return useIpcBundle().client;
}

/** Subscribes to a backend event for the component's lifetime. Payloads are full snapshots. */
export function useIpcEvent<E extends IpcEventName>(
  event: E,
  handler: (payload: IpcEvents[E]) => void,
): void {
  const client = useIpc();
  const ref = useRef(handler);
  useEffect(() => {
    ref.current = handler;
  });
  useEffect(() => {
    let unlisten: (() => void) | undefined;
    let cancelled = false;
    void client
      .listen(event, (payload) => {
        ref.current(payload);
      })
      .then((fn) => {
        if (cancelled) fn();
        else unlisten = fn;
      });
    return () => {
      cancelled = true;
      unlisten?.();
    };
  }, [client, event]);
}
