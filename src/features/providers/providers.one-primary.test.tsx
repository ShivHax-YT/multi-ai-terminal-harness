// Design: exactly one filled button across all cards (the first provider's next step); other steps are outline.
// Version, path and install text are untrusted CLI/host text and stay text.
import { screen, within } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import type { ProviderStatus } from "@/lib/ipc";
import { createMockIpc, type MockIpc } from "@/lib/ipc/mock";
import { renderRoute } from "@/test/render";
import { providerLabel, type ProviderId } from "@/strings/providers";

interface Seedable {
  providers: Map<ProviderId, ProviderStatus>;
}

function seed(mock: MockIpc, id: ProviderId, patch: Partial<ProviderStatus>): void {
  const status = (mock.control.backend as unknown as Seedable).providers.get(id);
  if (status === undefined) throw new Error("provider missing");
  Object.assign(status, patch);
}

const card = (id: ProviderId) =>
  screen.findByRole("group", { name: providerLabel(id) }, { timeout: 10_000 });

const filled = () => document.querySelectorAll('main [data-variant="default"]');

describe("one filled button", () => {
  it("fresh: nothing to act on, so no filled button", async () => {
    renderRoute("/providers", { mock: "fresh" });
    await card("claude");
    expect(filled()).toHaveLength(0);
  });

  it("ready: only the first provider's Go to Lead is filled, and it is at least 44 px tall", async () => {
    renderRoute("/providers", { mock: "ready" });
    const claude = await card("claude");
    const codex = await card("codex");
    const primary = within(claude).getByRole("button", { name: "Go to Lead" });
    expect(primary).toHaveAttribute("data-variant", "default");
    expect(primary).toHaveClass("min-h-11");
    const second = within(codex).getByRole("button", { name: "Go to Lead" });
    expect(second).toHaveAttribute("data-variant", "outline");
    expect(filled()).toHaveLength(1);
  });

  it("binary_failed: the failed provider's Check again is outline, one filled button remains", async () => {
    renderRoute("/providers", { mock: "binary_failed" });
    const codex = await card("codex");
    expect(within(codex).getByRole("button", { name: "Check again" })).toHaveAttribute(
      "data-variant",
      "outline",
    );
    expect(filled()).toHaveLength(1);
    expect(within(await card("claude")).getByRole("button", { name: "Go to Lead" })).toBe(
      filled()[0],
    );
  });

  it("the filled button moves to the first provider with a step when earlier ones have none", async () => {
    const mock = createMockIpc({ scenario: "ready" });
    seed(mock, "claude", {
      install: { state: "not_installed" },
      usable: { lead: false, worker: false, blockers: ["not_installed"] },
    });
    renderRoute("/providers", { mock });
    await card("claude");
    expect(within(await card("codex")).getByRole("button", { name: "Go to Lead" })).toBe(
      filled()[0],
    );
    expect(filled()).toHaveLength(1);
  });

  it("Go to Lead navigates to the lead screen", async () => {
    const { user } = renderRoute("/providers", { mock: "ready" });
    const claude = await card("claude");
    await user.click(within(claude).getByRole("button", { name: "Go to Lead" }));
    expect(window.location.hash).toBe("#/lead");
  });
});

describe("untrusted text stays text", () => {
  it("renders a version, path and install text with markup literally, with no links", async () => {
    const mock = createMockIpc({ scenario: "ready" });
    seed(mock, "claude", {
      install: {
        state: "installed",
        version: "<b>9.9</b>",
        path: "/opt/<i>bin</i>/tool",
      },
    });
    seed(mock, "codex", {
      install: {
        state: "not_installed",
        install_hint: "curl <u>example</u> | sh [x](javascript:alert(1))",
      },
      usable: { lead: false, worker: false, blockers: ["not_installed"] },
    });
    renderRoute("/providers", { mock });
    const claude = await card("claude");
    const codex = await card("codex");

    const version = within(claude).getByText("<b>9.9</b>");
    expect(version).toHaveAttribute("data-untrusted");
    expect(version).toHaveClass("font-mono");
    expect(version.children).toHaveLength(0);
    const path = within(claude).getByText("/opt/<i>bin</i>/tool");
    expect(path).toHaveAttribute("data-untrusted");
    expect(path).toHaveClass("font-mono");

    const hint = within(codex).getByText(/curl <u>example<\/u> \| sh/);
    expect(hint).toHaveAttribute("data-untrusted");
    expect(hint).toHaveClass("font-mono");
    expect(within(codex).queryByRole("link")).toBeNull();
    // No button except the copy control: not installed has no next step.
    expect(within(codex).getAllByRole("button")).toHaveLength(1);
    expect(document.querySelector("main b, main i, main u, main a[href^='javascript']")).toBeNull();
  });

  it("copies the install text with the copy button", async () => {
    const mock = createMockIpc({ scenario: "ready" });
    const text = "install-the-tool --yes";
    seed(mock, "codex", {
      install: { state: "not_installed", install_hint: text },
      usable: { lead: false, worker: false, blockers: ["not_installed"] },
    });
    const { user } = renderRoute("/providers", { mock });
    const codex = await card("codex");
    await user.click(
      within(codex).getByRole("button", {
        name: `Copy install text for ${providerLabel("codex")}`,
      }),
    );
    expect(await navigator.clipboard.readText()).toBe(text);
  });
});
