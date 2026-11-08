// Loading, empty, error, read-only and re-approval states.
import { screen, waitFor } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import { createMockIpc } from "@/lib/ipc/mock";
import { renderRoute } from "@/test/render";

import { approveCalls, DRAFT_ID, renderPlan } from "./test-support";

describe("plan screen states", () => {
  it("shows a skeleton while the plan loads", async () => {
    renderPlan("plan_draft", DRAFT_ID);
    expect(await screen.findByRole("status", { name: "Loading plan" })).toBeInTheDocument();
  });

  it("shows the empty state with a link to Lead when there are no plans", async () => {
    renderPlan("ready");
    expect(await screen.findByText("No plans yet. Ask the lead for one.")).toBeVisible();
    expect(screen.getByRole("link", { name: "Open Lead" })).toHaveAttribute("href", "#/lead");
  });

  it("shows the empty state after the only plan is discarded, only after the human confirms", async () => {
    const { mock, user } = renderPlan("plan_draft", DRAFT_ID);
    await user.click(await screen.findByRole("button", { name: "Discard plan..." }));
    await user.click(await screen.findByRole("button", { name: "Keep it" }));
    expect(mock.control.calls.filter((c) => c.command === "discard_plan")).toHaveLength(0);
    await user.click(await screen.findByRole("button", { name: "Discard plan..." }));
    await user.click(await screen.findByRole("button", { name: "Discard plan" }));
    expect(await screen.findByText("No plans yet. Ask the lead for one.")).toBeVisible();
    expect(mock.control.calls.filter((c) => c.command === "discard_plan")).toHaveLength(1);
    expect(approveCalls(mock)).toHaveLength(0);
  });

  it("shows the newest plan on /plans", async () => {
    renderPlan("plan_draft");
    expect(await screen.findByRole("group", { name: "Task t1" })).toBeInTheDocument();
  });

  it("shows an error alert when the plan cannot be loaded", async () => {
    renderPlan("errors", DRAFT_ID);
    expect(await screen.findByRole("alert")).toHaveTextContent(/Something went wrong/);
  });

  it("is read-only while running: no edit, discard or approve controls", async () => {
    renderPlan("running", DRAFT_ID);
    expect(await screen.findByText("This plan is running and read-only.")).toBeVisible();
    for (const name of [/Edit /, /Discard/, /Remove/, /Approve plan/]) {
      expect(screen.queryByRole("button", { name })).toBeNull();
    }
  });

  it("says an edit voided an earlier approval", async () => {
    const mock = createMockIpc({ scenario: "plan_draft" });
    const view = await mock.client.get_plan({ plan_id: DRAFT_ID });
    await mock.approval.approve_plan({ plan_id: DRAFT_ID, plan_hash: view.plan_hash });
    await mock.client.update_plan({
      plan_id: DRAFT_ID,
      edit: { kind: "set_acceptance", task_id: "t1", acceptance: ["Changed"] },
    });
    const calls = approveCalls(mock).length;
    renderRoute(`/plans/${DRAFT_ID}`, { mock });
    expect(await screen.findByText("Edited after approval. Approve again.")).toBeVisible();
    await screen.findByRole("button", { name: /Approve plan/ });
    await waitFor(() => {
      expect(approveCalls(mock)).toHaveLength(calls);
    });
  });
});
