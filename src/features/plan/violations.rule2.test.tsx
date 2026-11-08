// Rule 2 (one provider listed twice in a fallback chain) and a fallback outside the plan show as backend violations
// with their rule number, and nothing on screen is a filled button.
import { screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import { approveCalls, renderPlan, VIOLATIONS_ID } from "./test-support";

describe("violations", () => {
  it("shows the duplicate fallback as Blocked by rule 2, using the backend text", async () => {
    const { mock } = renderPlan("plan_violations", VIOLATIONS_ID);
    expect(await screen.findByText(/fallback provider claude is listed twice/)).toBeVisible();
    expect(screen.getAllByText("Blocked by rule 2").length).toBeGreaterThan(0);
    expect(approveCalls(mock)).toHaveLength(0);
  });

  it("shows a fallback outside the plan and offers no filled button", async () => {
    renderPlan("plan_violations", VIOLATIONS_ID);
    expect(
      await screen.findByText(/fallback provider kimi is not a task provider in this plan/),
    ).toBeVisible();
    expect(screen.getAllByText("Blocked by rule 9").length).toBeGreaterThan(0);
    expect(screen.queryByRole("button", { name: /Approve plan/ })).toBeNull();
    expect(document.querySelector('main [data-variant="default"]')).toBeNull();
  });
});
