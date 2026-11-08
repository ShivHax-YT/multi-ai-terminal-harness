// Shared test helpers for the plan screen tests. Test-only.
import { screen, within } from "@testing-library/react";

import { renderRoute } from "@/test/render";

export const DRAFT_ID = "plan-2026-10-25-001";
export const VIOLATIONS_ID = "plan-2026-10-25-002";

type Scenario = NonNullable<Exclude<Parameters<typeof renderRoute>[1], undefined>["mock"]>;

export function renderPlan(scenario: Scenario, planId?: string) {
  return renderRoute(planId === undefined ? "/plans" : `/plans/${planId}`, { mock: scenario });
}

export async function task(id: string) {
  return within(await screen.findByRole("group", { name: `Task ${id}` }));
}

export function approveCalls<C extends { command: string }>(mock: {
  control: { calls: readonly C[] };
}): C[] {
  return mock.control.calls.filter((c) => c.command === "approve_plan");
}
