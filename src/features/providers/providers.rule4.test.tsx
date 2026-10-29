// Rule 4: status comes only from ProviderStatus, and the screen issues only the status commands.
import { screen, waitFor, within } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import type { ProviderStatus } from "@/lib/ipc";
import { createMockIpc, type MockIpc } from "@/lib/ipc/mock";
import { renderRoute } from "@/test/render";
import { providerLabel, type ProviderId } from "@/strings/providers";

interface Seedable {
  providers: Map<ProviderId, ProviderStatus>;
}

/** Changes the mock backend's own state, so its refusals and results stay the real ones. */
function seed(mock: MockIpc, id: ProviderId, patch: Partial<ProviderStatus>): void {
  const status = (mock.control.backend as unknown as Seedable).providers.get(id);
  if (status === undefined) throw new Error("provider missing");
  Object.assign(status, patch);
}

const card = (id: ProviderId) =>
  screen.findByRole("group", { name: providerLabel(id) }, { timeout: 10_000 });

const STATUS_COMMANDS = [
  "list_providers",
  "refresh_provider_status",
  "confirm_personal_use",
  "open_provider_login",
];

describe("rule 4: sign-in state is rendered from the backend status", () => {
  it.each([
    ["signed_in", "Signed in"],
    ["signed_out", "Signed out"],
    ["unknown", "Sign-in state unknown"],
  ] as const)("sign_in.state %s renders %s", async (state, label) => {
    const mock = createMockIpc({ scenario: "ready" });
    seed(mock, "codex", { sign_in: { state } });
    renderRoute("/providers", { mock });
    const codex = await card("codex");
    expect(within(codex).getByText(label)).toBeInTheDocument();
    for (const other of ["Signed in", "Signed out", "Sign-in state unknown"]) {
      if (other !== label) expect(within(codex).queryByText(other)).not.toBeInTheDocument();
    }
  });

  it("renders the backend's usable answer and blockers without recomputing them", async () => {
    const mock = createMockIpc({ scenario: "ready" });
    // The backend says paused although every other field looks fine: the screen shows that answer as it is.
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
                    usable: { lead: false, worker: true, blockers: ["provider_paused" as const] },
                  }
                : p,
            ),
        },
      },
    });
    const codex = await card("codex");
    expect(within(codex).getByText("Usable as worker")).toBeInTheDocument();
    expect(within(codex).getByText(/Paused after repeated rate limits/)).toBeInTheDocument();
  });

  it("issues only the four status commands across load, confirm, check again and sign-in", async () => {
    const mock = createMockIpc({ scenario: "fresh" });
    seed(mock, "claude", {
      install: { state: "installed", version: "1.0.0" },
      binary: { state: "unchecked", checks: [] },
    });
    const { user } = renderRoute("/providers", { mock });
    const claude = await card("claude");
    await user.click(within(claude).getByRole("button", { name: "Check again" }));
    await waitFor(() => {
      expect(mock.control.calls.some((c) => c.command === "refresh_provider_status")).toBe(true);
    });
    const commands = new Set(mock.control.calls.map((c) => c.command));
    for (const command of commands) expect(STATUS_COMMANDS).toContain(command);
    expect(commands.has("get_killswitch_status")).toBe(false);
    expect(commands.has("get_settings")).toBe(false);
  });
});
