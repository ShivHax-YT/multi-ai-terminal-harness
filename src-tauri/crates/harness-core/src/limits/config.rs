//! The limits in force: the compiled ceilings, optionally made stricter by the user.
//!
//! There is no constructor that takes a ceiling. [`EffectiveLimits::ceilings`] reads the constants in
//! `compliance::ceilings`; [`EffectiveLimits::with_user`] combines each with a user value as `min(user, ceiling)`, so a
//! looser value is clamped back to the ceiling. Nothing reads a config file, flag or environment variable.

use crate::compliance::ceilings::{
    IDLE_PAUSE_MINUTES, LIMIT_RULES, MAX_CONCURRENT_SESSIONS, MAX_PROMPTS_PER_HOUR,
    MAX_RUN_MINUTES_PER_DAY, MAX_TURNS_PER_TASK,
};
use serde::{Deserialize, Serialize};

/// Stricter values a user may choose. `None` keeps the ceiling. A value above the ceiling is clamped down to it, and a
/// value below the rule's lower bound is raised to the bound.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct UserLimits {
    pub concurrent_sessions: Option<u32>,
    pub prompts_per_hour: Option<u32>,
    pub turns_per_task: Option<u32>,
    pub run_minutes_per_day: Option<u32>,
    pub idle_pause_minutes: Option<u32>,
}

/// The limits this module enforces. Fields are private, so a value can only come from the ceilings or from
/// `min(user, ceiling)`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EffectiveLimits {
    concurrent_sessions: u32,
    prompts_per_hour: u32,
    turns_per_task: u32,
    run_minutes_per_day: u32,
    idle_pause_minutes: u32,
}

impl EffectiveLimits {
    /// Exactly the compiled ceilings.
    pub const fn ceilings() -> Self {
        Self {
            concurrent_sessions: MAX_CONCURRENT_SESSIONS,
            prompts_per_hour: MAX_PROMPTS_PER_HOUR,
            turns_per_task: MAX_TURNS_PER_TASK,
            run_minutes_per_day: MAX_RUN_MINUTES_PER_DAY,
            idle_pause_minutes: IDLE_PAUSE_MINUTES,
        }
    }

    /// The ceilings made stricter by `user`; never looser.
    pub fn with_user(user: &UserLimits) -> Self {
        Self {
            concurrent_sessions: combine(
                "concurrent_sessions",
                MAX_CONCURRENT_SESSIONS,
                user.concurrent_sessions,
            ),
            prompts_per_hour: combine(
                "prompts_per_hour",
                MAX_PROMPTS_PER_HOUR,
                user.prompts_per_hour,
            ),
            turns_per_task: combine("turns_per_task", MAX_TURNS_PER_TASK, user.turns_per_task),
            run_minutes_per_day: combine(
                "run_minutes_per_day",
                MAX_RUN_MINUTES_PER_DAY,
                user.run_minutes_per_day,
            ),
            idle_pause_minutes: combine(
                "idle_pause_minutes",
                IDLE_PAUSE_MINUTES,
                user.idle_pause_minutes,
            ),
        }
    }

    pub const fn concurrent_sessions(&self) -> u32 {
        self.concurrent_sessions
    }
    pub const fn prompts_per_hour(&self) -> u32 {
        self.prompts_per_hour
    }
    pub const fn turns_per_task(&self) -> u32 {
        self.turns_per_task
    }
    pub const fn run_minutes_per_day(&self) -> u32 {
        self.run_minutes_per_day
    }
    pub const fn idle_pause_minutes(&self) -> u32 {
        self.idle_pause_minutes
    }
}

impl Default for EffectiveLimits {
    fn default() -> Self {
        Self::ceilings()
    }
}

/// `min(user, ceiling)`, raised to the rule's lower bound so a zero cannot switch a limit into "always refuse".
fn combine(key: &str, ceiling: u32, user: Option<u32>) -> u32 {
    let bound = LIMIT_RULES
        .iter()
        .find(|r| r.key == key)
        .map_or(1, |r| r.bound);
    user.map_or(ceiling, |u| u.min(ceiling).max(bound))
}
