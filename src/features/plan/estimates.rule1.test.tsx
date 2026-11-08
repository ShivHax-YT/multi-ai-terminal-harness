// Rule 1: estimates are shown against the compiled-in ceilings from get_limits; turns over the ceiling are flagged.
import { screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import { DRAFT_ID, renderPlan, VIOLATIONS_ID } from "./test-support";

describe("rule 1: estimates against ceilings", () => {
  it("shows prompts and turns as meters against the ceilings", async () => {
    renderPlan("plan_draft", DRAFT_ID);
    const prompts = await screen.findByRole("meter", { name: "Claude Code prompts per hour" });
    expect(prompts).toHaveAttribute("aria-valuemax", "30");
    expect(prompts).toHaveAttribute("aria-valuenow", "10");
    const turns = screen.getByRole("meter", { name: "Codex CLI turns in the longest task" });
    expect(turns).toHaveAttribute("aria-valuemax", "40");
    expect(turns).toHaveAttribute("aria-valuenow", "25");
    expect(screen.getAllByText(/ceiling 30 prompts per hour, 40 turns per task/)).not.toHaveLength(
      0,
    );
  });

  it("flags turns over the ceiling as a rule 1 violation and a full meter", async () => {
    renderPlan("plan_violations", VIOLATIONS_ID);
    expect(await screen.findByText(/estimated turns 55 exceed the ceiling of 40/)).toBeVisible();
    expect(screen.getAllByText("Blocked by rule 1").length).toBeGreaterThan(0);
    const turns = screen.getByRole("meter", { name: "Claude Code turns in the longest task" });
    expect(turns.getAttribute("aria-valuetext")).toMatch(/at limit/);
    expect(turns.closest("[data-level]")).toHaveAttribute("data-level", "danger");
  });
});
