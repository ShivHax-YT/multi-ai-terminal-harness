// Pure helpers for the plan screen. No IPC, no React.
import type { AuthMode, PlanView, ProviderAuth, ProviderStatus, Task } from "@/lib/ipc";
import { API_KEY_ONLY_PROVIDER_IDS, MVP_PROVIDER_IDS, type ProviderId } from "@/strings/providers";

/** The sample workflow plans (T-133) use ids like "sim-1"; real plans never do. */
export function isSamplePlanId(id: string | undefined): boolean {
  return id !== undefined && /^sim-\d+$/.test(id);
}

/** First 8 characters of the hash, shown on the button and in the header. */
export function shortHash(hash: string): string {
  return hash.slice(0, 8);
}

/** The approve button exists only for a draft with no violations (rule 9). */
export function canApprove(view: PlanView): boolean {
  return view.status === "draft" && view.violations.length === 0;
}

/** Edit controls exist only for a draft; approved, running, done and superseded plans are read-only. */
export function canEdit(view: PlanView): boolean {
  return view.status === "draft";
}

/** Providers that run at least one task in the plan. */
export function planProviders(view: PlanView): Set<ProviderId> {
  return new Set(view.plan.tasks.map((t) => t.provider));
}

/** Provider options for an edit: the MVP providers plus whatever the plan already uses on this task. */
export function providerOptions(task: Task): ProviderId[] {
  const out: ProviderId[] = [...MVP_PROVIDER_IDS];
  const extra = [task.provider, ...task.fallback_providers.map((f) => f.provider)];
  for (const id of extra) if (!out.includes(id)) out.push(id);
  return out;
}

/** Auth modes a provider may be edited to. Unknown provider: none, so nothing can be saved (fails closed). */
export function authModesFor(
  statuses: readonly ProviderStatus[] | undefined,
  provider: ProviderId,
): ProviderStatus["auth_modes"] {
  const modes = statuses?.find((s) => s.provider === provider)?.auth_modes ?? [];
  return API_KEY_ONLY_PROVIDER_IDS.includes(provider)
    ? modes.filter((mode) => mode === "api_key")
    : modes;
}

/**
 * Fallback providers this edit would add that no task in the plan uses. Such an edit voids approval (rule 9), so the
 * dialog says so before it sends anything.
 */
export function fallbacksOutsidePlan(
  view: PlanView,
  task: Task,
  next: readonly ProviderAuth[],
): ProviderId[] {
  const inPlan = planProviders(view);
  const had = new Set(task.fallback_providers.map((f) => f.provider));
  return next.map((f) => f.provider).filter((p) => !inPlan.has(p) && !had.has(p));
}

export function acceptanceFromText(text: string): string[] {
  return text
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => l !== "");
}

export function authModeLabel(mode: AuthMode): string {
  return mode === "api_key" ? "API key" : "Subscription";
}
