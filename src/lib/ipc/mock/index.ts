// Stateful mock of the Harness backend for dev and tests. Never part of a production build: the sentinel below
// makes `make check` fail if this module reaches dist/.

import type { ApprovalPort, CommandName, IpcClient, IpcError, IpcEventName, IpcEvents, PtyInputPort } from "../contract";
import { MOCK_SCENARIOS, MockBackend, type MockCall, type MockScenario } from "./backend";

export { MOCK_SCENARIOS, MockBackend, LEAD_THINK_MS, SCROLLBACK_CAP_BYTES } from "./backend";
export type { MockCall, MockScenario } from "./backend";

export const MOCK_SENTINEL = "__HARNESS_MOCK__";

export interface MockControl {
  /** Moves the fake clock forward and runs every timer that falls due. */
  advance(ms: number): Promise<void>;
  emit<E extends IpcEventName>(event: E, payload: IpcEvents[E]): void;
  failNext(command: CommandName, error: IpcError): void;
  setUserIdle(minutes: number): Promise<void>;
  /** Every `{command, args}` call so far (API keys are recorded as "<redacted>"). */
  readonly calls: readonly MockCall[];
  readonly backend: MockBackend;
  readonly sentinel: typeof MOCK_SENTINEL;
}

export interface MockIpc {
  client: IpcClient;
  approval: ApprovalPort;
  ptyInput: PtyInputPort;
  control: MockControl;
}

export interface MockOptions {
  scenario?: MockScenario;
  /** Fake clock start, ms since the epoch. Defaults to 2026-10-25T09:30:00Z so fixtures and snapshots are stable. */
  now?: number;
}

export const MOCK_DEFAULT_NOW = Date.parse("2026-10-25T09:30:00Z");

export function createMockIpc(options: MockOptions = {}): MockIpc {
  const backend = new MockBackend(options.scenario ?? "ready", options.now ?? MOCK_DEFAULT_NOW);
  const control: MockControl = {
    advance: (ms) => backend.advance(ms),
    emit: (event, payload) => {
      backend.emit(event, payload);
    },
    failNext: (command, error) => {
      backend.failNext(command, error);
    },
    setUserIdle: (minutes) => backend.setUserIdle(minutes),
    get calls() {
      return backend.calls;
    },
    backend,
    sentinel: MOCK_SENTINEL,
  };
  return { client: backend.client, approval: backend.approval, ptyInput: backend.ptyInput, control };
}

function isScenario(value: unknown): value is MockScenario {
  return typeof value === "string" && (MOCK_SCENARIOS as readonly string[]).includes(value);
}

/** Dev server only (src/lib/ipc/index.ts): real time drives the fake clock. Scenario from VITE_HARNESS_MOCK_SCENARIO. */
export function createDevMockIpc(scenario: unknown): MockIpc {
  const chosen = isScenario(scenario) ? scenario : "ready";
  const mock = createMockIpc({ scenario: chosen, now: Date.now() });
  const tick = 250;
  setInterval(() => {
    void mock.control.advance(tick);
  }, tick);
  console.info(`[${MOCK_SENTINEL}] dev IPC mock, scenario "${chosen}"`);
  return mock;
}
