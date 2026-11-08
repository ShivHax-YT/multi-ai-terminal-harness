// Rule 7: an API-key-only provider (Gemini) can be chosen only in API key mode.
import { screen, waitFor, within } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

import { createMockIpc } from "@/lib/ipc/mock";
import { renderRoute } from "@/test/render";

import { DRAFT_ID, task } from "./test-support";

async function geminiPlan() {
  const mock = createMockIpc({ scenario: "plan_draft" });
  await mock.client.update_plan({
    plan_id: DRAFT_ID,
    edit: { kind: "set_provider", task_id: "t1", provider: "gemini", auth_mode: "api_key" },
  });
  return mock;
}

describe("rule 7: provider edit", () => {
  it("offers only API key for Gemini and saves exactly that", async () => {
    const mock = await geminiPlan();
    const statuses = await mock.client.list_providers();
    const gemini = statuses.find((status) => status.provider === "gemini");
    if (gemini === undefined) throw new Error("fixture has no Gemini status");
    gemini.auth_modes = ["subscription", "api_key"];
    vi.spyOn(mock.client, "list_providers").mockResolvedValue(statuses);
    const { user } = renderRoute(`/plans/${DRAFT_ID}`, { mock });
    const t1 = await task("t1");
    await user.click(t1.getByRole("button", { name: "Edit provider" }));
    const dialog = await screen.findByRole("dialog");
    expect(within(dialog).getByLabelText("Provider")).toHaveValue("gemini");
    const mode = within(dialog).getByLabelText("Sign-in mode");
    expect(
      within(mode)
        .getAllByRole("option")
        .map((o) => o.textContent),
    ).toEqual(["API key"]);
    expect(within(dialog).getByText(/runs on an API key only/)).toBeInTheDocument();
    await user.click(within(dialog).getByRole("button", { name: "Save provider" }));
    await waitFor(() => {
      const edits = mock.control.calls.filter((c) => c.command === "update_plan");
      expect(edits.at(-1)?.args).toMatchObject({
        edit: { kind: "set_provider", task_id: "t1", provider: "gemini", auth_mode: "api_key" },
      });
    });
  });

  it("lets a subscription provider choose either listed mode", async () => {
    const { user } = renderRoute(`/plans/${DRAFT_ID}`, { mock: "plan_draft" });
    const t1 = await task("t1");
    await user.click(t1.getByRole("button", { name: "Edit provider" }));
    const mode = await screen.findByLabelText("Sign-in mode");
    const labels = within(mode)
      .getAllByRole("option")
      .map((o) => o.textContent);
    expect(labels).toContain("Subscription");
  });

  it("cannot save when the provider's status is unavailable (fails closed)", async () => {
    const mock = createMockIpc({ scenario: "plan_draft" });
    mock.control.failNext("list_providers", { kind: "internal", message: "no status" });
    const { user } = renderRoute(`/plans/${DRAFT_ID}`, { mock });
    const t1 = await task("t1");
    await user.click(t1.getByRole("button", { name: "Edit provider" }));
    expect(await screen.findByRole("button", { name: "Save provider" })).toBeDisabled();
  });
});
