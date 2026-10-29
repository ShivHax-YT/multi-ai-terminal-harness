// The one next step per provider, decided from the status the backend reported. `usable` and `blockers` are the
// backend's answer (rule 4: no CLI files are read here); this module never recomputes them.
import type { Blocker, ProviderStatus } from "@/lib/ipc";

export type StepKind = "check_again" | "confirm" | "sign_in" | "go_to_lead";

export interface NextStep {
  kind: StepKind;
  label: string;
}

const STEPS: Record<StepKind, NextStep> = {
  check_again: { kind: "check_again", label: "Check again" },
  confirm: { kind: "confirm", label: "Confirm it is my account" },
  sign_in: { kind: "sign_in", label: "Sign in in terminal" },
  go_to_lead: { kind: "go_to_lead", label: "Go to Lead" },
};

/** True when a subscription login may be used for this provider (rule 7: never for key-only tools). */
export function subscriptionAllowed(status: ProviderStatus): boolean {
  return status.auth_modes.includes("subscription") && status.killswitch !== "api_key_only";
}

/** The single next step, or null when nothing the user can do here moves it forward. */
export function nextStep(status: ProviderStatus): NextStep | null {
  if (!status.adapter_available) return null;
  if (status.killswitch === "disabled") return null; // rule 12: no action at all
  if (status.install.state === "not_installed") return null; // the install text is copyable instead
  if (status.usable.lead || status.usable.worker) return STEPS.go_to_lead;
  if (status.binary.state !== "verified") return STEPS.check_again; // rule 6: never a sign-in
  if (!subscriptionAllowed(status)) return null; // rule 7: no login path for key-only tools
  if (!status.personal_use_confirmed) return STEPS.confirm; // rule 5
  if (status.sign_in.state !== "signed_in") return STEPS.sign_in;
  return null;
}

/** The first provider, in list order, whose next step is the screen's one filled button. */
export function primaryProvider(
  statuses: readonly ProviderStatus[],
): ProviderStatus["provider"] | null {
  return statuses.find((s) => nextStep(s) !== null)?.provider ?? null;
}

const BLOCKER_SENTENCES: Record<Blocker, string> = {
  adapter_unavailable: "Support for this tool is not available yet.",
  not_installed: "The tool is not installed on this Mac.",
  binary_failed: "The tool failed verification, so automation is off (rule 6).",
  binary_unchecked: "The tool has not been verified yet.",
  signed_out: "You are signed out. Sign in in the tool's own terminal.",
  sign_in_unknown: "The sign-in state is unknown. Check again or sign in in the terminal.",
  personal_use_unconfirmed: "Confirm that this is your own personal account (rule 5).",
  api_key_missing: "Add an API key in Settings to use this tool.",
  killswitch_disabled: "A signed remote config turned this tool off (rule 12).",
  provider_paused: "Paused after repeated rate limits. Resume it from Usage.",
};

/** One plain sentence per blocker. A value this build does not know falls back to a generic sentence. */
export function blockerSentence(blocker: Blocker): string {
  const sentence = (BLOCKER_SENTENCES as Partial<Record<string, string>>)[blocker];
  return sentence ?? "Something blocks this tool.";
}
