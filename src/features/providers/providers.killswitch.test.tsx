// Rule 12: a kill-switch-disabled provider offers no action; api_key_only turns subscription use off.
import { screen, within } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import { createMockIpc } from "@/lib/ipc/mock";
import { renderRoute } from "@/test/render";
import { providerLabel, type ProviderId } from "@/strings/providers";

import { seedProvider } from "./test-seed";

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
    seedProvider(mock, "codex", {
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
    seedProvider(mock, "codex", {
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

  it("hides the sign-in and confirm blocker sentences when subscription use is off", async () => {
    const mock = createMockIpc({ scenario: "ready" });
    renderRoute("/providers", {
      mock: {
        ...mock,
        client: {
          ...mock.client,
          list_providers: async () =>
            (await mock.client.list_providers()).map((p) =>
              p.provider === "codex"
                ? {
                    ...p,
                    killswitch: "api_key_only" as const,
                    sign_in: { state: "signed_out" as const },
                    personal_use_confirmed: false,
                    usable: {
                      lead: false,
                      worker: false,
                      blockers: [
                        "signed_out" as const,
                        "sign_in_unknown" as const,
                        "personal_use_unconfirmed" as const,
                        "api_key_missing" as const,
                      ],
                    },
                  }
                : p,
            ),
        },
      },
    });
    const codex = await card("codex");
    const list = within(codex).getByRole("list", { name: "What blocks it" });
    expect(
      within(list)
        .getAllByRole("listitem")
        .map((li) => li.textContent),
    ).toEqual(["Add an API key in Settings to use this tool."]);
    expect(within(codex).queryByText(/signed out|sign in in|own personal account/i)).toBeNull();
  });
});
