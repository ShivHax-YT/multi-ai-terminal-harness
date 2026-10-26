// Every IPC command is listed here so tauri-build generates one `allow-<command>` permission per command, and
// capabilities/main.json grants exactly those. A command missing from this list cannot be called from the webview.
// src/test/command-parity.test.ts checks that this list, lib.rs `generate_handler!`, the capability and the TS
// contract (src/lib/ipc/contract.ts) name the same commands.
const COMMANDS: &[&str] = &[
    "get_app_info",
    "list_providers",
    "refresh_provider_status",
    "open_provider_login",
    "confirm_personal_use",
    "set_api_key",
    "update_spend_caps",
    "remove_api_key",
    "start_lead_request",
    "cancel_lead_request",
    "list_lead_requests",
    "list_plans",
    "get_plan",
    "update_plan",
    "discard_plan",
    "approve_plan",
    "list_sessions",
    "pause_session",
    "resume_session",
    "kill_session",
    "set_takeover",
    "resume_provider",
    "attach_terminal",
    "resize_terminal",
    "pty_write",
    "list_reviews",
    "get_review",
    "mark_reviewed",
    "get_usage",
    "get_limits",
    "get_settings",
    "update_settings",
    "get_killswitch_status",
];

fn main() {
    tauri_build::try_build(
        tauri_build::Attributes::new()
            .app_manifest(tauri_build::AppManifest::new().commands(COMMANDS)),
    )
    .expect("tauri-build failed");
}
