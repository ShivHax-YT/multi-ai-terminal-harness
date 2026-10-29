// Rule 7: Gemini is API key only. No sign-in control or login path in any scenario.
import { screen, within } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import { createMockIpc } from "@/lib/ipc/mock";
import { renderRoute } from "@/test/render";
import { providerLabel } from "@/strings/providers";

const gemini = () =>
  screen.findByRole("group", { name: providerLabel("gemini") }, { timeout: 10_000 });

describe("rule 7: the API-key-only provider has no login path", () => {
  it.each(["ready", "api_key", "fresh", "binary_failed", "killswitch"] as const)(
    "scenario %s: no sign-in or confirm control, API key only, link to Settings",
    async (scenario) => {
      const { mock } = renderRoute("/providers", { mock: scenario });
      const card = await gemini();
      expect(within(card).queryByRole("button", { name: /sign|log ?in|confirm/i })).toBeNull();
      expect(within(card).queryByRole("link", { name: /sign|log ?in/i })).toBeNull();
      expect(within(card).getByText("API key only")).toBeInTheDocument();
      const settings = within(card).getByRole("link", { name: "Open Settings" });
      expect(settings).toHaveAttribute("href", "#/settings");
      expect(mock.control.calls.filter((c) => c.command === "open_provider_login")).toHaveLength(0);
    },
  );

  it("shows whether a key is saved without offering to sign in (api_key)", async () => {
    renderRoute("/providers", { mock: "api_key" });
    const card = await gemini();
    expect(within(card).getByText("API key saved")).toBeInTheDocument();
    expect(within(card).queryByText("Personal use")).toBeNull();
  });

  it("shows that no key is saved (ready)", async () => {
    renderRoute("/providers", { mock: "ready" });
    const card = await gemini();
    expect(within(card).getByText("No API key yet")).toBeInTheDocument();
  });

  it("never offers sign-in or confirm for this provider even if the backend lists a subscription mode", async () => {
    const mock = createMockIpc({ scenario: "ready" });
    renderRoute("/providers", {
      mock: {
        ...mock,
        client: {
          ...mock.client,
          list_providers: async () =>
            (await mock.client.list_providers()).map((p) =>
              p.provider === "gemini"
                ? {
                    ...p,
                    auth_modes: ["subscription" as const, "api_key" as const],
                    sign_in: { state: "signed_out" as const },
                    personal_use_confirmed: false,
                    usable: {
                      lead: false,
                      worker: false,
                      blockers: ["signed_out" as const, "personal_use_unconfirmed" as const],
                    },
                  }
                : p,
            ),
        },
      },
    });
    const card = await gemini();
    expect(within(card).queryByRole("button")).toBeNull();
    expect(within(card).getByText("API key only")).toBeInTheDocument();
    expect(within(card).queryByText(/signed out|own personal account/i)).toBeNull();
    expect(mock.control.calls.filter((c) => c.command === "open_provider_login")).toHaveLength(0);
  });
});
