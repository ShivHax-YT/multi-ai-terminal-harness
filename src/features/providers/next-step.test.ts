import { describe, expect, it } from "vitest";

import providersJson from "@/lib/ipc/fixtures/providers.json";
import type { Blocker, ProviderStatus } from "@/lib/ipc";

import { blockerSentence, nextStep, primaryProvider, subscriptionAllowed } from "./next-step";

const base = (providersJson as ProviderStatus[]).find((p) => p.provider === "claude");
if (base === undefined) throw new Error("fixture missing");

function status(patch: Partial<ProviderStatus>): ProviderStatus {
  return { ...structuredClone(base as ProviderStatus), ...patch };
}

const unusable = (blockers: Blocker[]): ProviderStatus["usable"] => ({
  lead: false,
  worker: false,
  blockers,
});

describe("nextStep", () => {
  it("offers Go to Lead when the backend says usable, and never recomputes usable", () => {
    expect(nextStep(status({}))?.label).toBe("Go to Lead");
    // The backend's answer wins even if the individual fields look like they would block.
    expect(
      nextStep(status({ sign_in: { state: "signed_out" }, usable: { ...base.usable, lead: true } }))
        ?.kind,
    ).toBe("go_to_lead");
    // And an unusable status is never promoted, whatever the fields say.
    expect(nextStep(status({ usable: unusable(["provider_paused"]) }))).toBeNull();
  });

  it("offers Check again when the binary is not verified, and never a sign-in (rule 6)", () => {
    for (const state of ["failed", "unchecked"] as const) {
      const step = nextStep(
        status({
          binary: { state, checks: [] },
          sign_in: { state: "signed_out" },
          personal_use_confirmed: true,
          usable: unusable(["binary_failed"]),
        }),
      );
      expect(step?.label).toBe("Check again");
    }
  });

  it("offers Confirm before Sign in (rule 5), then Sign in in terminal", () => {
    const signedOut = status({
      sign_in: { state: "signed_out" },
      personal_use_confirmed: false,
      usable: unusable(["signed_out", "personal_use_unconfirmed"]),
    });
    expect(nextStep(signedOut)?.label).toBe("Confirm it is my account");
    expect(nextStep({ ...signedOut, personal_use_confirmed: true })?.label).toBe(
      "Sign in in terminal",
    );
  });

  it("has no step when not installed, unavailable, or turned off (rule 12)", () => {
    expect(
      nextStep(status({ install: { state: "not_installed" }, usable: unusable([]) })),
    ).toBeNull();
    expect(nextStep(status({ adapter_available: false, usable: unusable([]) }))).toBeNull();
    expect(nextStep(status({ killswitch: "disabled" }))).toBeNull();
  });

  it("never offers a sign-in for API-key-only providers or api_key_only kill switches (rules 7 and 12)", () => {
    const keyOnly = status({
      auth_modes: ["api_key"],
      sign_in: { state: "unknown" },
      personal_use_confirmed: false,
      usable: unusable(["api_key_missing"]),
    });
    expect(subscriptionAllowed(keyOnly)).toBe(false);
    expect(nextStep(keyOnly)).toBeNull();
    const switched = status({
      killswitch: "api_key_only",
      sign_in: { state: "signed_out" },
      usable: unusable(["api_key_missing"]),
    });
    expect(nextStep(switched)).toBeNull();
  });
});

describe("primaryProvider", () => {
  it("is the first provider in list order that has a next step", () => {
    const none = status({ install: { state: "not_installed" }, usable: unusable([]) });
    const a = { ...none, provider: "claude" } as const;
    const b = { ...status({}), provider: "codex" } as const;
    const c = { ...status({}), provider: "gemini" } as const;
    expect(primaryProvider([a, b, c])).toBe("codex");
    expect(primaryProvider([a])).toBeNull();
    expect(primaryProvider([])).toBeNull();
  });
});

describe("blockerSentence", () => {
  const ALL: Record<Blocker, true> = {
    adapter_unavailable: true,
    not_installed: true,
    binary_failed: true,
    binary_unchecked: true,
    signed_out: true,
    sign_in_unknown: true,
    personal_use_unconfirmed: true,
    api_key_missing: true,
    killswitch_disabled: true,
    provider_paused: true,
  };

  it("maps every blocker to one plain sentence", () => {
    const seen = new Set<string>();
    for (const blocker of Object.keys(ALL) as Blocker[]) {
      const sentence = blockerSentence(blocker);
      expect(sentence).toMatch(/^[A-Z].*\.$/);
      expect(sentence).not.toBe("Something blocks this tool.");
      seen.add(sentence);
    }
    expect(seen.size).toBe(Object.keys(ALL).length);
  });

  it("falls back for a blocker this build does not know", () => {
    expect(blockerSentence("brand_new" as Blocker)).toBe("Something blocks this tool.");
  });
});
