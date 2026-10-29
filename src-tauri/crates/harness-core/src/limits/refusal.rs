//! The refusal returned when a ceiling or presence rule blocks an action.

use chrono::{DateTime, Utc};
use serde::Serialize;

/// Which ceiling or presence rule refused.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum CeilingKind {
    ConcurrentSessions,
    PromptsPerHour,
    TurnsPerTask,
    RunMinutesPerDay,
    UserIdle,
    AppBackground,
}

/// A hard-rule refusal. The app maps it to `IpcError { kind: "rule_blocked", rule, message, retry_at }`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, thiserror::Error)]
#[error("{message}")]
pub struct Refusal {
    /// The hard rule that refused (always 1 in this module).
    pub rule: u8,
    pub kind: CeilingKind,
    pub message: String,
    /// When the same action could next be admitted, if time alone would allow it.
    pub retry_at: Option<DateTime<Utc>>,
}

impl Refusal {
    /// A rule 1 refusal.
    pub(crate) fn rule1(
        kind: CeilingKind,
        message: impl Into<String>,
        retry_at: Option<DateTime<Utc>>,
    ) -> Self {
        Self {
            rule: 1,
            kind,
            message: message.into(),
            retry_at,
        }
    }
}
