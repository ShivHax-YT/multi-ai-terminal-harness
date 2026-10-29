// Rule 12: a kill-switch-disabled provider offers no action; api_key_only turns subscription use off.
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

describe("rule 12: kill switch (killswitch)", () => {
  it("a disabled provider says so and offers no button or link", async () => {
    const { mock } = renderRoute("/providers", { mock: "killswitch" });
    const codex = await card("codex");
    expect(within(codex).getByText("Turned off by remote config")).toBeInTheDocument();
    expect(within(codex).queryByRole("button")).toBeNull();
    expect(within(codex).queryByRole("link")).toBeNull();
    // It shows no install, sign-in or verification rows to act on.
    expect(within(codex).queryByText("Signed in")).toBeNull();
    expect(mock.control.calls.filter((c) => c.command === "open_provider_login")).toHaveLength(0);
    // The other provider is unaffected.
    expect(within(await card("claude")).getByRole("button", { name: "Go to Lead" })).toBeEnabled();
  });

  it("a disabled provider that is also signed out and unverified still offers no action", async () => {
    const mock = createMockIpc({ scenario: "killswitch" });
    seed(mock, "codex", {
      sign_in: { state: "signed_out" },
      personal_use_confirmed: false,
      binary: { state: "unchecked", checks: [] },
    });
    renderRoute("/providers", { mock });
    const codex = await card("codex");
    expect(within(codex).queryByRole("button")).toBeNull();
  });

  it("api_key_only shows 'Subscription use is off. API key only.' and no sign-in", async () => {
    const mock = createMockIpc({ scenario: "ready" });
    seed(mock, "codex", {
      killswitch: "api_key_only",
      sign_in: { state: "signed_out" },
      personal_use_confirmed: false,
    });
    renderRoute("/providers", { mock });
    const codex = await card("codex");
    expect(within(codex).getByText("Subscription use is off. API key only.")).toBeInTheDocument();
    expect(within(codex).queryByRole("button", { name: /sign in|confirm/i })).toBeNull();
    expect(within(codex).getByRole("link", { name: "Open Settings" })).toHaveAttribute(
      "href",
      "#/settings",
    );
  });
});
