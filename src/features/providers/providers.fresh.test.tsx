// Freshness: the screen revalidates on every mount, a stale response never overwrites a newer provider_changed
// event, and the entrance stays inside the motion budget.
import { act, screen, waitFor, within } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import { MOTION_MS } from "@/components/motion";
import { createMockIpc, type MockIpc } from "@/lib/ipc/mock";
import { renderRoute } from "@/test/render";
import { providerLabel, type ProviderId } from "@/strings/providers";

import { STAGGERED_CARDS } from "./motion-budget";
import { seedProvider } from "./test-seed";

const card = (id: ProviderId) =>
  screen.findByRole("group", { name: providerLabel(id) }, { timeout: 10_000 });

function hold(): { promise: Promise<void>; release: () => void } {
  let release: () => void = () => undefined;
  const promise = new Promise<void>((resolve) => {
    release = resolve;
  });
  return { promise, release };
}

describe("revalidate on mount", () => {
  it("shows the backend's new state when the user returns to the screen", async () => {
    const mock = createMockIpc({ scenario: "ready" });
    seedProvider(mock, "codex", { sign_in: { state: "signed_out" } });
    const { user } = renderRoute("/providers", { mock });
    expect(within(await card("codex")).getByText("Signed out")).toBeInTheDocument();

    const nav = screen.getByRole("navigation", { name: "Main navigation", hidden: true });
    await user.click(within(nav).getByRole("link", { name: /^Lead/ }));
    await screen.findByRole("heading", { level: 1, name: "Lead" });
    expect(screen.queryByRole("group")).not.toBeInTheDocument();

    // While the screen is unmounted it hears no events: the login finishes and the kill switch flips.
    seedProvider(mock, "codex", { sign_in: { state: "signed_in" } });
    seedProvider(mock, "claude", { killswitch: "disabled" });

    await user.click(within(nav).getByRole("link", { name: /^Providers/ }));
    const codex = await card("codex");
    await waitFor(() => {
      expect(within(codex).getByText("Signed in")).toBeInTheDocument();
    });
    expect(
      within(await card("claude")).getByText("Turned off by remote config"),
    ).toBeInTheDocument();
    expect(mock.control.calls.filter((c) => c.command === "list_providers")).toHaveLength(2);
  });
});

describe("stale responses", () => {
  /** codex starts unverified; the held Check again response is the stale one. */
  function setup(): { mock: MockIpc; wrapped: MockIpc; held: ReturnType<typeof hold> } {
    const mock = createMockIpc({ scenario: "ready" });
    seedProvider(mock, "codex", {
      binary: { state: "unchecked", checks: [] },
    });
    const held = hold();
    const wrapped: MockIpc = {
      ...mock,
      client: {
        ...mock.client,
        refresh_provider_status: async (args) => {
          const stale = await mock.client.refresh_provider_status(args);
          await held.promise;
          return stale;
        },
      },
    };
    return { mock, wrapped, held };
  }

  it("ignores a mutation response when a newer provider_changed arrived while it was in flight", async () => {
    const { mock, wrapped, held } = setup();
    const { user } = renderRoute("/providers", { mock: wrapped });
    const codex = await card("codex");
    await user.click(within(codex).getByRole("button", { name: "Check again" }));
    await waitFor(() => {
      expect(mock.control.calls.some((c) => c.command === "refresh_provider_status")).toBe(true);
    });

    // A newer snapshot from the backend arrives first: verified and signed out.
    const newer = (await mock.client.list_providers()).find((p) => p.provider === "codex");
    if (newer === undefined) throw new Error("codex missing");
    newer.binary = { state: "verified", checks: [] };
    newer.sign_in = { state: "signed_out" };
    newer.usable = { lead: false, worker: false, blockers: ["signed_out"] };
    await act(async () => {
      mock.control.emit("provider_changed", newer);
      await Promise.resolve();
    });
    expect(await within(codex).findByText("Verified")).toBeInTheDocument();

    // The older response (still "unchecked") now resolves and must not win.
    await act(async () => {
      held.release();
      await held.promise;
    });
    await waitFor(() => {
      expect(within(codex).queryByText("Check again")).not.toBeInTheDocument();
    });
    expect(within(codex).getByText("Verified")).toBeInTheDocument();
    expect(within(codex).queryByText("Not verified yet")).not.toBeInTheDocument();
  });

  it("applies a mutation response when no newer event arrived", async () => {
    const { mock, wrapped, held } = setup();
    const { user } = renderRoute("/providers", { mock: wrapped });
    const codex = await card("codex");
    seedProvider(mock, "codex", { binary: { state: "verified", checks: [] } });
    await user.click(within(codex).getByRole("button", { name: "Check again" }));
    await act(async () => {
      held.release();
      await held.promise;
    });
    expect(await within(codex).findByText("Verified")).toBeInTheDocument();
  });

  it("keeps a newer event over an older list response", async () => {
    const mock = createMockIpc({ scenario: "ready" });
    const held = hold();
    let calls = 0;
    const wrapped: MockIpc = {
      ...mock,
      client: {
        ...mock.client,
        list_providers: async () => {
          calls += 1;
          const list = await mock.client.list_providers();
          if (calls === 1) await held.promise;
          return list;
        },
      },
    };
    renderRoute("/providers", { mock: wrapped });
    await screen.findByRole("status", { name: "Loading providers" });
    // Wait for the screen's event subscription, then push a newer snapshot while the list is still pending.
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 20));
    });
    const newer = (await mock.client.list_providers()).find((p) => p.provider === "codex");
    if (newer === undefined) throw new Error("codex missing");
    newer.sign_in = { state: "signed_out" };
    newer.usable = { lead: false, worker: false, blockers: ["signed_out"] };
    await act(async () => {
      mock.control.emit("provider_changed", newer);
      await Promise.resolve();
    });
    await act(async () => {
      held.release();
      await held.promise;
    });
    expect(await within(await card("codex")).findByText("Signed out")).toBeInTheDocument();
  });
});

describe("motion budget", () => {
  it("staggers only as many cards as fit in 300 ms, and the rest are static", async () => {
    const budget = (n: number) => (n - 1) * MOTION_MS.staggerStep + MOTION_MS.staggerItem;
    expect(budget(STAGGERED_CARDS)).toBeLessThanOrEqual(MOTION_MS.staggerMax);
    expect(budget(STAGGERED_CARDS + 1)).toBeGreaterThan(MOTION_MS.staggerMax);

    const { container } = renderRoute("/providers", { mock: "ready" });
    await card("claude");
    const group = container.querySelector('[data-motion="stagger"]');
    expect(group).not.toBeNull();
    expect(group?.querySelectorAll('[data-slot="card"]')).toHaveLength(STAGGERED_CARDS);
    expect(container.querySelectorAll('[data-slot="card"]')).toHaveLength(6);
  });
});
