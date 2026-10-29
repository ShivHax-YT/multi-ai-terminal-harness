// Rule 5: sign-in is disabled until confirm_personal_use succeeds. Then it opens the CLI's own login session.
import { screen, waitFor, within } from "@testing-library/react";
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

const loginCalls = (mock: MockIpc) =>
  mock.control.calls.filter((c) => c.command === "open_provider_login");

/** An installed, verified CLI that is signed out and not yet confirmed as the user's own account. */
function signedOutUnconfirmed(): MockIpc {
  const mock = createMockIpc({ scenario: "ready" });
  seed(mock, "claude", {
    sign_in: { state: "signed_out" },
    personal_use_confirmed: false,
  });
  return mock;
}

describe("rule 5: confirm before sign-in", () => {
  it("offers Confirm first and keeps Sign in disabled, with zero login calls", async () => {
    const mock = signedOutUnconfirmed();
    const { user } = renderRoute("/providers", { mock });
    const claude = await card("claude");
    expect(within(claude).getByRole("button", { name: "Confirm it is my account" })).toBeEnabled();
    const signIn = within(claude).getByRole("button", { name: "Sign in in terminal" });
    expect(signIn).toBeDisabled();
    await user.click(signIn);
    expect(loginCalls(mock)).toHaveLength(0);
  });

  it("confirms, enables Sign in, then opens the login session and navigates to it", async () => {
    const mock = signedOutUnconfirmed();
    const { user } = renderRoute("/providers", { mock });
    const claude = await card("claude");
    await user.click(within(claude).getByRole("button", { name: "Confirm it is my account" }));
    const signIn = await within(claude).findByRole("button", { name: "Sign in in terminal" });
    await waitFor(() => {
      expect(signIn).toBeEnabled();
    });
    expect(within(claude).queryByRole("button", { name: "Confirm it is my account" })).toBeNull();
    expect(loginCalls(mock)).toHaveLength(0);

    await user.click(signIn);
    await waitFor(() => {
      expect(window.location.hash).toBe("#/sessions/login-1");
    });
    const order = mock.control.calls.map((c) => c.command);
    expect(order.indexOf("confirm_personal_use")).toBeLessThan(
      order.indexOf("open_provider_login"),
    );
    expect(loginCalls(mock)).toHaveLength(1);
    expect(loginCalls(mock)[0]?.args).toEqual({ provider: "claude" });
  });

  it("confirm shows its refusal in the card and does not enable Sign in", async () => {
    const mock = signedOutUnconfirmed();
    mock.control.failNext("confirm_personal_use", { kind: "internal", message: "Could not save." });
    const { user } = renderRoute("/providers", { mock });
    const claude = await card("claude");
    await user.click(within(claude).getByRole("button", { name: "Confirm it is my account" }));
    expect(await within(claude).findByRole("alert")).toHaveTextContent("Could not save.");
    expect(within(claude).getByRole("button", { name: "Sign in in terminal" })).toBeDisabled();
    expect(loginCalls(mock)).toHaveLength(0);
  });

  it("a confirmed, signed-in provider offers no sign-in at all", async () => {
    const mock = createMockIpc({ scenario: "ready" });
    renderRoute("/providers", { mock });
    const claude = await card("claude");
    expect(within(claude).queryByRole("button", { name: /sign in/i })).toBeNull();
    expect(loginCalls(mock)).toHaveLength(0);
  });
});
