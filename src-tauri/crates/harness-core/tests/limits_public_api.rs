//! Rule 1 through the public API only, with a clock implemented outside the crate.

use chrono::{DateTime, Duration as Delta, TimeZone, Utc};
use harness_core::clock::Clock;
use harness_core::limits::{CeilingKind, Presence, ProviderId, ProviderLimits, UserLimits};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// A clock the test owns, to show any `Clock` can drive the limits.
struct StepClock {
    now: Mutex<DateTime<Utc>>,
}

impl StepClock {
    fn new() -> Arc<Self> {
        Arc::new(Self {
            now: Mutex::new(Utc.with_ymd_and_hms(2026, 10, 29, 8, 0, 0).unwrap()),
        })
    }
    fn step(&self, minutes: i64) {
        *self.now.lock().unwrap() += Delta::minutes(minutes);
    }
}

impl Clock for StepClock {
    fn now(&self) -> DateTime<Utc> {
        *self.now.lock().unwrap()
    }
    fn monotonic(&self) -> Duration {
        Duration::ZERO
    }
}

#[test]
fn a_present_user_day_stops_at_the_run_ceiling() {
    let clock = StepClock::new();
    let limits = ProviderLimits::new(clock.clone());
    limits.run_started(ProviderId::Claude).unwrap();

    let mut admitted = 0;
    let mut stopped_at = None;
    // 08:00 UTC up to the next UTC midnight, when the daily counter rolls over.
    for minute in 0..(16 * 60) {
        // One prompt every 3 minutes keeps well under 30 per hour.
        if minute % 3 == 0 {
            match limits.admit_prompt(ProviderId::Claude, "task") {
                Ok(()) => admitted += 1,
                Err(r) => {
                    assert_eq!(r.kind, CeilingKind::RunMinutesPerDay);
                    stopped_at.get_or_insert(minute);
                }
            }
        }
        clock.step(1);
    }
    // 480 minutes after 08:00 is 16:00. From then until midnight every prompt is refused, even with the run still active.
    assert_eq!(stopped_at, Some(480));
    assert_eq!(admitted, 160);
}

#[test]
fn going_idle_stops_work_and_returning_resumes_it() {
    let clock = StepClock::new();
    let limits = ProviderLimits::new(clock.clone());
    limits.admit_prompt(ProviderId::Codex, "task").unwrap();
    limits.set_presence(Presence {
        idle_minutes: 30,
        app_in_background: false,
    });
    clock.step(1);
    let refused = limits.admit_prompt(ProviderId::Codex, "task").unwrap_err();
    assert_eq!((refused.rule, refused.kind), (1, CeilingKind::UserIdle));
    limits.set_presence(Presence::default());
    limits.admit_prompt(ProviderId::Codex, "task").unwrap();
}

#[test]
fn no_public_way_to_exceed_a_ceiling() {
    let clock = StepClock::new();
    let limits = ProviderLimits::with_user_limits(
        clock,
        &UserLimits {
            concurrent_sessions: Some(u32::MAX),
            prompts_per_hour: Some(u32::MAX),
            turns_per_task: Some(u32::MAX),
            run_minutes_per_day: Some(u32::MAX),
            idle_pause_minutes: Some(u32::MAX),
        },
    );
    let e = limits.effective_limits();
    assert_eq!(e.concurrent_sessions(), 2);
    assert_eq!(e.prompts_per_hour(), 30);
    assert_eq!(e.turns_per_task(), 40);
    assert_eq!(e.run_minutes_per_day(), 480);
    assert_eq!(e.idle_pause_minutes(), 30);
}
