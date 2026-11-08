// Security: plan text is lead output and stays text. No HTML, no markdown, no links, no headings of its own.
import { screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import { createMockIpc } from "@/lib/ipc/mock";
import { renderRoute } from "@/test/render";

import { DRAFT_ID } from "./test-support";

const HOSTILE = '<img src=x onerror="alert(1)"> **bold** [click](https://example.invalid) # H1';

describe("untrusted plan text", () => {
  it("renders titles, summaries, paths and acceptance literally", async () => {
    const mock = createMockIpc({ scenario: "plan_draft" });
    const view = await mock.client.get_plan({ plan_id: DRAFT_ID });
    const plan = structuredClone(view.plan);
    plan.request_summary = HOSTILE;
    const first = plan.tasks[0];
    if (first === undefined) throw new Error("fixture has tasks");
    first.title = HOSTILE;
    first.owned_files = ["<script>alert(1)</script>.ts"];
    first.acceptance = [HOSTILE];
    const { container } = renderRoute(`/plans/${DRAFT_ID}`, { mock });
    await screen.findByRole("group", { name: "Task t1" });
    mock.control.emit("plan_changed", { ...view, plan });
    expect((await screen.findAllByText(HOSTILE, { exact: false })).length).toBeGreaterThan(0);
    const main = container.querySelector('[data-screen="plan"]');
    if (main === null) throw new Error("plan screen root");
    expect(main.querySelector("img")).toBeNull();
    expect(main.querySelector("script")).toBeNull();
    expect(main.querySelectorAll("a")).toHaveLength(0);
    expect(main.querySelectorAll("h1")).toHaveLength(0);
    expect(main.querySelector("strong")).toBeNull();
    expect(screen.getByText("<script>alert(1)</script>.ts")).toHaveClass("font-mono");
  });
});
