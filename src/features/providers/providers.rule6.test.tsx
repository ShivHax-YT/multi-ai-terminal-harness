// Rule 6: a binary that failed verification gets no sign-in, and a refused login is shown as "Blocked by rule 6".
import { act, screen, waitFor, within } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import { createMockIpc, type MockIpc } from "@/lib/ipc/mock";
import { renderRoute } from "@/test/render";
import { providerLabel, type ProviderId } from "@/strings/providers";

import { seedProvider } from "./test-seed";

const card = (id: ProviderId) =>
  screen.findByRole("group", { name: providerLabel(id) }, { timeout: 10_000 });

const calls = (mock: MockIpc, command: string) =>
  mock.control.calls.filter((c) => c.command === command);

describe("rule 6: failed binary (binary_failed)", () => {
  it("shows the failure, offers Check again, and offers no sign-in", async () => {
    const { mock, user } = renderRoute("/providers", { mock: "binary_failed" });
    const codex = await card("codex");
    expect(within(codex).getByText("Failed verification")).toBeInTheDocument();
    expect(
      within(codex).getByText("The tool failed verification, so automation is off (rule 6)."),
    ).toBeInTheDocument();
    // The check details come from the host: shown as text.
    const checks = within(codex).getByRole("list", { name: "Verification checks" });
    expect(within(checks).getByText(/code object is not signed at all/)).toHaveAttribute(
      "data-untrusted",
    );
    expect(within(codex).queryByRole("button", { name: /sign in/i })).toBeNull();
    expect(within(codex).queryByRole("button", { name: /confirm/i })).toBeNull();

    await user.click(within(codex).getByRole("button", { name: "Check again" }));
    await waitFor(() => {
      expect(calls(mock, "refresh_provider_status")).toHaveLength(1);
    });
    expect(calls(mock, "refresh_provider_status")[0]?.args).toEqual({ provider: "codex" });
    expect(calls(mock, "open_provider_login")).toHaveLength(0);
    // Still failed: the screen shows what the backend says.
    expect(await within(codex).findByText("Failed verification")).toBeInTheDocument();
  });

  it("shows a refused login as Blocked by rule 6, stays put, and does not retry", async () => {
    // The screen's copy of the status is stale (it looks fine); the backend refuses.
    const mock = createMockIpc({ scenario: "ready" });
    seedProvider(mock, "claude", { sign_in: { state: "signed_out" } });
    mock.control.failNext("open_provider_login", {
      kind: "rule_blocked",
      rule: 6,
      message: "The CLI failed verification; sign-in is refused.",
    });
    const { user } = renderRoute("/providers", { mock });
    const claude = await card("claude");
    await user.click(within(claude).getByRole("button", { name: "Sign in in terminal" }));
    const alert = await within(claude).findByRole("alert");
    expect(alert).toHaveTextContent("Blocked by rule 6");
    expect(alert).toHaveTextContent("The CLI failed verification; sign-in is refused.");
    expect(window.location.hash).toBe("#/providers");
    await act(async () => {
      await mock.control.advance(5 * 60_000);
    });
    expect(calls(mock, "open_provider_login")).toHaveLength(1);
  });

  it("an unverified (unchecked) binary also gets Check again and no sign-in", async () => {
    const mock = createMockIpc({ scenario: "ready" });
    seedProvider(mock, "codex", {
      binary: { state: "unchecked", checks: [] },
      usable: { lead: false, worker: false, blockers: ["binary_unchecked"] },
    });
    renderRoute("/providers", { mock });
    const codex = await card("codex");
    expect(within(codex).getByText("Not verified yet")).toBeInTheDocument();
    expect(within(codex).getByRole("button", { name: "Check again" })).toBeInTheDocument();
    expect(within(codex).queryByRole("button", { name: /sign in/i })).toBeNull();
  });
});
