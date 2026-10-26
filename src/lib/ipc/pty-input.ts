// Rule 3: the only way to type into a PTY. Importable only from src/features/sessions/terminal/** (ESLint import zone
// and src/test/ipc-boundaries.test.ts), where it is called only from xterm.js onData (human keystrokes). The backend
// refuses it unless that session's take-over is on.

import type { PtyInputPort } from "./contract";
import { useIpcBundle } from "./context";

export type { PtyInputPort };

export function usePtyInput(): PtyInputPort {
  return useIpcBundle().ptyInput;
}
