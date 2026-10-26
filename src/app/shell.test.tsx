import { act, fireEvent, screen, waitFor, within } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import { renderRoute } from "@/test/render";

import { NAV_ITEMS } from "./nav";
import { THEME_STORAGE_KEY } from "./theme";

const heading = (name: string) => screen.findByRole("heading", { level: 1, name });

describe("app shell", () => {
  it("redirects / to the lead screen", async () => {
    renderRoute("/");
    expect(await heading("Lead")).toBeInTheDocument();
    expect(window.location.hash).toBe("#/lead");
  });

  it("lists the seven screens plus About in the sidebar", async () => {
    renderRoute("/lead");
    await heading("Lead");
    const nav = screen.getByRole("navigation", { hidden: true });
    for (const label of [...NAV_ITEMS.map((n) => n.label), "About"]) {
      expect(within(nav).getByRole("link", { name: new RegExp(`^${label}`) })).toBeInTheDocument();
    }
  });

  it("switches screens with Cmd/Ctrl+1..7", async () => {
    renderRoute("/lead");
    await heading("Lead");
    for (const item of NAV_ITEMS) {
      fireEvent.keyDown(window, { key: String(item.digit), metaKey: true });
      expect(await heading(item.label)).toBeInTheDocument();
    }
    fireEvent.keyDown(window, { key: "1", ctrlKey: true });
    expect(await heading("Providers")).toBeInTheDocument();
  });

  it("renders every screen route, including the parameterised ones", async () => {
    const cases: [string, string][] = [
      ["/plans/plan-1", "Plans"],
      ["/sessions/s-1", "Sessions"],
      ["/review/t1?tab=diff", "Review"],
      ["/about", "About"],
      ["/nowhere", "Lead"],
    ];
    for (const [path, title] of cases) {
      const r = renderRoute(path);
      expect(await heading(title)).toBeInTheDocument();
      r.unmount();
    }
  });

  it("opens the palette with Cmd+K and offers navigation and theme only (rule 9)", async () => {
    renderRoute("/lead");
    await heading("Lead");
    fireEvent.keyDown(window, { key: "k", metaKey: true });
    const dialog = await screen.findByRole("dialog");
    const options = within(dialog).getAllByRole("option");
    expect(options.length).toBe(NAV_ITEMS.length + 1 + 3);
    for (const option of options) {
      const text = option.textContent;
      expect(text).toMatch(/^(Providers|Lead|Plans|Sessions|Review|Usage|Settings|About|Theme: )/);
      expect(text).not.toMatch(/approve|kill|take ?over|pty|reset|resume|pause|sign|key/i);
    }
  });

  it("navigates from the palette", async () => {
    const { user } = renderRoute("/lead");
    await heading("Lead");
    await user.click(screen.getByRole("button", { name: "Open command palette" }));
    const dialog = await screen.findByRole("dialog");
    await user.click(within(dialog).getByRole("option", { name: /^Usage/ }));
    expect(await heading("Usage")).toBeInTheDocument();
    await waitFor(() => {
      expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
    });
  });

  it("switches theme from the palette and saves it locally", async () => {
    const { user } = renderRoute("/lead");
    await heading("Lead");
    fireEvent.keyDown(window, { key: "k", metaKey: true });
    const dialog = await screen.findByRole("dialog");
    await user.click(within(dialog).getByRole("option", { name: "Theme: Dark" }));
    expect(document.documentElement.classList.contains("dark")).toBe(true);
    expect(localStorage.getItem(THEME_STORAGE_KEY)).toBe("dark");
  });

  it("switches theme from the header menu (light, dark, system)", async () => {
    const { user } = renderRoute("/lead");
    await heading("Lead");
    await user.click(screen.getByRole("button", { name: /^Theme:/ }));
    await user.click(await screen.findByRole("menuitemradio", { name: "Dark" }));
    expect(document.documentElement.classList.contains("dark")).toBe(true);
    await user.click(screen.getByRole("button", { name: /^Theme:/ }));
    await user.click(await screen.findByRole("menuitemradio", { name: "Light" }));
    expect(document.documentElement.classList.contains("dark")).toBe(false);
    expect(localStorage.getItem(THEME_STORAGE_KEY)).toBe("light");
    await user.click(screen.getByRole("button", { name: /^Theme:/ }));
    await user.click(await screen.findByRole("menuitemradio", { name: "System" }));
    expect(localStorage.getItem(THEME_STORAGE_KEY)).toBe("system");
  });

  it("restores the saved theme on start", async () => {
    localStorage.setItem(THEME_STORAGE_KEY, "dark");
    renderRoute("/lead");
    await heading("Lead");
    expect(document.documentElement.classList.contains("dark")).toBe(true);
  });

  it("has no route-transition animation and makes no IPC call that acts", async () => {
    const { mock, container } = renderRoute("/lead");
    await heading("Lead");
    for (const item of NAV_ITEMS) {
      act(() => {
        fireEvent.keyDown(window, { key: String(item.digit), metaKey: true });
      });
      await heading(item.label);
    }
    expect(container.querySelector("main")?.querySelector("[data-motion]")).toBeNull();
    const acting = mock.control.calls.filter((c) => !/^(get_|list_)/.test(c.command));
    expect(acting).toEqual([]);
  });
});
