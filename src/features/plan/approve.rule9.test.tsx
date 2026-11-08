// Rule 9: approval is a human click on the hash that is on screen; nothing else approves.
import { screen, waitFor } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import { approveCalls, DRAFT_ID, renderPlan, task, VIOLATIONS_ID } from "./test-support";

describe("rule 9: approve", () => {
  it("makes zero approve calls on mount and renders the button unfocused and 44 px tall", async () => {
    const { mock } = renderPlan("plan_draft", DRAFT_ID);
    const view = await mock.client.get_plan({ plan_id: DRAFT_ID });
    const button = await screen.findByRole("button", {
      name: `Approve plan ${view.plan_hash.slice(0, 8)}`,
    });
    expect(button).toHaveClass("min-h-11");
    expect(button).not.toHaveFocus();
    expect(approveCalls(mock)).toHaveLength(0);
  });

  it("sends exactly one approve call with the rendered hash on a click, then goes read-only", async () => {
    const { mock, user } = renderPlan("plan_draft", DRAFT_ID);
    const view = await mock.client.get_plan({ plan_id: DRAFT_ID });
    await user.click(
      await screen.findByRole("button", { name: `Approve plan ${view.plan_hash.slice(0, 8)}` }),
    );
    await screen.findByText("This plan is approved and read-only.");
    const calls = approveCalls(mock);
    expect(calls).toHaveLength(1);
    expect(calls[0]?.args).toEqual({ plan_id: DRAFT_ID, plan_hash: view.plan_hash });
    expect(screen.queryByRole("button", { name: /Approve plan/ })).toBeNull();
    expect(screen.queryByRole("button", { name: /Edit provider/ })).toBeNull();
  });

  it("makes zero approve calls after an edit, which shows the new hash", async () => {
    const { mock, user } = renderPlan("plan_draft", DRAFT_ID);
    const before = await mock.client.get_plan({ plan_id: DRAFT_ID });
    await screen.findByRole("button", { name: /Approve plan/ });
    const t1 = await task("t1");
    await user.click(t1.getByRole("button", { name: "Edit acceptance" }));
    const box = await screen.findByLabelText("Acceptance checks");
    await user.clear(box);
    await user.type(box, "A new check");
    await user.click(screen.getByRole("button", { name: "Save acceptance" }));
    const after = await waitFor(async () => {
      const v = await mock.client.get_plan({ plan_id: DRAFT_ID });
      expect(v.plan_hash).not.toBe(before.plan_hash);
      return v;
    });
    await screen.findByRole("button", { name: `Approve plan ${after.plan_hash.slice(0, 8)}` });
    expect(approveCalls(mock)).toHaveLength(0);
  });

  it("makes zero approve calls on a plan_changed event", async () => {
    const { mock } = renderPlan("plan_draft", DRAFT_ID);
    await screen.findByRole("button", { name: /Approve plan/ });
    const view = await mock.client.get_plan({ plan_id: DRAFT_ID });
    mock.control.emit("plan_changed", view);
    await screen.findByRole("button", { name: /Approve plan/ });
    expect(approveCalls(mock)).toHaveLength(0);
  });

  it("shows no approve button and makes zero approve calls when the plan has violations", async () => {
    const { mock } = renderPlan("plan_violations", VIOLATIONS_ID);
    await screen.findAllByText(/Blocked by rule/);
    expect(screen.queryByRole("button", { name: /Approve plan/ })).toBeNull();
    expect(approveCalls(mock)).toHaveLength(0);
  });

  it("shows a stale hash refusal once, refetches, and never retries", async () => {
    const { mock, user } = renderPlan("plan_draft", DRAFT_ID);
    const button = await screen.findByRole("button", { name: /Approve plan/ });
    mock.control.failNext("approve_plan", {
      kind: "plan_hash_mismatch",
      message: "The plan changed since you reviewed it. Review it again.",
    });
    const getsBefore = mock.control.calls.filter((c) => c.command === "get_plan").length;
    await user.click(button);
    await screen.findByText("This plan changed. Review it again.");
    await waitFor(() => {
      expect(mock.control.calls.filter((c) => c.command === "get_plan").length).toBeGreaterThan(
        getsBefore,
      );
    });
    expect(approveCalls(mock)).toHaveLength(1);
    // The human may look again and press the button themselves; nothing happened on its own.
    expect(screen.getByRole("button", { name: /Approve plan/ })).toBeEnabled();
    expect(approveCalls(mock)).toHaveLength(1);
  });
});
