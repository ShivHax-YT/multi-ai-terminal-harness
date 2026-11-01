//! IPC command stubs for contract v1 (docs/tasks/T-101-ipc-contract.md).
//!
//! Most reads return UI fixtures (`src/lib/ipc/fixtures/*.json`); provider status and human terminals are real, and
//! `get_limits` is built from the compiled ceilings in `harness_core`. Other mutations return
//! `not_implemented` until their brief lands. Two refusals are permanent properties of this layer:
//! - `approve_plan` never mints an approval (rule 9: only the scheduler-verified UI click path will);
//! - `pty_write` refuses with rule 3 unless that human terminal's take-over is on.
//!
//! Argument values are never logged or echoed (an API key passes through `set_api_key`).

use crate::terminals::{provider_spec, TerminalError, Terminals};
use base64::Engine;
use harness_core::compliance::ceilings::{
    LimitRule, Stricter, Unit, LIMIT_RULES, SPEND_CAP_MAX_DAILY_USD, SPEND_CAP_MAX_WEEKLY_USD,
};
use serde::Serialize;
use serde_json::{json, Map, Value};
use std::sync::{Arc, OnceLock};

const USAGE_JSON: &str = include_str!("../../src/lib/ipc/fixtures/usage.json");
const SETTINGS_JSON: &str = include_str!("../../src/lib/ipc/fixtures/settings.json");
const KILLSWITCH_JSON: &str = include_str!("../../src/lib/ipc/fixtures/killswitch.json");
#[cfg(test)]
const LIMITS_JSON: &str = include_str!("../../src/lib/ipc/fixtures/limits.json");

/// `IpcError.kind` in the contract.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum IpcErrorKind {
    NotFound,
    InvalidInput,
    RuleBlocked,
    PlanHashMismatch,
    PlanHasViolations,
    RateLimited,
    NotImplemented,
    Internal,
}

/// The only rejection type of every command.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct IpcError {
    pub kind: IpcErrorKind,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rule: Option<u8>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub retry_at: Option<String>,
}

impl IpcError {
    fn new(kind: IpcErrorKind, message: impl Into<String>) -> Self {
        Self {
            kind,
            message: message.into(),
            rule: None,
            retry_at: None,
        }
    }

    fn not_implemented(command: &str) -> Self {
        Self::new(
            IpcErrorKind::NotImplemented,
            format!("{command} is not implemented yet"),
        )
    }

    fn not_found(what: &str) -> Self {
        Self::new(IpcErrorKind::NotFound, format!("{what} not found"))
    }

    fn rule_blocked(rule: u8, message: impl Into<String>) -> Self {
        Self {
            rule: Some(rule),
            ..Self::new(IpcErrorKind::RuleBlocked, message)
        }
    }

    fn internal(message: impl Into<String>) -> Self {
        Self::new(IpcErrorKind::Internal, message)
    }
}

pub type IpcResult<T> = Result<T, IpcError>;

/// `AppInfo` in the contract.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct AppInfo {
    pub name: String,
    pub version: String,
    pub identifier: String,
}

/// `{session_id}` / `{request_id}` results.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct SessionRef {
    pub session_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct RequestRef {
    pub request_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct TerminalAttach {
    pub cols: u16,
    pub rows: u16,
    /// The `seq` of the newest chunk in the scrollback. Later chunks arrive as `terminal_output` events.
    pub seq: u64,
    pub scrollback_b64: String,
}

fn fixture(src: &str) -> IpcResult<Value> {
    serde_json::from_str(src).map_err(|_| IpcError::internal("bundled fixture is not valid JSON"))
}

/// Drops arguments a stub does not use yet, without logging them.
fn unused<T>(_args: T) {}

// ---- app --------------------------------------------------------------------------------------------------------

#[tauri::command(rename_all = "snake_case")]
pub fn get_app_info(app: tauri::AppHandle) -> IpcResult<AppInfo> {
    let info = app.package_info();
    Ok(AppInfo {
        name: app
            .config()
            .product_name
            .clone()
            .unwrap_or_else(|| info.name.clone()),
        version: info.version.to_string(),
        identifier: app.config().identifier.clone(),
    })
}

// ---- providers --------------------------------------------------------------------------------------------------

fn provider_registry() -> Arc<harness_core::status::ProviderRegistry> {
    static REGISTRY: OnceLock<Arc<harness_core::status::ProviderRegistry>> = OnceLock::new();
    REGISTRY
        .get_or_init(|| Arc::new(harness_core::status::ProviderRegistry::default()))
        .clone()
}

fn provider_id(provider: &str) -> IpcResult<harness_core::provider::ProviderId> {
    provider
        .parse()
        .map_err(|_| IpcError::new(IpcErrorKind::InvalidInput, "Unknown provider"))
}

#[tauri::command(rename_all = "snake_case")]
pub async fn list_providers() -> IpcResult<Value> {
    let registry = provider_registry();
    tauri::async_runtime::spawn_blocking(move || Ok(json!(registry.list())))
        .await
        .map_err(|_| IpcError::internal("Provider check could not complete"))?
}

#[tauri::command(rename_all = "snake_case")]
pub async fn refresh_provider_status(provider: String) -> IpcResult<Value> {
    let provider = provider_id(&provider)?;
    let registry = provider_registry();
    tauri::async_runtime::spawn_blocking(move || Ok(registry.refresh(provider)))
        .await
        .map_err(|_| IpcError::internal("Provider check could not complete"))?
}

#[tauri::command(rename_all = "snake_case")]
pub fn open_provider_login(provider: String) -> IpcResult<SessionRef> {
    unused(provider);
    Err(IpcError::not_implemented("open_provider_login"))
}

#[tauri::command(rename_all = "snake_case")]
pub async fn confirm_personal_use(provider: String) -> IpcResult<Value> {
    let provider = provider_id(&provider)?;
    let registry = provider_registry();
    tauri::async_runtime::spawn_blocking(move || {
        registry
            .confirm(provider)
            .map_err(|e| IpcError::rule_blocked(5, e))
    })
    .await
    .map_err(|_| IpcError::internal("Account confirmation could not complete"))?
}

#[tauri::command(rename_all = "snake_case")]
pub fn set_api_key(provider: String, key: String, caps: Value) -> IpcResult<Value> {
    unused((provider, key, caps));
    Err(IpcError::not_implemented("set_api_key"))
}

#[tauri::command(rename_all = "snake_case")]
pub fn update_spend_caps(provider: String, caps: Value) -> IpcResult<Value> {
    unused((provider, caps));
    Err(IpcError::not_implemented("update_spend_caps"))
}

#[tauri::command(rename_all = "snake_case")]
pub fn remove_api_key(provider: String) -> IpcResult<Value> {
    unused(provider);
    Err(IpcError::not_implemented("remove_api_key"))
}

// ---- lead -------------------------------------------------------------------------------------------------------

#[tauri::command(rename_all = "snake_case")]
pub fn start_lead_request(lead: String, text: String) -> IpcResult<RequestRef> {
    unused((lead, text));
    Err(IpcError::not_implemented("start_lead_request"))
}

#[tauri::command(rename_all = "snake_case")]
pub fn cancel_lead_request(request_id: String) -> IpcResult<()> {
    unused(request_id);
    Err(IpcError::not_implemented("cancel_lead_request"))
}

#[tauri::command(rename_all = "snake_case")]
pub fn list_lead_requests() -> IpcResult<Value> {
    Ok(json!([]))
}

// ---- plans ------------------------------------------------------------------------------------------------------

#[tauri::command(rename_all = "snake_case")]
pub fn list_plans() -> IpcResult<Value> {
    Ok(json!([]))
}

#[tauri::command(rename_all = "snake_case")]
pub fn get_plan(plan_id: String) -> IpcResult<Value> {
    unused(plan_id);
    Err(IpcError::not_found("plan"))
}

#[tauri::command(rename_all = "snake_case")]
pub fn update_plan(plan_id: String, edit: Value) -> IpcResult<Value> {
    unused((plan_id, edit));
    Err(IpcError::not_implemented("update_plan"))
}

#[tauri::command(rename_all = "snake_case")]
pub fn discard_plan(plan_id: String) -> IpcResult<()> {
    unused(plan_id);
    Err(IpcError::not_implemented("discard_plan"))
}

/// Rule 9: the stub never mints an approval token. The real command creates one only for a user click, bound to the
/// plan hash the user saw, and only for a plan with no open violations.
#[tauri::command(rename_all = "snake_case")]
pub fn approve_plan(plan_id: String, plan_hash: String) -> IpcResult<Value> {
    unused((plan_id, plan_hash));
    Err(IpcError::not_implemented("approve_plan"))
}

// ---- sessions ---------------------------------------------------------------------------------------------------

fn terminal_error(error: TerminalError) -> IpcError {
    match error {
        TerminalError::NotFound => IpcError::not_found("session"),
        TerminalError::AtCeiling => IpcError::rule_blocked(
            1,
            "This provider already has its maximum of 2 terminals open. Stop one first.",
        ),
        TerminalError::TakeoverOff => IpcError::rule_blocked(
            3,
            "take-over is off for this session; automation never types into a terminal",
        ),
        TerminalError::Ended => IpcError::new(IpcErrorKind::InvalidInput, "The session has ended."),
        TerminalError::Failed(message) => IpcError::internal(message),
    }
}

#[tauri::command(rename_all = "snake_case")]
pub fn list_sessions() -> IpcResult<Value> {
    Ok(Terminals::shared().list())
}

/// A human click starts one interactive CLI in a folder the human chose. No prompt or other text from the app reaches
/// the CLI. Rule 5: refused until the human has confirmed this is their own account.
#[tauri::command(rename_all = "snake_case")]
pub async fn start_terminal(
    provider: String,
    folder: String,
    confirm_personal_use: bool,
) -> IpcResult<Value> {
    let provider = provider_id(&provider)?;
    let registry = provider_registry();
    tauri::async_runtime::spawn_blocking(move || {
        if !harness_core::status::human_terminal_supported(provider) {
            return Err(IpcError::new(
                IpcErrorKind::InvalidInput,
                "This provider has no supported terminal yet.",
            ));
        }
        // The folder is checked before confirmation so a bad path is not hidden, and before any launch.
        let folder = harness_core::status::human_terminal_folder(std::path::Path::new(&folder))
            .map_err(|message| IpcError::new(IpcErrorKind::InvalidInput, message))?;
        if confirm_personal_use {
            registry.note_personal_use(provider);
        }
        if !registry.personal_use_confirmed(provider) {
            return Err(IpcError::rule_blocked(
                5,
                "Confirm that this is your own personal account first.",
            ));
        }
        harness_core::status::human_terminal_check(provider)
            .map_err(|message| IpcError::new(IpcErrorKind::InvalidInput, message))?;
        let name = provider.as_str();
        let title = folder
            .file_name()
            .map_or_else(|| "/".to_owned(), |n| n.to_string_lossy().into_owned());
        let shown = folder.to_string_lossy().into_owned();
        let spec = provider_spec(name, folder).map_err(IpcError::internal)?;
        Terminals::shared()
            .start(name, &title, &shown, spec)
            .map_err(terminal_error)
    })
    .await
    .map_err(|_| IpcError::internal("The terminal could not start."))?
}

/// The native folder panel. Returns null when the human cancels.
#[tauri::command(rename_all = "snake_case")]
pub async fn choose_terminal_folder(app: tauri::AppHandle) -> IpcResult<Option<String>> {
    let (send, receive) = std::sync::mpsc::channel();
    app.run_on_main_thread(move || {
        let _ = send.send(harness_core::process::choose_folder());
    })
    .map_err(|_| IpcError::internal("The folder panel could not open."))?;
    let chosen = tauri::async_runtime::spawn_blocking(move || receive.recv().ok().flatten())
        .await
        .map_err(|_| IpcError::internal("The folder panel could not open."))?;
    Ok(chosen.map(|path| path.to_string_lossy().into_owned()))
}

#[tauri::command(rename_all = "snake_case")]
pub fn pause_session(session_id: String) -> IpcResult<Value> {
    unused(session_id);
    Err(IpcError::not_implemented("pause_session"))
}

#[tauri::command(rename_all = "snake_case")]
pub fn resume_session(session_id: String) -> IpcResult<Value> {
    unused(session_id);
    Err(IpcError::not_implemented("resume_session"))
}

#[tauri::command(rename_all = "snake_case")]
pub fn kill_session(session_id: String) -> IpcResult<Value> {
    Terminals::shared()
        .kill(&session_id)
        .map_err(terminal_error)
}

#[tauri::command(rename_all = "snake_case")]
pub fn set_takeover(session_id: String, enabled: bool) -> IpcResult<Value> {
    Terminals::shared()
        .set_takeover(&session_id, enabled)
        .map_err(terminal_error)
}

#[tauri::command(rename_all = "snake_case")]
pub fn resume_provider(provider: String) -> IpcResult<()> {
    unused(provider);
    Err(IpcError::not_implemented("resume_provider"))
}

#[tauri::command(rename_all = "snake_case")]
pub fn attach_terminal(session_id: String) -> IpcResult<TerminalAttach> {
    let attach = Terminals::shared()
        .attach(&session_id)
        .map_err(terminal_error)?;
    Ok(TerminalAttach {
        cols: attach.cols,
        rows: attach.rows,
        seq: attach.seq,
        scrollback_b64: base64::engine::general_purpose::STANDARD.encode(attach.scrollback),
    })
}

#[tauri::command(rename_all = "snake_case")]
pub fn resize_terminal(session_id: String, cols: u16, rows: u16) -> IpcResult<()> {
    Terminals::shared()
        .resize(&session_id, cols, rows)
        .map_err(terminal_error)
}

/// Rule 3: human keystrokes reach a PTY only while that session's take-over is on. An unknown session has no take-over,
/// so it refuses the same way. Off the main thread, because a CLI that stops reading must not freeze the window. The
/// data is never logged.
#[tauri::command(rename_all = "snake_case")]
pub async fn pty_write(session_id: String, data: String) -> IpcResult<()> {
    tauri::async_runtime::spawn_blocking(move || {
        Terminals::shared()
            .write(&session_id, &data)
            .map_err(terminal_error)
    })
    .await
    .map_err(|_| IpcError::internal("The keystroke did not reach the terminal."))?
}

// ---- review -----------------------------------------------------------------------------------------------------

#[tauri::command(rename_all = "snake_case")]
pub fn list_reviews() -> IpcResult<Value> {
    Ok(json!([]))
}

#[tauri::command(rename_all = "snake_case")]
pub fn get_review(task_id: String) -> IpcResult<Value> {
    unused(task_id);
    Err(IpcError::not_found("review"))
}

#[tauri::command(rename_all = "snake_case")]
pub fn mark_reviewed(task_id: String) -> IpcResult<Value> {
    unused(task_id);
    Err(IpcError::not_implemented("mark_reviewed"))
}

// ---- usage, limits, settings, kill switch -----------------------------------------------------------------------

#[tauri::command(rename_all = "snake_case")]
pub fn get_usage() -> IpcResult<Value> {
    fixture(USAGE_JSON)
}

fn limit_rule_json(rule: &LimitRule) -> Value {
    let stricter = match rule.stricter {
        Stricter::Lower => "lower",
        Stricter::Higher => "higher",
    };
    let unit = match rule.unit {
        Unit::Count => "count",
        Unit::PerHour => "per_hour",
        Unit::Minutes => "minutes",
        Unit::Seconds => "seconds",
    };
    json!({ "ceiling": rule.ceiling, "stricter": stricter, "bound": rule.bound, "unit": unit })
}

/// Built from the compiled ceilings (rule 1), never from a file or a setting.
#[tauri::command(rename_all = "snake_case")]
pub fn get_limits() -> IpcResult<Value> {
    let mut rules = Map::new();
    for rule in &LIMIT_RULES {
        rules.insert(rule.key.to_owned(), limit_rule_json(rule));
    }
    Ok(json!({
        "rules": rules,
        "spend_cap_max": { "daily_usd": SPEND_CAP_MAX_DAILY_USD, "weekly_usd": SPEND_CAP_MAX_WEEKLY_USD },
    }))
}

#[tauri::command(rename_all = "snake_case")]
pub fn get_settings() -> IpcResult<Value> {
    fixture(SETTINGS_JSON)
}

#[tauri::command(rename_all = "snake_case")]
pub fn update_settings(patch: Value) -> IpcResult<Value> {
    unused(patch);
    Err(IpcError::not_implemented("update_settings"))
}

/// Read-only (rule 12): the webview can never change the kill-switch state.
#[tauri::command(rename_all = "snake_case")]
pub fn get_killswitch_status() -> IpcResult<Value> {
    fixture(KILLSWITCH_JSON)
}

// ---- sample workflow: no provider automation ---------------------------------------------------------------
#[tauri::command(rename_all = "snake_case")]
pub fn sim_snapshot(
    state: tauri::State<'_, harness_core::plan::simulation::Simulation>,
) -> IpcResult<Value> {
    let plans = state.snapshot().map_err(IpcError::internal)?;
    Ok(
        json!({ "runtime": "native", "projects": [{ "id": "sample", "name": "Harness sample project" }], "plans": plans }),
    )
}

#[tauri::command(rename_all = "snake_case")]
pub fn sim_submit(
    state: tauri::State<'_, harness_core::plan::simulation::Simulation>,
    project_id: String,
    task: String,
) -> IpcResult<harness_core::plan::simulation::SimPlan> {
    state
        .submit(&project_id, &task)
        .map_err(|e| IpcError::new(IpcErrorKind::InvalidInput, e))
}

#[tauri::command(rename_all = "snake_case")]
pub fn sim_approve_plan(
    state: tauri::State<'_, harness_core::plan::simulation::Simulation>,
    plan_id: String,
    plan_hash: String,
) -> IpcResult<Value> {
    state
        .approve(&plan_id, &plan_hash)
        .map(|token| json!({ "token": token }))
        .map_err(|e| IpcError::rule_blocked(9, e))
}

#[tauri::command(rename_all = "snake_case")]
pub fn sim_run(
    state: tauri::State<'_, harness_core::plan::simulation::Simulation>,
    plan_id: String,
    plan_hash: String,
    token: String,
) -> IpcResult<harness_core::plan::simulation::SimPlan> {
    state
        .run(&plan_id, &plan_hash, &token)
        .map_err(|e| IpcError::rule_blocked(9, e))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(v: &str) -> String {
        v.to_owned()
    }

    #[test]
    fn limits_match_fixture() {
        let built = get_limits().expect("get_limits");
        let ui = fixture(LIMITS_JSON).expect("limits fixture");
        assert_eq!(
            built, ui,
            "UI limits fixture drifted from harness-core ceilings"
        );
    }

    #[test]
    fn limits_match_fixture_settings_defaults_are_the_ceilings() {
        let settings = get_settings().expect("settings");
        for rule in &LIMIT_RULES {
            assert_eq!(
                settings["limits"][rule.key].as_u64(),
                Some(u64::from(rule.ceiling)),
                "default for {} is not its ceiling",
                rule.key
            );
        }
    }

    #[test]
    fn stub_never_approves() {
        let hash = "0".repeat(64);
        let err = approve_plan(s("plan-1"), hash.clone()).expect_err("approve_plan must refuse");
        assert_eq!(err.kind, IpcErrorKind::NotImplemented);
        let empty_hash = approve_plan(s(""), s("")).expect_err("approve_plan must refuse");
        assert_eq!(empty_hash.kind, IpcErrorKind::NotImplemented);
        // No plan can be read back with an approval either.
        assert_eq!(
            get_plan(s("plan-1")).expect_err("no plans").kind,
            IpcErrorKind::NotFound
        );
        assert_eq!(list_plans().expect("list"), json!([]));
        let text = serde_json::to_string(&err).expect("serialize");
        assert!(!text.contains("approval"));
        assert!(!text.contains("nonce"));
    }

    #[test]
    fn pty_write_refuses_with_rule_3() {
        let err = tauri::async_runtime::block_on(pty_write(s("s-1"), s("ls\r")))
            .expect_err("pty_write must refuse");
        assert_eq!(err.kind, IpcErrorKind::RuleBlocked);
        assert_eq!(err.rule, Some(3));
        assert!(
            !err.message.contains("ls"),
            "input data must never be echoed"
        );
    }

    #[test]
    fn terminal_commands_on_an_unknown_session_are_not_found() {
        let nf = IpcErrorKind::NotFound;
        assert_eq!(kill_session(s("s")).unwrap_err().kind, nf);
        assert_eq!(set_takeover(s("s"), true).unwrap_err().kind, nf);
        assert_eq!(resize_terminal(s("s"), 80, 24).unwrap_err().kind, nf);
    }

    #[test]
    fn a_terminal_needs_the_personal_use_confirmation_and_a_supported_provider() {
        let folder = std::env::temp_dir();
        assert!(
            harness_core::status::human_terminal_folder(&folder).is_ok(),
            "the confirmation check has to run against a folder that would be accepted"
        );
        let folder_text = folder.to_string_lossy().into_owned();
        let run = |p: &str, confirm| {
            tauri::async_runtime::block_on(start_terminal(s(p), s(&folder_text), confirm))
                .unwrap_err()
        };
        assert_eq!(run("not-a-provider", true).kind, IpcErrorKind::InvalidInput);
        for provider in ["gemini", "grok", "kimi", "glm"] {
            assert_eq!(
                run(provider, true).kind,
                IpcErrorKind::InvalidInput,
                "{provider}"
            );
        }
        let before = list_sessions().expect("sessions");
        let claude = run("claude", false);
        assert_eq!(claude.kind, IpcErrorKind::RuleBlocked);
        assert_eq!(claude.rule, Some(5));
        let codex = run("codex", false);
        assert_eq!(codex.kind, IpcErrorKind::RuleBlocked);
        assert_eq!(codex.rule, Some(5));
        // Confirmation is refused before discover or launch, so no CLI and no session is started.
        assert_eq!(list_sessions().expect("sessions"), before);
    }

    #[test]
    fn set_api_key_never_echoes_the_key() {
        let secret = "sk-test-DO-NOT-ECHO-1234567890";
        let err = set_api_key(s("x"), s(secret), json!({"daily_usd": 1, "weekly_usd": 2}))
            .expect_err("stub");
        let text = serde_json::to_string(&err).expect("serialize");
        assert!(!text.contains(secret));
    }

    #[test]
    fn mutations_are_not_implemented() {
        let ni = IpcErrorKind::NotImplemented;
        assert_eq!(open_provider_login(s("x")).unwrap_err().kind, ni);
        assert_eq!(update_spend_caps(s("x"), json!({})).unwrap_err().kind, ni);
        assert_eq!(remove_api_key(s("x")).unwrap_err().kind, ni);
        assert_eq!(start_lead_request(s("x"), s("t")).unwrap_err().kind, ni);
        assert_eq!(cancel_lead_request(s("r")).unwrap_err().kind, ni);
        assert_eq!(update_plan(s("p"), json!({})).unwrap_err().kind, ni);
        assert_eq!(discard_plan(s("p")).unwrap_err().kind, ni);
        assert_eq!(pause_session(s("s")).unwrap_err().kind, ni);
        assert_eq!(resume_session(s("s")).unwrap_err().kind, ni);
        assert_eq!(resume_provider(s("x")).unwrap_err().kind, ni);
        assert_eq!(mark_reviewed(s("t")).unwrap_err().kind, ni);
        assert_eq!(update_settings(json!({})).unwrap_err().kind, ni);
    }

    #[test]
    fn provider_status_validates_identifiers_without_querying_any_cli() {
        assert_eq!(
            provider_id("claude").unwrap(),
            harness_core::provider::ProviderId::Claude
        );
        assert_eq!(
            provider_id("claude; command").unwrap_err().kind,
            IpcErrorKind::InvalidInput
        );
        let source = include_str!("commands.rs");
        let production = source.split("#[cfg(test)]\nmod tests").next().unwrap();
        assert!(!production.contains("fixtures/providers.json"));
    }

    #[test]
    fn other_reads_return_fixtures() {
        assert!(get_usage().expect("usage")["providers"].is_array());
        assert!(get_killswitch_status().expect("ks")["adapters"].is_array());
        assert_eq!(list_lead_requests().expect("lead"), json!([]));
        assert_eq!(list_sessions().expect("sessions"), json!([]));
        assert_eq!(list_reviews().expect("reviews"), json!([]));
        assert_eq!(
            attach_terminal(s("s")).unwrap_err().kind,
            IpcErrorKind::NotFound
        );
        assert_eq!(get_review(s("t")).unwrap_err().kind, IpcErrorKind::NotFound);
    }

    #[test]
    fn ipc_error_serializes_like_the_contract() {
        let v = serde_json::to_value(IpcError::rule_blocked(3, "m")).expect("json");
        assert_eq!(
            v,
            json!({"kind": "rule_blocked", "message": "m", "rule": 3})
        );
        let v = serde_json::to_value(IpcError::not_implemented("x")).expect("json");
        assert_eq!(
            v,
            json!({"kind": "not_implemented", "message": "x is not implemented yet"})
        );
    }
}
