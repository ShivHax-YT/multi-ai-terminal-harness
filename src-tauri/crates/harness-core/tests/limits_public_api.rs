//! Rule 1 through the public API only, driven by the simulated clock (enabled for tests by the `sim` dev-dependency).

use chrono::{TimeZone, Utc};
use harness_core::clock::SimClock;
use harness_core::limits::{CeilingKind, Presence, ProviderId, ProviderLimits, UserLimits};
use harness_core::provider::ProviderId as CrateProviderId;
use std::sync::Arc;
use std::time::Duration;

fn setup() -> (SimClock, ProviderLimits) {
    // 08:00 UTC.
    let clock = SimClock::new(Utc.with_ymd_and_hms(2026, 10, 29, 8, 0, 0).unwrap());
    let limits = ProviderLimits::new(Arc::new(clock.clone()));
    limits.set_presence(Presence::default());
    (clock, limits)
}

/// One minute of simulated time with the app's presence heartbeat.
fn minute(clock: &SimClock, limits: &ProviderLimits) {
    clock.advance(Duration::from_secs(60));
    limits.set_presence(Presence::default());
}

#[test]
fn a_present_user_day_stops_at_the_run_ceiling() {
    let (clock, limits) = setup();
    let _run = limits.run_started(ProviderId::Claude).unwrap();

    let mut admitted = 0;
    let mut stopped_at = None;
    // 08:00 UTC up to the next UTC midnight, when the daily counter rolls over.
    for m in 0..(16 * 60) {
        // One prompt every 3 minutes keeps well under 30 per hour.
        if m % 3 == 0 {
            match limits.admit_prompt(ProviderId::Claude, "task") {
                Ok(()) => admitted += 1,
                Err(r) => {
                    assert_eq!(r.kind, CeilingKind::RunMinutesPerDay);
                    stopped_at.get_or_insert(m);
                }
            }
        }
        if m == 480 {
            assert!(limits.must_pause(ProviderId::Claude));
        }
        minute(&clock, &limits);
    }
    // 480 minutes after 08:00 is 16:00. From then until midnight every prompt is refused, with the run still open.
    assert_eq!(stopped_at, Some(480));
    assert_eq!(admitted, 160);
}

#[test]
fn going_idle_stops_work_and_returning_resumes_it() {
    let (clock, limits) = setup();
    limits.admit_prompt(ProviderId::Codex, "task").unwrap();
    limits.set_presence(Presence {
        idle_minutes: 30,
        app_in_background: false,
    });
    minute(&clock, &limits);
    limits.set_presence(Presence {
        idle_minutes: 31,
        app_in_background: false,
    });
    let refused = limits.admit_prompt(ProviderId::Codex, "task").unwrap_err();
    assert_eq!((refused.rule, refused.kind), (1, CeilingKind::UserIdle));
    limits.set_presence(Presence::default());
    limits.admit_prompt(ProviderId::Codex, "task").unwrap();
}

#[test]
fn no_public_way_to_exceed_a_ceiling() {
    let clock = SimClock::new(Utc.with_ymd_and_hms(2026, 10, 29, 8, 0, 0).unwrap());
    let limits = ProviderLimits::with_user_limits(
        Arc::new(clock),
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

#[test]
fn the_user_changing_the_system_date_does_not_open_the_budget() {
    let (clock, limits) = setup();
    for _ in 0..30 {
        limits.admit_prompt(ProviderId::Claude, "task").unwrap();
    }
    let run = limits.run_started(ProviderId::Claude).unwrap();
    for _ in 0..(8 * 60) {
        minute(&clock, &limits);
    }
    drop(run);
    assert!(limits.admit_prompt(ProviderId::Claude, "task").is_err());
    clock.jump_wall_forward(Duration::from_secs(48 * 3600));
    limits.set_presence(Presence::default());
    let refused = limits.admit_prompt(ProviderId::Claude, "task").unwrap_err();
    assert_eq!(refused.kind, CeilingKind::RunMinutesPerDay);
    assert!(limits.run_started(ProviderId::Claude).is_err());
}

#[test]
fn provider_id_is_the_crate_wide_type() {
    let id: CrateProviderId = ProviderId::Kimi;
    assert_eq!(id.as_str(), "kimi");
}
