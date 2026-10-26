//! Harness app shell: registers the IPC commands of the contract (docs/tasks/T-101-ipc-contract.md).
//!
//! No Tauri plugins are registered (rules 4, 5, 6). The webview's only door into the backend is the command list
//! below, granted one by one in capabilities/main.json.

pub mod commands;

/// Starts the app.
pub fn run() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![
            commands::get_app_info,
            commands::list_providers,
            commands::refresh_provider_status,
            commands::open_provider_login,
            commands::confirm_personal_use,
            commands::set_api_key,
            commands::update_spend_caps,
            commands::remove_api_key,
            commands::start_lead_request,
            commands::cancel_lead_request,
            commands::list_lead_requests,
            commands::list_plans,
            commands::get_plan,
            commands::update_plan,
            commands::discard_plan,
            commands::approve_plan,
            commands::list_sessions,
            commands::pause_session,
            commands::resume_session,
            commands::kill_session,
            commands::set_takeover,
            commands::resume_provider,
            commands::attach_terminal,
            commands::resize_terminal,
            commands::pty_write,
            commands::list_reviews,
            commands::get_review,
            commands::mark_reviewed,
            commands::get_usage,
            commands::get_limits,
            commands::get_settings,
            commands::update_settings,
            commands::get_killswitch_status,
        ])
        .run(tauri::generate_context!())
        .expect("error while running Harness");
}
