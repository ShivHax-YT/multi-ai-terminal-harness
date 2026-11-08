// Read-only pieces of the plan screen. Every string the lead wrote goes through UntrustedText (plan text is
// untrusted data); paths, branch names and hashes are mono.
import { OctagonX } from "lucide-react";
import type { ReactNode } from "react";

import {
  Meter,
  ProviderName,
  StatusChip,
  UntrustedText,
  type StatusTone,
} from "@/components/common";
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import type {
  LimitsInfo,
  PlanEstimate,
  PlanStatus,
  PlanView,
  PlanViolation,
  Task,
} from "@/lib/ipc";
import { providerLabel } from "@/strings/providers";

import { authModeLabel, shortHash } from "./plan-logic";

const STATUS: Record<PlanStatus, { tone: StatusTone; label: string }> = {
  draft: { tone: "info", label: "Draft" },
  approved: { tone: "success", label: "Approved" },
  running: { tone: "info", label: "Running" },
  done: { tone: "success", label: "Done" },
  superseded: { tone: "neutral", label: "Superseded" },
};

export function PlanHeader({ view }: { view: PlanView }) {
  const n = view.plan.tasks.length;
  const status = STATUS[view.status];
  return (
    <header className="space-y-2">
      <div className="flex flex-wrap items-baseline justify-between gap-3">
        <h2 className="text-xl font-semibold">
          Plan: <UntrustedText text={view.plan.request_summary} />
        </h2>
        <span className="font-mono text-[13px] text-muted-foreground">
          hash {shortHash(view.plan_hash)}
        </span>
      </div>
      <div className="flex flex-wrap items-center gap-3 text-sm text-muted-foreground">
        <span>
          {String(n)} {n === 1 ? "task" : "tasks"}
        </span>
        <StatusChip tone={status.tone} label={status.label} />
      </div>
    </header>
  );
}

export function Violations({ violations }: { violations: PlanViolation[] }) {
  if (violations.length === 0) return null;
  return (
    <Alert variant="destructive" aria-label="Plan violations">
      <OctagonX aria-hidden="true" />
      <AlertTitle>This plan cannot be approved yet</AlertTitle>
      <AlertDescription>
        <ul className="max-w-[65ch] space-y-1">
          {violations.map((v, i) => (
            <li key={`${String(v.rule)}-${v.task_id ?? ""}-${String(i)}`}>
              <span className="font-semibold">Blocked by rule {String(v.rule)}</span>
              {v.task_id !== undefined && (
                <>
                  {" "}
                  (<UntrustedText text={v.task_id} mono />)
                </>
              )}
              : <UntrustedText text={v.message} />
            </li>
          ))}
        </ul>
      </AlertDescription>
    </Alert>
  );
}

function Field({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="space-y-0.5">
      <dt className="text-xs text-muted-foreground">{label}</dt>
      <dd className="text-sm">{children}</dd>
    </div>
  );
}

export function TaskCard({
  task,
  violations,
  controls,
}: {
  task: Task;
  violations: PlanViolation[];
  controls: ReactNode;
}) {
  const own = violations.filter((v) => v.task_id === task.id);
  return (
    <section
      role="group"
      aria-label={`Task ${task.id}`}
      className="space-y-3 rounded-xl border bg-card p-4 text-card-foreground"
    >
      <div className="flex flex-wrap items-baseline gap-x-4 gap-y-1">
        <UntrustedText text={task.id} mono className="font-semibold" />
        <span className="text-sm">{task.role}</span>
        <span className="text-sm">
          <ProviderName id={task.provider} /> ({authModeLabel(task.auth_mode)})
        </span>
        <span className="text-sm text-muted-foreground">
          {String(task.owned_files.length)} {task.owned_files.length === 1 ? "file" : "files"}
        </span>
        {own.length > 0 && <StatusChip tone="danger" label="Blocked" />}
      </div>
      <UntrustedText text={task.title} block className="font-medium" />
      <dl className="grid gap-3 md:grid-cols-2">
        <Field label="Owned files">
          {task.owned_files.length === 0 ? (
            "None"
          ) : (
            <ul className="space-y-0.5">
              {task.owned_files.map((f) => (
                <li key={f}>
                  <UntrustedText text={f} mono className="break-all" />
                </li>
              ))}
            </ul>
          )}
        </Field>
        <Field label="Fallbacks">
          {task.fallback_providers.length === 0 ? (
            "None"
          ) : (
            <ul className="space-y-0.5">
              {task.fallback_providers.map((f, i) => (
                <li key={`${f.provider}-${String(i)}`}>
                  <ProviderName id={f.provider} /> ({authModeLabel(f.auth_mode)})
                </li>
              ))}
            </ul>
          )}
        </Field>
        <Field label="Acceptance">
          <ul className="list-disc space-y-0.5 pl-5">
            {task.acceptance.map((a, i) => (
              <li key={`${a}-${String(i)}`}>
                <UntrustedText text={a} />
              </li>
            ))}
          </ul>
        </Field>
        <Field label="Depends on">
          {task.depends_on.length === 0 ? (
            "Nothing"
          ) : (
            <UntrustedText text={task.depends_on.join(", ")} mono />
          )}
        </Field>
      </dl>
      {controls !== null && <div className="flex flex-wrap gap-2">{controls}</div>}
    </section>
  );
}

function estimateLabel(e: PlanEstimate): string {
  return `${e.provider}/${e.auth_mode}`;
}

/** Estimates against the compiled-in ceilings (rule 1). API-key estimates fall under spend caps instead. */
export function Estimates({
  estimates,
  limits,
}: {
  estimates: PlanEstimate[];
  limits: LimitsInfo | undefined;
}) {
  if (estimates.length === 0) return null;
  const promptCeiling = limits?.rules.prompts_per_hour.ceiling;
  const turnCeiling = limits?.rules.turns_per_task.ceiling;
  return (
    <section aria-label="Estimated usage" className="space-y-3">
      <h3 className="text-base font-semibold">Estimated usage</h3>
      <div className="grid max-w-[65ch] gap-4">
        {estimates.map((e) => (
          <div key={estimateLabel(e)} className="space-y-2">
            <p className="text-sm text-muted-foreground">
              <ProviderName id={e.provider} /> ({authModeLabel(e.auth_mode)}): {String(e.prompts)}{" "}
              prompts, up to {String(e.max_task_turns)} turns in one task
              {promptCeiling !== undefined && e.auth_mode === "subscription"
                ? ` (ceiling ${String(promptCeiling)} prompts per hour, ${String(turnCeiling)} turns per task)`
                : ""}
            </p>
            {e.auth_mode === "subscription" && promptCeiling !== undefined && (
              <Meter
                label={`${labelOf(e)} prompts per hour`}
                current={e.prompts}
                limit={promptCeiling}
              />
            )}
            {e.auth_mode === "subscription" && turnCeiling !== undefined && (
              <Meter
                label={`${labelOf(e)} turns in the longest task`}
                current={e.max_task_turns}
                limit={turnCeiling}
              />
            )}
            {e.auth_mode === "api_key" && (
              <p className="text-sm text-muted-foreground">
                API key runs are limited by the spend cap, not by prompts per hour.
              </p>
            )}
          </div>
        ))}
      </div>
    </section>
  );
}

function labelOf(e: PlanEstimate): string {
  return providerLabel(e.provider);
}
