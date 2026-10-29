// Markup and accessibility of the cards: valid description lists, and same-named buttons told apart.
import { screen, within } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import { createMockIpc } from "@/lib/ipc/mock";
import { renderRoute } from "@/test/render";
import { providerLabel, type ProviderId } from "@/strings/providers";

import { seedProvider } from "./test-seed";

const card = (id: ProviderId) =>
  screen.findByRole("group", { name: providerLabel(id) }, { timeout: 10_000 });

describe("description lists", () => {
  it.each(["ready", "fresh", "binary_failed", "api_key", "killswitch"] as const)(
    "scenario %s: every <dl> child is a div, dt or dd (the failed-check list sits inside a dd)",
    async (scenario) => {
      const { container } = renderRoute("/providers", { mock: scenario });
      await card("claude");
      const lists = container.querySelectorAll("dl");
      expect(lists.length).toBeGreaterThan(0);
      for (const dl of lists) {
        for (const child of dl.children) {
          expect(
            ["DIV", "DT", "DD"],
            `<dl> has a <${child.tagName.toLowerCase()}> child`,
          ).toContain(child.tagName);
        }
        // Inside a wrapping <div> only dt and dd are allowed.
        for (const div of dl.querySelectorAll(":scope > div")) {
          for (const child of div.children) expect(["DT", "DD"]).toContain(child.tagName);
        }
      }
    },
  );

  it("puts the failed verification checks inside the Binary row's dd", async () => {
    renderRoute("/providers", { mock: "binary_failed" });
    const codex = await card("codex");
    const checks = within(codex).getByRole("list", { name: "Verification checks" });
    expect(checks.parentElement?.tagName).toBe("DD");
    expect(checks.closest("dl")).not.toBeNull();
    expect(checks.parentElement?.previousElementSibling?.textContent).toBe("Binary");
  });
});

describe("same-named buttons are told apart", () => {
  it("describes each Go to Lead button by its provider's name", async () => {
    renderRoute("/providers", { mock: "ready" });
    const claude = await card("claude");
    const codex = await card("codex");
    expect(within(claude).getByRole("button", { name: "Go to Lead" })).toHaveAccessibleDescription(
      providerLabel("claude"),
    );
    expect(within(codex).getByRole("button", { name: "Go to Lead" })).toHaveAccessibleDescription(
      providerLabel("codex"),
    );
  });

  it("describes the Settings link by its provider's name", async () => {
    renderRoute("/providers", { mock: "ready" });
    const gemini = await card("gemini");
    expect(within(gemini).getByRole("link", { name: "Open Settings" })).toHaveAccessibleDescription(
      providerLabel("gemini"),
    );
  });

  it("explains the disabled sign-in with hidden text", async () => {
    const mock = createMockIpc({ scenario: "ready" });
    seedProvider(mock, "claude", {
      sign_in: { state: "signed_out" },
      personal_use_confirmed: false,
    });
    renderRoute("/providers", { mock });
    const claude = await card("claude");
    const signIn = within(claude).getByRole("button", { name: "Sign in in terminal" });
    expect(signIn).toBeDisabled();
    expect(signIn).toHaveAccessibleDescription(
      `${providerLabel("claude")} Confirm your account first`,
    );
    expect(within(claude).getByText("Confirm your account first")).toHaveClass("sr-only");
  });
});
