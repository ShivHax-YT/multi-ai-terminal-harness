// Plan helpers for the mock backend: hash, violation check and estimates. The real backend is authoritative; these
// mirror docs/spec/plan.md and spike/plan/check.jq closely enough for the UI to show the same states.

import type { Plan, PlanEstimate, PlanViolation } from "../contract";

/** Key-sorted JSON (enough for a mock; the app will use RFC 8785 JCS). */
export function canonicalJson(value: unknown): string {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  const entries = Object.entries(value as Record<string, unknown>)
    .filter(([, v]) => v !== undefined)
    .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
  return `{${entries.map(([k, v]) => `${JSON.stringify(k)}:${canonicalJson(v)}`).join(",")}}`;
}

/** SHA-256 (WebCrypto) of the canonical JSON of the plan without `approval`, lowercase hex. */
export async function planHash(plan: Plan): Promise<string> {
  const { approval: _approval, ...rest } = plan;
  const bytes = new TextEncoder().encode(canonicalJson(rest));
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export interface PlanCheckOptions {
  turnsPerTask: number;
  promptsPerHour: number;
  /** Providers whose status lists only the api_key auth mode (rule 7). */
  apiKeyOnly: ReadonlySet<string>;
}

/** Cross-field rule checks (rules 1, 2, 7, 9) for a well-shaped plan. */
export function checkPlan(plan: Plan, ceilings: PlanCheckOptions): PlanViolation[] {
  const out: PlanViolation[] = [];
  const ids = new Set<string>();
  const usedProviders = new Set(plan.tasks.map((t) => t.provider));
  const keyOnly = (provider: string, authMode: string): boolean =>
    ceilings.apiKeyOnly.has(provider) && authMode !== "api_key";

  for (const task of plan.tasks) {
    if (ids.has(task.id)) out.push({ rule: 9, message: `duplicate task id ${task.id}`, task_id: task.id });
    ids.add(task.id);
    if (task.estimated_usage.turns > ceilings.turnsPerTask) {
      out.push({
        rule: 1,
        message: `estimated turns ${String(task.estimated_usage.turns)} exceed the ceiling of ${String(ceilings.turnsPerTask)} per task`,
        task_id: task.id,
      });
    }
    const seen = new Set<string>();
    for (const fb of task.fallback_providers) {
      if (fb.provider === task.provider) {
        out.push({ rule: 2, message: "a fallback is the task's own provider", task_id: task.id });
      }
      if (seen.has(fb.provider)) {
        out.push({ rule: 2, message: `fallback provider ${fb.provider} is listed twice`, task_id: task.id });
      }
      seen.add(fb.provider);
      if (!usedProviders.has(fb.provider)) {
        out.push({
          rule: 9,
          message: `fallback provider ${fb.provider} is not a task provider in this plan`,
          task_id: task.id,
        });
      }
      if (keyOnly(fb.provider, fb.auth_mode)) {
        out.push({ rule: 7, message: "this fallback provider runs on an API key only", task_id: task.id });
      }
    }
    if (keyOnly(task.provider, task.auth_mode)) {
      out.push({ rule: 7, message: "this provider runs on an API key only", task_id: task.id });
    }
  }
  for (const task of plan.tasks) {
    for (const dep of task.depends_on) {
      if (dep === task.id) out.push({ rule: 9, message: "a task depends on itself", task_id: task.id });
      else if (!ids.has(dep)) {
        out.push({ rule: 9, message: `depends on unknown task ${dep}`, task_id: task.id });
      }
    }
  }
  if (keyOnly(plan.lead.provider, plan.lead.auth_mode)) {
    out.push({ rule: 7, message: "the lead provider runs on an API key only" });
  }
  const promptsByProvider = new Map<string, number>();
  for (const task of plan.tasks) {
    if (task.auth_mode === "api_key") continue;
    promptsByProvider.set(
      task.provider,
      (promptsByProvider.get(task.provider) ?? 0) + task.estimated_usage.prompts,
    );
  }
  for (const [provider, prompts] of promptsByProvider) {
    if (prompts > ceilings.promptsPerHour) {
      out.push({
        rule: 1,
        message: `${provider}: ${String(prompts)} estimated prompts exceed the ceiling of ${String(ceilings.promptsPerHour)}`,
      });
    }
  }
  return out;
}

/** Per provider and auth mode: summed prompts and the largest task turn estimate. */
export function planEstimates(plan: Plan): PlanEstimate[] {
  const byKey = new Map<string, PlanEstimate>();
  for (const task of plan.tasks) {
    const key = `${task.provider}/${task.auth_mode}`;
    const cur = byKey.get(key) ?? {
      provider: task.provider,
      auth_mode: task.auth_mode,
      prompts: 0,
      max_task_turns: 0,
    };
    cur.prompts += task.estimated_usage.prompts;
    cur.max_task_turns = Math.max(cur.max_task_turns, task.estimated_usage.turns);
    byKey.set(key, cur);
  }
  return [...byKey.values()];
}

