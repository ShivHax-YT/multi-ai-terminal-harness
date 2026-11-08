import { describe, expect, it } from "vitest";

import type { PlanView, ProviderStatus } from "@/lib/ipc";
import planJson from "@/lib/ipc/fixtures/plan.json";

import {
  acceptanceFromText,
  authModesFor,
  canApprove,
  canEdit,
  fallbacksOutsidePlan,
  isSamplePlanId,
  providerOptions,
  shortHash,
} from "./plan-logic";

const plan = planJson as unknown as PlanView["plan"];
function view(over: Partial<PlanView> = {}): PlanView {
  return {
    plan,
    plan_hash: "0123456789abcdef",
    status: "draft",
    violations: [],
    estimates: [],
    needs_reapproval: false,
    ...over,
  };
}

describe("plan-logic", () => {
  it("recognises only sample plan ids", () => {
    expect(isSamplePlanId("sim-12")).toBe(true);
    expect(isSamplePlanId("plan-2026-10-25-001")).toBe(false);
    expect(isSamplePlanId("sim-1/../x")).toBe(false);
    expect(isSamplePlanId(undefined)).toBe(false);
  });

  it("approves only a draft with no violations", () => {
    expect(canApprove(view())).toBe(true);
    expect(canApprove(view({ violations: [{ rule: 1, message: "x" }] }))).toBe(false);
    for (const status of ["approved", "running", "done", "superseded"] as const) {
      expect(canApprove(view({ status }))).toBe(false);
      expect(canEdit(view({ status }))).toBe(false);
    }
    expect(canEdit(view())).toBe(true);
  });

  it("shortens the hash to 8 characters", () => {
    expect(shortHash("0123456789abcdef")).toBe("01234567");
  });

  it("limits provider options to the MVP providers plus those already on the task", () => {
    const t1 = plan.tasks[0];
    if (t1 === undefined) throw new Error("fixture");
    expect(providerOptions(t1)).toEqual(["claude", "codex"]);
    expect(providerOptions({ ...t1, provider: "gemini" })).toEqual(["claude", "codex", "gemini"]);
  });

  it("lists no auth modes for an unknown provider status", () => {
    const status = { provider: "gemini", auth_modes: ["api_key"] } as ProviderStatus;
    expect(authModesFor([status], "gemini")).toEqual(["api_key"]);
    expect(authModesFor([status], "claude")).toEqual([]);
    expect(authModesFor(undefined, "gemini")).toEqual([]);
  });

  it("finds fallbacks that add a provider outside the plan", () => {
    const t1 = plan.tasks[0];
    if (t1 === undefined) throw new Error("fixture");
    const v = view();
    expect(fallbacksOutsidePlan(v, t1, [{ provider: "kimi", auth_mode: "subscription" }])).toEqual([
      "kimi",
    ]);
    expect(fallbacksOutsidePlan(v, t1, [{ provider: "codex", auth_mode: "subscription" }])).toEqual(
      [],
    );
  });

  it("splits acceptance text into non-empty trimmed lines", () => {
    expect(acceptanceFromText(" a \n\n b\n")).toEqual(["a", "b"]);
  });
});
