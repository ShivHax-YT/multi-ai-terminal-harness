// Rule 9: the only way to approve a plan. Importable only from src/features/plan/** (ESLint import zone and
// src/test/ipc-boundaries.test.ts). The backend mints an approval token only for this call, bound to the plan hash
// the user reviewed; the UI must call it only from a user click.

import type { ApprovalPort } from "./contract";
import { useIpcBundle } from "./context";

export type { ApprovalPort };

export function useApproval(): ApprovalPort {
  return useIpcBundle().approval;
}
