// Rule 9: a fallback provider that no task in the plan uses is an edit that voids approval. The screen says so before
// it sends the edit.
import { screen, waitFor, within } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import { createMockIpc } from "@/lib/ipc/mock";
import { renderRoute } from "@/test/render";

import { approveCalls, DRAFT_ID, task } from "./test-support";

async function planWithOnlyClaude() {
  const mock = createMockIpc({ scenario: "plan_draft" });
  // Every task runs on the first provider and nothing has a fallback, so the second provider is outside the plan.
  for (const id of ["t1", "t2", "t3"]) {
    await mock.client.update_plan({
      plan_id: DRAFT_ID,
      edit: { kind: "set_provider", task_id: id, provider: "claude", auth_mode: "subscription" },
    });
    await mock.client.update_plan({
      plan_id: DRAFT_ID,
      edit: { kind: "set_fallbacks", task_id: id, fallback_providers: [] },
    });
  }
  return mock;
}

describe("rule 9: fallback outside the plan", () => {
  it("warns before the edit is sent, then sends one edit and shows the new violation", async () => {
    const mock = await planWithOnlyClaude();
    const { user } = renderRoute(`/plans/${DRAFT_ID}`, { mock });
    const t1 = await task("t1");
    await user.click(t1.getByRole("button", { name: "Edit fallbacks" }));
    const dialog = await screen.findByRole("dialog");
    const editsBefore = mock.control.calls.filter((c) => c.command === "update_plan").length;
    expect(within(dialog).queryByText(/This needs a new approval/)).toBeNull();
    await user.click(within(dialog).getByLabelText("Codex CLI"));
    expect(await within(dialog).findByText(/This needs a new approval/)).toBeInTheDocument();
    expect(mock.control.calls.filter((c) => c.command === "update_plan")).toHaveLength(editsBefore);
    await user.click(within(dialog).getByRole("button", { name: "Save fallbacks" }));
    await screen.findByText(/is not a task provider in this plan/);
    const sent = mock.control.calls.filter((c) => c.command === "update_plan").slice(editsBefore);
    expect(sent).toHaveLength(1);
    expect(sent[0]?.args).toMatchObject({
      edit: {
        kind: "set_fallbacks",
        task_id: "t1",
        fallback_providers: [{ provider: "codex", auth_mode: "subscription" }],
      },
    });
    // The new rule 9 violation removes the approve button; nothing was approved.
    expect(screen.queryByRole("button", { name: /Approve plan/ })).toBeNull();
    expect(approveCalls(mock)).toHaveLength(0);
  });

  it("does not warn for a provider that already runs a task in the plan", async () => {
    const { user, mock } = renderRoute(`/plans/${DRAFT_ID}`, { mock: "plan_draft" });
    const t1 = await task("t1");
    await user.click(t1.getByRole("button", { name: "Edit fallbacks" }));
    const dialog = await screen.findByRole("dialog");
    const codex = within(dialog).getByLabelText("Codex CLI");
    await user.click(codex);
    await user.click(codex);
    await waitFor(() => {
      expect(codex).toBeChecked();
    });
    expect(within(dialog).queryByText(/This needs a new approval/)).toBeNull();
    expect(approveCalls(mock)).toHaveLength(0);
  });
});
