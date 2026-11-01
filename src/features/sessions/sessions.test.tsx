// The Sessions screen against the mock backend, with a stand-in for xterm (it needs real layout).
import { screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { createMockIpc } from "@/lib/ipc/mock";
import { renderRoute } from "@/test/render";

const xterm = vi.hoisted(() => ({
  writes: [] as Uint8Array[],
  options: [] as Record<string, unknown>[],
  dataHandlers: [] as ((data: string) => void)[],
}));

vi.mock("@xterm/xterm", () => ({
  Terminal: class {
    constructor(options: Record<string, unknown>) {
      xterm.options.push(options);
    }
    loadAddon() {}
    open() {}
    focus() {}
    reset() {}
    dispose() {}
    attachCustomKeyEventHandler() {}
    write(bytes: Uint8Array) {
      xterm.writes.push(bytes);
    }
    onData(handler: (data: string) => void) {
      xterm.dataHandlers.push(handler);
      return { dispose: () => undefined };
    }
    onBinary() {
      return { dispose: () => undefined };
    }
    onResize() {
      return { dispose: () => undefined };
    }
  },
}));
vi.mock("@xterm/addon-fit", () => ({
  FitAddon: class {
    fit() {}
  },
}));
vi.mock("@xterm/xterm/css/xterm.css", () => ({}));

const written = () => xterm.writes.map((b) => new TextDecoder().decode(b)).join("");

beforeEach(() => {
  xterm.writes.length = 0;
  xterm.options.length = 0;
  xterm.dataHandlers.length = 0;
  localStorage.clear();
  vi.stubGlobal(
    "ResizeObserver",
    class {
      observe() {}
      disconnect() {}
    },
  );
});

async function openClaude() {
  const view = renderRoute("/sessions", { mock: "fresh" });
  await view.user.click(await screen.findByRole("button", { name: "Choose" }));
  const open = await screen.findByRole("button", { name: /Open Claude Code/ });
  await waitFor(() => {
    expect(open).toBeEnabled();
  });
  await view.user.click(open);
  return view;
}

describe("opening a terminal", () => {
  it("cannot start without a folder", async () => {
    renderRoute("/sessions", { mock: "fresh" });
    expect(await screen.findByRole("button", { name: /Open Claude Code/ })).toBeDisabled();
    expect(await screen.findByRole("button", { name: /Open Codex CLI/ })).toBeDisabled();
  });

  it("rule 5: asks once whether the account is the user's own, and starts only on yes", async () => {
    const { mock, user } = await openClaude();
    const dialog = await screen.findByRole("alertdialog");
    expect(dialog).toHaveTextContent("your own account");
    expect(mock.control.calls.filter((c) => c.command === "start_terminal")).toHaveLength(0);
    await user.click(screen.getByRole("button", { name: "It is my own account" }));
    await screen.findByRole("region", { name: "Terminal" });
    expect(mock.control.calls.filter((c) => c.command === "start_terminal")).toHaveLength(1);
    expect(window.location.hash).toMatch(/^#\/sessions\/t-/);
  });

  it("cancelling starts nothing", async () => {
    const { mock, user } = await openClaude();
    await user.click(await screen.findByRole("button", { name: "Cancel" }));
    expect(mock.control.calls.filter((c) => c.command === "start_terminal")).toHaveLength(0);
  });

  it("rule 1: a refusal at the ceiling is displayed and not retried", async () => {
    const mock = createMockIpc({ scenario: "fresh" });
    for (const folder of ["/a", "/b"]) {
      await mock.client.start_terminal({
        provider: "claude",
        folder,
        confirm_personal_use: true,
      });
    }
    const { user } = renderRoute("/sessions", { mock });
    await user.click(await screen.findByRole("button", { name: "Choose" }));
    const open = await screen.findByRole("button", { name: /Open Claude Code/ });
    await waitFor(() => {
      expect(open).toBeEnabled();
    });
    await user.click(open);
    // The status list may not have loaded yet, in which case the backend hears the confirmation again.
    const confirm = screen.queryByRole("button", { name: "It is my own account" });
    if (confirm !== null) await user.click(confirm);
    expect(await screen.findByText(/Blocked by rule 1/)).toBeInTheDocument();
    expect(mock.control.calls.filter((c) => c.command === "start_terminal")).toHaveLength(3);
  });
});

describe("one terminal", () => {
  async function liveSession() {
    const mock = createMockIpc({ scenario: "fresh" });
    const session = await mock.client.start_terminal({
      provider: "codex",
      folder: "/work/project",
      confirm_personal_use: true,
    });
    return { mock, session };
  }

  it("rule 5: links never open", async () => {
    const { mock, session } = await liveSession();
    const open = vi.spyOn(window, "open");
    renderRoute(`/sessions/${session.session_id}`, { mock });
    await screen.findByRole("region", { name: "Terminal" });
    await waitFor(() => {
      expect(xterm.options).toHaveLength(1);
    });
    const handler = xterm.options[0]?.linkHandler as { activate: () => void };
    handler.activate();
    expect(open).not.toHaveBeenCalled();
  });

  it("output reaches only xterm's write, even when it looks like markup", async () => {
    const { mock, session } = await liveSession();
    const bait = "<img src=x onerror=alert(1)>";
    mock.control.backend.printToTerminal(session.session_id, bait);
    const { container } = renderRoute(`/sessions/${session.session_id}`, { mock });
    await waitFor(() => {
      expect(written()).toContain(bait);
    });
    expect(container.querySelector("img")).toBeNull();
  });

  it("rule 4: output is never stored or logged", async () => {
    const { mock, session } = await liveSession();
    const secret = "output-marker-do-not-keep";
    const log = vi.spyOn(console, "log");
    const set = vi.spyOn(Storage.prototype, "setItem");
    mock.control.backend.printToTerminal(session.session_id, secret);
    renderRoute(`/sessions/${session.session_id}`, { mock });
    await waitFor(() => {
      expect(written()).toContain(secret);
    });
    for (const call of [...log.mock.calls, ...set.mock.calls]) {
      expect(JSON.stringify(call)).not.toContain(secret);
    }
  });

  it("chunks printed after the attach arrive, in order, without repeats", async () => {
    const { mock, session } = await liveSession();
    mock.control.backend.printToTerminal(session.session_id, "first ");
    renderRoute(`/sessions/${session.session_id}`, { mock });
    await waitFor(() => {
      expect(written()).toBe("first ");
    });
    mock.control.backend.printToTerminal(session.session_id, "second ");
    mock.control.backend.printToTerminal(session.session_id, "third");
    await waitFor(() => {
      expect(written()).toBe("first second third");
    });
  });

  it("rule 3: rendering issues no write, and a locked session says so", async () => {
    const { mock, session } = await liveSession();
    const { user } = renderRoute(`/sessions/${session.session_id}`, { mock });
    await user.click(await screen.findByRole("button", { name: "Lock keyboard" }));
    expect(await screen.findByText(/Keystrokes do not reach this session/)).toBeInTheDocument();
    expect(await screen.findByRole("button", { name: "Take over" })).toBeInTheDocument();
    expect(mock.control.calls.filter((c) => c.command === "pty_write")).toHaveLength(0);
  });

  it("stop asks first, then shows the session ended", async () => {
    const { mock, session } = await liveSession();
    const { user } = renderRoute(`/sessions/${session.session_id}`, { mock });
    await user.click(await screen.findByRole("button", { name: "Stop" }));
    expect(mock.control.calls.filter((c) => c.command === "kill_session")).toHaveLength(0);
    const dialog = await screen.findByRole("alertdialog");
    expect(dialog).toHaveTextContent("Files in the folder stay");
    await user.click(screen.getByRole("button", { name: "Stop" }));
    expect(await screen.findByText("Session ended.")).toBeInTheDocument();
    expect(mock.control.calls.filter((c) => c.command === "kill_session")).toHaveLength(1);
  });

  it("an unknown session id explains itself", async () => {
    renderRoute("/sessions/t-999", { mock: "fresh" });
    expect(await screen.findByText("Session not found")).toBeInTheDocument();
  });
});
