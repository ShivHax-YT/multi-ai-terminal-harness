// Tauri transport for contract v1. With the port modules this is the only code that calls `invoke` (one IPC door);
// production builds always use it (./index.ts). Every rejection is normalized to an IpcRejection.

import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";

import {
  toIpcRejection,
  type ApprovalPort,
  type CommandName,
  type IpcBundle,
  type IpcClient,
  type PtyInputPort,
} from "./contract";

async function call<T>(command: CommandName, args?: Record<string, unknown>): Promise<T> {
  try {
    return await invoke<T>(command, args);
  } catch (error) {
    throw toIpcRejection(error);
  }
}

function createClient(): IpcClient {
  return {
    get_app_info: () => call("get_app_info"),

    list_providers: () => call("list_providers"),
    refresh_provider_status: (args) => call("refresh_provider_status", { ...args }),
    open_provider_login: (args) => call("open_provider_login", { ...args }),
    confirm_personal_use: (args) => call("confirm_personal_use", { ...args }),
    set_api_key: (args) => call("set_api_key", { ...args }),
    update_spend_caps: (args) => call("update_spend_caps", { ...args }),
    remove_api_key: (args) => call("remove_api_key", { ...args }),

    start_lead_request: (args) => call("start_lead_request", { ...args }),
    cancel_lead_request: (args) => call("cancel_lead_request", { ...args }),
    list_lead_requests: () => call("list_lead_requests"),

    list_plans: () => call("list_plans"),
    get_plan: (args) => call("get_plan", { ...args }),
    update_plan: (args) => call("update_plan", { ...args }),
    discard_plan: (args) => call("discard_plan", { ...args }),

    list_sessions: () => call("list_sessions"),
    pause_session: (args) => call("pause_session", { ...args }),
    resume_session: (args) => call("resume_session", { ...args }),
    kill_session: (args) => call("kill_session", { ...args }),
    set_takeover: (args) => call("set_takeover", { ...args }),
    resume_provider: (args) => call("resume_provider", { ...args }),
    attach_terminal: (args) => call("attach_terminal", { ...args }),
    resize_terminal: (args) => call("resize_terminal", { ...args }),

    list_reviews: () => call("list_reviews"),
    get_review: (args) => call("get_review", { ...args }),
    mark_reviewed: (args) => call("mark_reviewed", { ...args }),

    get_usage: () => call("get_usage"),
    get_limits: () => call("get_limits"),
    get_settings: () => call("get_settings"),
    update_settings: (args) => call("update_settings", { ...args }),
    get_killswitch_status: () => call("get_killswitch_status"),

    listen: async (event, handler) => {
      const unlisten = await listen<Parameters<typeof handler>[0]>(event, (e) => {
        handler(e.payload);
      });
      return unlisten;
    },
  };
}

/** Rule 9: handed out only through ./approval (useApproval). */
function createApproval(): ApprovalPort {
  return { approve_plan: (args) => call("approve_plan", { ...args }) };
}

/** Rule 3: handed out only through ./pty-input (usePtyInput). */
function createPtyInput(): PtyInputPort {
  return { pty_write: (args) => call("pty_write", { ...args }) };
}

export function createTauriIpc(): IpcBundle {
  return { client: createClient(), approval: createApproval(), ptyInput: createPtyInput() };
}
