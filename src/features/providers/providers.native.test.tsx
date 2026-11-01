import { screen, waitFor, within } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import { createMockIpc } from "@/lib/ipc/mock";
import { renderRoute } from "@/test/render";
import { providerLabel } from "@/strings/providers";

import { seedProvider } from "./test-seed";

describe("native onboarding observations", () => {
  it("shows signed-in status independently of execution readiness", async () => {
    const mock = createMockIpc({ scenario: "ready" });
    const { user } = renderRoute("/providers", {
      mock: {
        ...mock,
        client: {
          ...mock.client,
          list_providers: async () =>
            (await mock.client.list_providers()).map((p) =>
              p.provider === "codex"
                ? {
                    ...p,
                    killswitch: "unknown" as const,
                    personal_use_confirmed: false,
                    usable: {
                      lead: false,
                      worker: false,
                      blockers: [
                        "execution_boundary_unavailable" as const,
                        "runtime_controls_unavailable" as const,
                        "provider_policy_unverified" as const,
                      ],
                    },
                  }
                : p,
            ),
        },
      },
    });
    const card = await screen.findByRole("group", { name: providerLabel("codex") });
    expect(within(card).getByText("Signed in")).toBeInTheDocument();
    expect(within(card).getByText("Tasks unavailable")).toBeInTheDocument();
    expect(within(card).queryByRole("button", { name: "Go to Lead" })).not.toBeInTheDocument();
    expect(
      within(card).queryByRole("button", { name: "Confirm it is my account" }),
    ).not.toBeInTheDocument();
    expect(within(card).getByRole("button", { name: "Check again" })).toBeInTheDocument();
    await user.click(within(card).getByText("Technical details"));
    await waitFor(() =>
      expect(within(card).getByText(/filesystem isolation is not ready/)).toBeVisible(),
    );
  });

  it("keeps long install paths out of the main status rows and exposes them on request", async () => {
    const mock = createMockIpc({ scenario: "ready" });
    const path = `/a-very-long-installation-folder/${"nested-directory/".repeat(35)}cli`;
    seedProvider(mock, "codex", { install: { state: "installed", version: "0.162.0", path } });
    const { user } = renderRoute("/providers", { mock });
    const card = await screen.findByRole("group", { name: providerLabel("codex") });
    await waitFor(() => expect(within(card).getByText("Signed in")).toBeVisible());
    const text = within(card).getByText(path);
    expect(text).not.toBeVisible();
    await user.click(within(card).getByText("Technical details"));
    await waitFor(() => expect(within(card).getByText(path)).toBeVisible());
  });

  it("prepares manual official login as plain text and never dispatches it", async () => {
    const mock = createMockIpc({ scenario: "ready" });
    const command = "'/some path/cli' login <script>still plain text</script>";
    seedProvider(mock, "codex", {
      sign_in: { state: "signed_out", login_command: command },
      usable: {
        lead: false,
        worker: false,
        blockers: ["signed_out", "execution_boundary_unavailable"],
      },
    });
    renderRoute("/providers", { mock });
    const card = await screen.findByRole("group", { name: providerLabel("codex") });
    expect(within(card).getByText(command)).toBeInTheDocument();
    expect(card.querySelector("script")).toBeNull();
    expect(
      within(card).queryByRole("button", { name: "Sign in using Terminal" }),
    ).not.toBeInTheDocument();
    expect(mock.control.calls.some((c) => c.command === "open_provider_login")).toBe(false);
  });
});
