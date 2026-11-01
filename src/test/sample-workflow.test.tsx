import { webcrypto } from "node:crypto";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it } from "vitest";

import { App } from "@/app/app";
import { createMockIpc } from "@/lib/ipc/mock";

Object.defineProperty(globalThis.crypto, "subtle", { value: webcrypto.subtle, configurable: true });

describe("sample workflow", () => {
  it("selects a project, submits, approves from the plan screen, then reviews safely rendered output", async () => {
    const user = userEvent.setup();
    const mock = createMockIpc();
    window.location.hash = "#/lead";
    render(<App bundle={mock} />);
    expect(
      await screen.findByText(
        /Provider installation, verification, sign-in and usage are fixture data/,
      ),
    ).toBeInTheDocument();
    expect(await screen.findByLabelText("Project")).toHaveValue("sample");
    const submit = screen.getByRole("button", { name: "Prepare simulated plan" });
    expect(submit).toBeDisabled();
    await user.type(screen.getByLabelText("Task"), "Show <script>alert(1)</script> as plain text");
    await user.click(submit);
    await user.click(
      await screen.findByRole("button", { name: "Approve and run simulated worker" }),
    );
    await user.click(await screen.findByRole("link", { name: "Review output and file changes" }));
    expect(await screen.findByText(/this diff is illustrative/)).toBeInTheDocument();
    expect(screen.getByText(/No worktree: browser memory only/)).toBeInTheDocument();
    expect(screen.getByText(/Illustrative change/)).toHaveTextContent("<script>alert(1)</script>");
    expect(document.querySelector("main script")).toBeNull();
    await waitFor(() => {
      expect(window.location.hash).toContain("/review/sim-1");
    });
  });

  it("allocates unique IDs for simultaneous browser submissions", async () => {
    const mock = createMockIpc();
    const plans = await Promise.all(
      ["first", "second", "third"].map((task) =>
        mock.client.sim_submit({ project_id: "sample", task }),
      ),
    );
    expect(new Set(plans.map((p) => p.id)).size).toBe(3);
    const selected = plans[1]!;
    const args = { plan_id: selected.id, plan_hash: selected.hash };
    const { token } = await mock.approval.sim_approve_plan(args);
    expect((await mock.client.sim_run({ ...args, token })).task).toBe("second");
  });

  it("refuses unapproved, edited and replayed browser dispatches", async () => {
    const mock = createMockIpc();
    const p = await mock.client.sim_submit({ project_id: "sample", task: "Try sample" });
    const args = { plan_id: p.id, plan_hash: p.hash, token: "forged" };
    // Mock refusals may throw synchronously, just like existing mock port implementations.
    expect(() => mock.client.sim_run(args)).toThrow(/approval/);
    expect(() => mock.approval.sim_approve_plan({ plan_id: p.id, plan_hash: "edited" })).toThrow();
    const { token } = await mock.approval.sim_approve_plan(args);
    expect(() => mock.client.sim_run({ ...args, plan_hash: "edited", token })).toThrow();
    expect((await mock.client.sim_run({ ...args, token })).result?.isolation).toBe(
      "browser_memory",
    );
    expect(() => mock.client.sim_run({ ...args, token })).toThrow();
  });
});
