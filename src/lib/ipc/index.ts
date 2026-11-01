// The IPC entry point for screens: `useIpc()`, `useIpcEvent()` and the contract types.
//
// Client selection: native windows always use Tauri, including development builds.
// Browser-only development uses the labelled mock unless VITE_HARNESS_IPC=tauri.
// The mock is loaded by dynamic import on the dev path only, so it tree-shakes out of
// production (`make check` fails if its sentinel reaches dist/).

import { isTauri } from "@tauri-apps/api/core";

import type { IpcBundle } from "./contract";
import { createTauriIpc } from "./tauri";

export * from "./contract";
export { IpcProvider, useIpc, useIpcEvent, useIpcMode } from "./context";

export async function loadIpc(): Promise<IpcBundle> {
  if (import.meta.env.DEV && !isTauri() && import.meta.env.VITE_HARNESS_IPC !== "tauri") {
    const { createDevMockIpc } = await import("./mock");
    return createDevMockIpc(import.meta.env.VITE_HARNESS_MOCK_SCENARIO);
  }
  return createTauriIpc();
}
