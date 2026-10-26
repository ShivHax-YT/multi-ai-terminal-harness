//! Compiled-in ceilings (hard rules 1, 10 and 11).
//!
//! These are compile-time constants and the only place the numbers live. No config key, flag or environment variable
//! may raise them; users may only choose a stricter value inside [`LIMIT_RULES`]. Ceilings may be lowered in a release,
//! never raised by a user.

/// Concurrent automated sessions per subscription provider (rule 1).
pub const MAX_CONCURRENT_SESSIONS: u32 = 2;
/// Automated prompts per hour per subscription provider (rule 1).
pub const MAX_PROMPTS_PER_HOUR: u32 = 30;
/// Turns per task (rule 1).
pub const MAX_TURNS_PER_TASK: u32 = 40;
/// Automated run time per day per subscription provider, in minutes (rule 1: 8 hours).
pub const MAX_RUN_MINUTES_PER_DAY: u32 = 480;
/// Workers pause after the current task once the user has been idle this long, in minutes (rule 1).
pub const IDLE_PAUSE_MINUTES: u32 = 30;
/// Minimum gap between dispatches to one provider, in seconds (rule 10).
pub const MIN_DISPATCH_GAP_SECS: u32 = 5;
/// First backoff after a rate-limit error, in seconds; doubles on each further error (rule 10).
pub const BACKOFF_BASE_SECS: u32 = 60;
/// Consecutive limit errors after which the provider pauses until its reset time or a user resume (rule 10).
pub const PAUSE_AFTER_LIMIT_ERRORS: u32 = 3;
/// Largest daily spend cap a user may set for an API-key provider, in USD (rule 11: there is no unlimited value).
/// Placeholder for the human to set before release.
pub const SPEND_CAP_MAX_DAILY_USD: u32 = 500;
/// Largest weekly spend cap a user may set for an API-key provider, in USD (rule 11). Placeholder, as above.
pub const SPEND_CAP_MAX_WEEKLY_USD: u32 = 2000;

/// Which direction is stricter for a limit.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Stricter {
    /// A smaller value is stricter: the user value lies in `[bound, ceiling]`.
    Lower,
    /// A larger value is stricter: the user value lies in `[ceiling, bound]`.
    Higher,
}

/// Unit of a limit value.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Unit {
    Count,
    PerHour,
    Minutes,
    Seconds,
}

/// One user-adjustable limit: the ceiling, which direction is stricter, and the far end of the allowed range.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LimitRule {
    pub key: &'static str,
    pub ceiling: u32,
    pub stricter: Stricter,
    pub bound: u32,
    pub unit: Unit,
    /// The hard rule a looser value would break.
    pub rule: u8,
}

impl LimitRule {
    /// True when `value` is inside the allowed range (never looser than the ceiling).
    pub const fn allows(&self, value: u32) -> bool {
        match self.stricter {
            Stricter::Lower => value >= self.bound && value <= self.ceiling,
            Stricter::Higher => value >= self.ceiling && value <= self.bound,
        }
    }

    /// True when `value` is looser than the ceiling (a compliance refusal, not just a range error).
    pub const fn is_looser(&self, value: u32) -> bool {
        match self.stricter {
            Stricter::Lower => value > self.ceiling,
            Stricter::Higher => value < self.ceiling,
        }
    }
}

/// Every user-adjustable limit, in the IPC contract's `LimitKey` order.
pub const LIMIT_RULES: [LimitRule; 8] = [
    LimitRule {
        key: "concurrent_sessions",
        ceiling: MAX_CONCURRENT_SESSIONS,
        stricter: Stricter::Lower,
        bound: 1,
        unit: Unit::Count,
        rule: 1,
    },
    LimitRule {
        key: "prompts_per_hour",
        ceiling: MAX_PROMPTS_PER_HOUR,
        stricter: Stricter::Lower,
        bound: 1,
        unit: Unit::PerHour,
        rule: 1,
    },
    LimitRule {
        key: "turns_per_task",
        ceiling: MAX_TURNS_PER_TASK,
        stricter: Stricter::Lower,
        bound: 1,
        unit: Unit::Count,
        rule: 1,
    },
    LimitRule {
        key: "run_minutes_per_day",
        ceiling: MAX_RUN_MINUTES_PER_DAY,
        stricter: Stricter::Lower,
        bound: 30,
        unit: Unit::Minutes,
        rule: 1,
    },
    LimitRule {
        key: "idle_pause_minutes",
        ceiling: IDLE_PAUSE_MINUTES,
        stricter: Stricter::Lower,
        bound: 5,
        unit: Unit::Minutes,
        rule: 1,
    },
    LimitRule {
        key: "min_dispatch_gap_s",
        ceiling: MIN_DISPATCH_GAP_SECS,
        stricter: Stricter::Higher,
        bound: 600,
        unit: Unit::Seconds,
        rule: 10,
    },
    LimitRule {
        key: "backoff_base_s",
        ceiling: BACKOFF_BASE_SECS,
        stricter: Stricter::Higher,
        bound: 3600,
        unit: Unit::Seconds,
        rule: 10,
    },
    LimitRule {
        key: "pause_after_limit_errors",
        ceiling: PAUSE_AFTER_LIMIT_ERRORS,
        stricter: Stricter::Lower,
        bound: 1,
        unit: Unit::Count,
        rule: 10,
    },
];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ceilings_concurrent_sessions_is_2() {
        assert_eq!(MAX_CONCURRENT_SESSIONS, 2);
    }

    #[test]
    fn ceilings_prompts_per_hour_is_30() {
        assert_eq!(MAX_PROMPTS_PER_HOUR, 30);
    }

    #[test]
    fn ceilings_turns_per_task_is_40() {
        assert_eq!(MAX_TURNS_PER_TASK, 40);
    }

    #[test]
    fn ceilings_run_minutes_per_day_is_480() {
        assert_eq!(MAX_RUN_MINUTES_PER_DAY, 480);
        assert_eq!(MAX_RUN_MINUTES_PER_DAY, 8 * 60);
    }

    #[test]
    fn ceilings_idle_pause_is_30_minutes() {
        assert_eq!(IDLE_PAUSE_MINUTES, 30);
    }

    #[test]
    fn ceilings_dispatch_gap_is_5_seconds() {
        assert_eq!(MIN_DISPATCH_GAP_SECS, 5);
    }

    #[test]
    fn ceilings_backoff_base_is_60_seconds() {
        assert_eq!(BACKOFF_BASE_SECS, 60);
    }

    #[test]
    fn ceilings_pause_after_3_limit_errors() {
        assert_eq!(PAUSE_AFTER_LIMIT_ERRORS, 3);
    }

    #[test]
    fn ceilings_spend_cap_max_is_finite_and_ordered() {
        assert_eq!(SPEND_CAP_MAX_DAILY_USD, 500);
        assert_eq!(SPEND_CAP_MAX_WEEKLY_USD, 2000);
        const { assert!(SPEND_CAP_MAX_DAILY_USD > 0) };
        const { assert!(SPEND_CAP_MAX_WEEKLY_USD >= SPEND_CAP_MAX_DAILY_USD) };
    }

    #[test]
    fn ceilings_limit_rules_use_the_constants() {
        let by_key = |k: &str| LIMIT_RULES.iter().find(|r| r.key == k).copied().unwrap();
        assert_eq!(
            by_key("concurrent_sessions").ceiling,
            MAX_CONCURRENT_SESSIONS
        );
        assert_eq!(by_key("prompts_per_hour").ceiling, MAX_PROMPTS_PER_HOUR);
        assert_eq!(by_key("turns_per_task").ceiling, MAX_TURNS_PER_TASK);
        assert_eq!(
            by_key("run_minutes_per_day").ceiling,
            MAX_RUN_MINUTES_PER_DAY
        );
        assert_eq!(by_key("idle_pause_minutes").ceiling, IDLE_PAUSE_MINUTES);
        assert_eq!(by_key("min_dispatch_gap_s").ceiling, MIN_DISPATCH_GAP_SECS);
        assert_eq!(by_key("backoff_base_s").ceiling, BACKOFF_BASE_SECS);
        assert_eq!(
            by_key("pause_after_limit_errors").ceiling,
            PAUSE_AFTER_LIMIT_ERRORS
        );
    }

    #[test]
    fn ceilings_limit_rule_bounds() {
        let got: Vec<(&str, Stricter, u32, u8)> = LIMIT_RULES
            .iter()
            .map(|r| (r.key, r.stricter, r.bound, r.rule))
            .collect();
        assert_eq!(
            got,
            vec![
                ("concurrent_sessions", Stricter::Lower, 1, 1),
                ("prompts_per_hour", Stricter::Lower, 1, 1),
                ("turns_per_task", Stricter::Lower, 1, 1),
                ("run_minutes_per_day", Stricter::Lower, 30, 1),
                ("idle_pause_minutes", Stricter::Lower, 5, 1),
                ("min_dispatch_gap_s", Stricter::Higher, 600, 10),
                ("backoff_base_s", Stricter::Higher, 3600, 10),
                ("pause_after_limit_errors", Stricter::Lower, 1, 10),
            ]
        );
    }

    #[test]
    fn ceilings_never_allow_a_looser_value() {
        for r in LIMIT_RULES {
            assert!(r.allows(r.ceiling), "{} must allow its ceiling", r.key);
            assert!(r.allows(r.bound), "{} must allow its bound", r.key);
            let looser = match r.stricter {
                Stricter::Lower => r.ceiling + 1,
                Stricter::Higher => r.ceiling - 1,
            };
            assert!(!r.allows(looser), "{} allowed a looser value", r.key);
            assert!(r.is_looser(looser), "{} did not flag a looser value", r.key);
            assert!(!r.is_looser(r.ceiling));
        }
    }
}
