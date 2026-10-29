// States and behaviour of the Providers screen, each rendered from a mock scenario.
import { act, screen, within } from "@testing-library/react";
import { afterEach, describe, expect, it } from "vitest";

import type { ProviderStatus } from "@/lib/ipc";
import { createMockIpc, type MockIpc } from "@/lib/ipc/mock";
import { renderRoute } from "@/test/render";
import { setReducedMotion } from "@/test/setup";
import { providerLabel, type ProviderId } from "@/strings/providers";

afterEach(() => {
  setReducedMotion(false);
});

/** Wraps list_providers so a test can hold it or reshape what the screen sees. */
function withListProviders(mock: MockIpc, list: () => Promise<ProviderStatus[]>): MockIpc {
  return { ...mock, client: { ...mock.client, list_providers: list } };
}

const card = (id: ProviderId) =>
  screen.findByRole("group", { name: providerLabel(id) }, { timeout: 10_000 });

describe("loading", () => {
  it("shows a skeleton while list_providers is pending, then the cards", async () => {
    const mock = createMockIpc({ scenario: "ready" });
    let release: () => void = () => undefined;
    const held = new Promise<void>((resolve) => {
      release = resolve;
    });
    renderRoute("/providers", {
      mock: withListProviders(mock, async () => {
        await held;
        return mock.client.list_providers();
      }),
    });
    expect(await screen.findByRole("status", { name: "Loading providers" })).toBeInTheDocument();
    expect(screen.queryByRole("group")).not.toBeInTheDocument();
    await act(async () => {
      release();
      await held;
    });
    expect(await card("claude")).toBeInTheDocument();
    expect(screen.queryByRole("status", { name: "Loading providers" })).not.toBeInTheDocument();
  });
});

describe("empty", () => {
  it("says nothing is ready yet when no provider is usable (fresh)", async () => {
    renderRoute("/providers", { mock: "fresh" });
    expect(
      await screen.findByRole("heading", { name: "Nothing is ready yet" }),
    ).toBeInTheDocument();
    // The cards are still there: they say what blocks each provider.
    const claude = await card("claude");
    expect(within(claude).getByText("Not installed")).toBeInTheDocument();
    expect(within(claude).getByText("No install text is available yet.")).toBeInTheDocument();
    expect(within(claude).queryByRole("button")).not.toBeInTheDocument();
  });

  it("does not show the empty state when a provider is usable (ready)", async () => {
    renderRoute("/providers", { mock: "ready" });
    await card("claude");
    expect(screen.queryByText("Nothing is ready yet")).not.toBeInTheDocument();
  });
});

describe("error", () => {
  it("shows an alert when list_providers rejects, and does not retry by itself", async () => {
    const { mock, user } = renderRoute("/providers", { mock: "errors" });
    const alert = await screen.findByRole("alert");
    expect(within(alert).getByText("Something went wrong")).toBeInTheDocument();
    expect(within(alert).getByText("mock scenario: every command fails")).toBeInTheDocument();
    await act(async () => {
      await mock.control.advance(5 * 60_000);
    });
    const listCalls = () => mock.control.calls.filter((c) => c.command === "list_providers");
    expect(listCalls()).toHaveLength(1);
    // A manual retry is the user's call.
    await user.click(within(alert).getByRole("button", { name: "Try again" }));
    expect(listCalls()).toHaveLength(2);
  });

  it.each([
    ["rule_blocked", { kind: "rule_blocked", rule: 12, message: "Blocked on purpose." }],
    ["rate_limited", { kind: "rate_limited", message: "Slow down." }],
  ] as const)("offers no retry button for %s", async (_name, error) => {
    const mock = createMockIpc({ scenario: "ready" });
    mock.control.failNext("list_providers", error);
    renderRoute("/providers", { mock });
    const alert = await screen.findByRole("alert");
    expect(within(alert).getByText(error.message)).toBeInTheDocument();
    expect(within(alert).queryByRole("button")).not.toBeInTheDocument();
    await act(async () => {
      await mock.control.advance(5 * 60_000);
    });
    expect(mock.control.calls.filter((c) => c.command === "list_providers")).toHaveLength(1);
  });

  it("shows a failed card action inside that card only", async () => {
    const mock = createMockIpc({ scenario: "binary_failed" });
    mock.control.failNext("refresh_provider_status", {
      kind: "internal",
      message: "Check failed.",
    });
    const { user } = renderRoute("/providers", { mock });
    const codex = await card("codex");
    await user.click(within(codex).getByRole("button", { name: "Check again" }));
    expect(await within(codex).findByRole("alert")).toHaveTextContent("Check failed.");
    expect(within(await card("claude")).queryByRole("alert")).not.toBeInTheDocument();
  });
});

describe("ready", () => {
  it("lists every provider in backend order with plain-text names and statuses", async () => {
    renderRoute("/providers", { mock: "ready" });
    await card("claude");
    const names = screen.getAllByRole("group").map((g) => g.getAttribute("data-provider"));
    expect(names).toEqual(["claude", "codex", "grok", "kimi", "gemini", "glm"]);
    const claude = await card("claude");
    expect(within(claude).getByText("Installed")).toBeInTheDocument();
    expect(within(claude).getByText("Verified")).toBeInTheDocument();
    expect(within(claude).getByText("Signed in")).toBeInTheDocument();
    expect(within(claude).getByText("Usable as lead and worker")).toBeInTheDocument();
    expect(within(claude).getByText("2.1.295")).toHaveClass("font-mono");
    const grok = await card("grok");
    expect(
      within(grok).getByText("Support for this tool is not available yet."),
    ).toBeInTheDocument();
    expect(within(grok).queryByRole("button")).not.toBeInTheDocument();
  });

  it("replaces a card when the backend pushes provider_changed", async () => {
    const mock = createMockIpc({ scenario: "ready" });
    renderRoute("/providers", { mock });
    const codex = await card("codex");
    expect(within(codex).getByText("Signed in")).toBeInTheDocument();
    const next = await mock.client.list_providers();
    const changed = next.find((p) => p.provider === "codex");
    if (changed === undefined) throw new Error("codex missing");
    changed.sign_in = { state: "signed_out" };
    changed.usable = { lead: false, worker: false, blockers: ["signed_out"] };
    await act(async () => {
      mock.control.emit("provider_changed", changed);
      await Promise.resolve();
    });
    expect(await within(await card("codex")).findByText("Signed out")).toBeInTheDocument();
  });
});

describe("motion", () => {
  it("staggers the cards once, and renders them static under reduced motion", async () => {
    const first = renderRoute("/providers", { mock: "ready" });
    await card("claude");
    expect(first.container.querySelector('[data-motion="stagger"]')).not.toBeNull();
    first.unmount();
    setReducedMotion(true);
    const second = renderRoute("/providers", { mock: "ready" });
    await card("claude");
    expect(second.container.querySelector('[data-motion="static"]')).not.toBeNull();
    expect(second.container.querySelector('[data-motion="stagger"]')).toBeNull();
  });
});
