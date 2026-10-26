// Test helper: render the whole app (shell + routes) at a path against the stateful mock.
//
//   const { mock, user } = renderRoute("/plans/plan-1", { mock: "plan_draft" });
//   await screen.findByRole("heading", { name: "Plans" });
//   await mock.control.advance(1500);
//   expect(mock.control.calls.filter((c) => c.command === "pty_write")).toHaveLength(0);
import { render, type RenderResult } from "@testing-library/react";
import userEvent, { type UserEvent } from "@testing-library/user-event";

import { App } from "@/app/app";
import { createMockIpc, type MockIpc, type MockScenario } from "@/lib/ipc/mock";

export interface RenderRouteOptions {
  /** A scenario name (fresh mock) or a mock you created and want to keep driving. Default "ready". */
  mock?: MockScenario | MockIpc;
}

export interface RenderRouteResult extends RenderResult {
  mock: MockIpc;
  user: UserEvent;
}

export function renderRoute(path: string, options: RenderRouteOptions = {}): RenderRouteResult {
  const mock =
    typeof options.mock === "object"
      ? options.mock
      : createMockIpc({ scenario: options.mock ?? "ready" });
  window.location.hash = `#${path}`;
  const user = userEvent.setup();
  const result = render(<App bundle={mock} />);
  return { ...result, mock, user };
}
