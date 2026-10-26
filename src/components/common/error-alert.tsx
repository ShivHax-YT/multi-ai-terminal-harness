// Shows an IPC rejection. Compliance refusals read "Blocked by rule N: <message>" (contract convention).
import { OctagonX, ShieldAlert } from "lucide-react";
import type { ReactNode } from "react";

import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { toIpcRejection, type IpcError } from "@/lib/ipc/contract";

import { UntrustedText } from "./untrusted-text";

/** "Blocked by rule 3" for rule refusals, else a plain title per error kind. */
export function errorTitle(error: IpcError): string {
  switch (error.kind) {
    case "rule_blocked":
      return error.rule === undefined
        ? "Blocked by a hard rule"
        : `Blocked by rule ${String(error.rule)}`;
    case "not_found":
      return "Not found";
    case "invalid_input":
      return "Check the input";
    case "plan_hash_mismatch":
      return "The plan changed";
    case "plan_has_violations":
      return "The plan has open violations";
    case "rate_limited":
      return "Rate limited";
    case "not_implemented":
      return "Not available yet";
    case "internal":
      return "Something went wrong";
  }
}

export interface ErrorAlertProps {
  error: unknown;
  /** Optional action, such as a Retry button. */
  action?: ReactNode;
  className?: string;
}

export function ErrorAlert({ error, action, className }: ErrorAlertProps) {
  const e = toIpcRejection(error);
  const blocked = e.kind === "rule_blocked";
  const Icon = blocked ? ShieldAlert : OctagonX;
  return (
    <Alert variant="destructive" className={className}>
      <Icon aria-hidden="true" />
      <AlertTitle>{blocked ? `${errorTitle(e)}:` : errorTitle(e)}</AlertTitle>
      <AlertDescription>
        <UntrustedText text={e.message} />
        {action}
      </AlertDescription>
    </Alert>
  );
}
