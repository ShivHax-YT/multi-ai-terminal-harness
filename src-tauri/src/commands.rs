//! IPC command stubs for contract v1 (docs/tasks/T-101-ipc-contract.md).
//!
//! Reads return the UI fixtures (`src/lib/ipc/fixtures/*.json`) so the Tauri build renders the same empty and ready
//! states as the dev mock; `get_limits` is built from the compiled ceilings in `harness_core`. Mutations return
//! `not_implemented` until their brief lands. Two refusals are permanent properties of the stubs:
//! - `approve_plan` never mints an approval (rule 9: only the scheduler-verified UI click path will);
//! - `pty_write` always refuses with rule 3 (no session has take-over on, because no session exists).
//!
//! Argument values are never logged or echoed (an API key passes through `set_api_key`).

use harness_core::compliance::ceilings::{
    LimitRule, Stricter, Unit, LIMIT_RULES, SPEND_CAP_MAX_DAILY_USD, SPEND_CAP_MAX_WEEKLY_USD,
};
use serde::Serialize;
use serde_json::{json, Map, Value};

const PROVIDERS_JSON: &str = include_str!("../../src/lib/ipc/fixtures/providers.json");
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
        name: info.name.clone(),
        version: info.version.to_string(),
        identifier: app.config().identifier.clone(),
    })
}

// ---- providers --------------------------------------------------------------------------------------------------

#[tauri::command(rename_all = "snake_case")]
pub fn list_providers() -> IpcResult<Value> {
    fixture(PROVIDERS_JSON)
}

#[tauri::command(rename_all = "snake_case")]
pub fn refresh_provider_status(provider: String) -> IpcResult<Value> {
    let all = fixture(PROVIDERS_JSON)?;
    all.as_array()
        .and_then(|list| {
            list.iter()
                .find(|p| p.get("provider").and_then(Value::as_str) == Some(provider.as_str()))
        })
        .cloned()
        .ok_or_else(|| IpcError::not_found("provider"))
}

#[tauri::command(rename_all = "snake_case")]
pub fn open_provider_login(provider: String) -> IpcResult<SessionRef> {
    unused(provider);
    Err(IpcError::not_implemented("open_provider_login"))
}

#[tauri::command(rename_all = "snake_case")]
pub fn confirm_personal_use(provider: String) -> IpcResult<Value> {
    unused(provider);
    Err(IpcError::not_implemented("confirm_personal_use"))
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

#[tauri::command(rename_all = "snake_case")]
pub fn list_sessions() -> IpcResult<Value> {
    Ok(json!([]))
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
    unused(session_id);
    Err(IpcError::not_implemented("kill_session"))
}

#[tauri::command(rename_all = "snake_case")]
pub fn set_takeover(session_id: String, enabled: bool) -> IpcResult<Value> {
    unused((session_id, enabled));
    Err(IpcError::not_implemented("set_takeover"))
}

#[tauri::command(rename_all = "snake_case")]
pub fn resume_provider(provider: String) -> IpcResult<()> {
    unused(provider);
    Err(IpcError::not_implemented("resume_provider"))
}

#[tauri::command(rename_all = "snake_case")]
pub fn attach_terminal(session_id: String) -> IpcResult<TerminalAttach> {
    unused(session_id);
    Err(IpcError::not_found("session"))
}

#[tauri::command(rename_all = "snake_case")]
pub fn resize_terminal(session_id: String, cols: u16, rows: u16) -> IpcResult<()> {
    unused((session_id, cols, rows));
    Err(IpcError::not_implemented("resize_terminal"))
}

/// Rule 3: human keystrokes reach a PTY only while that session's take-over is on. No session exists in the stub,
/// so this always refuses. The data is never logged.
#[tauri::command(rename_all = "snake_case")]
pub fn pty_write(session_id: String, data: String) -> IpcResult<()> {
    unused((session_id, data));
    Err(IpcError::rule_blocked(
        3,
        "take-over is off for this session; automation never types into a terminal",
    ))
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
        let err = pty_write(s("s-1"), s("ls\r")).expect_err("pty_write must refuse");
        assert_eq!(err.kind, IpcErrorKind::RuleBlocked);
        assert_eq!(err.rule, Some(3));
        assert!(
            !err.message.contains("ls"),
            "input data must never be echoed"
        );
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
        assert_eq!(confirm_personal_use(s("x")).unwrap_err().kind, ni);
        assert_eq!(update_spend_caps(s("x"), json!({})).unwrap_err().kind, ni);
        assert_eq!(remove_api_key(s("x")).unwrap_err().kind, ni);
        assert_eq!(start_lead_request(s("x"), s("t")).unwrap_err().kind, ni);
        assert_eq!(cancel_lead_request(s("r")).unwrap_err().kind, ni);
        assert_eq!(update_plan(s("p"), json!({})).unwrap_err().kind, ni);
        assert_eq!(discard_plan(s("p")).unwrap_err().kind, ni);
        assert_eq!(pause_session(s("s")).unwrap_err().kind, ni);
        assert_eq!(resume_session(s("s")).unwrap_err().kind, ni);
        assert_eq!(kill_session(s("s")).unwrap_err().kind, ni);
        assert_eq!(set_takeover(s("s"), true).unwrap_err().kind, ni);
        assert_eq!(resume_provider(s("x")).unwrap_err().kind, ni);
        assert_eq!(resize_terminal(s("s"), 80, 24).unwrap_err().kind, ni);
        assert_eq!(mark_reviewed(s("t")).unwrap_err().kind, ni);
        assert_eq!(update_settings(json!({})).unwrap_err().kind, ni);
    }

    #[test]
    fn reads_return_fixtures() {
        let providers = list_providers().expect("providers");
        let list = providers.as_array().expect("array");
        assert_eq!(list.len(), 6);
        let first = list[0]["provider"].as_str().expect("id").to_owned();
        assert_eq!(
            refresh_provider_status(first.clone()).expect("found")["provider"],
            first
        );
        assert_eq!(
            refresh_provider_status(s("nope")).unwrap_err().kind,
            IpcErrorKind::NotFound
        );
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
