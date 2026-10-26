import { useState } from "react";
import { createHashRouter, RouterProvider } from "react-router";

import type { IpcBundle } from "@/lib/ipc";

import { AppProviders } from "./providers";
import { routes } from "./routes";

/** The whole app for one IPC bundle (Tauri in production, the mock in dev and tests). Hash router. */
export function App({ bundle }: { bundle: IpcBundle }) {
  const [router] = useState(() => createHashRouter(routes));
  return (
    <AppProviders bundle={bundle}>
      <RouterProvider router={router} />
    </AppProviders>
  );
}
