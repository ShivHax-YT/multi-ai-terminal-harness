//! Rule 1 proofs: every ceiling is refused at its limit, and no path loosens one.

use super::*;
use crate::clock::{Clock, SimClock};
use chrono::{DateTime, TimeZone, Utc};
use std::sync::Arc;
use std::time::Duration;

const MIN: u64 = 60;

fn noon() -> DateTime<Utc> {
    Utc.with_ymd_and_hms(2026, 10, 29, 12, 0, 0).unwrap()
}

fn setup_at(start: DateTime<Utc>) -> (SimClock, ProviderLimits) {
    let clock = SimClock::new(start);
    let limits = ProviderLimits::new(Arc::new(clock.clone()));
    (clock, limits)
}

fn setup() -> (SimClock, ProviderLimits) {
    setup_at(noon())
}

fn mins(clock: &SimClock, n: u64) {
    clock.advance(Duration::from_secs(n * MIN));
}

fn refusal<T: std::fmt::Debug>(r: Result<T, Refusal>) -> Refusal {
    r.expect_err("expected a refusal")
}

// ---- sessions ---------------------------------------------------------------------------------------------------

#[test]
fn third_session_refused() {
    let (_clock, limits) = setup();
    let a = limits.acquire_session(ProviderId::Claude).unwrap();
    let b = limits.acquire_session(ProviderId::Claude).unwrap();
    let refused = refusal(limits.acquire_session(ProviderId::Claude));
    assert_eq!(refused.rule, 1);
    assert_eq!(refused.kind, CeilingKind::ConcurrentSessions);
    assert!(refused.retry_at.is_none());
    drop((a, b));
}

#[test]
fn dropping_a_permit_frees_the_slot() {
    let (_clock, limits) = setup();
    let a = limits.acquire_session(ProviderId::Codex).unwrap();
    let _b = limits.acquire_session(ProviderId::Codex).unwrap();
    assert!(limits.acquire_session(ProviderId::Codex).is_err());
    drop(a);
    let _c = limits.acquire_session(ProviderId::Codex).unwrap();
    assert!(limits.acquire_session(ProviderId::Codex).is_err());
}

#[test]
fn session_slots_are_per_provider() {
    let (_clock, limits) = setup();
    let _a = limits.acquire_session(ProviderId::Claude).unwrap();
    let _b = limits.acquire_session(ProviderId::Claude).unwrap();
    let c = limits.acquire_session(ProviderId::Codex).unwrap();
    assert_eq!(c.provider(), ProviderId::Codex);
}

#[test]
fn permit_outlives_the_limits_handle_it_came_from() {
    let (_clock, limits) = setup();
    let permit = limits.acquire_session(ProviderId::Claude).unwrap();
    let other = limits.clone();
    drop(limits);
    assert_eq!(other.meters(ProviderId::Claude).sessions.current, 1);
    drop(permit);
    assert_eq!(other.meters(ProviderId::Claude).sessions.current, 0);
}

// ---- prompts per hour -------------------------------------------------------------------------------------------

#[test]
fn thirty_first_prompt_refused_within_hour() {
    let (clock, limits) = setup();
    let first = clock.now();
    for i in 0..30 {
        limits
            .admit_prompt(ProviderId::Claude, "t1")
            .unwrap_or_else(|e| panic!("prompt {i} refused: {e}"));
        mins(&clock, 1);
    }
    // 30 minutes in, the window holds 30.
    let refused = refusal(limits.admit_prompt(ProviderId::Claude, "t1"));
    assert_eq!(refused.rule, 1);
    assert_eq!(refused.kind, CeilingKind::PromptsPerHour);
    assert_eq!(
        refused.retry_at,
        Some(first + chrono::Duration::minutes(60))
    );
}

#[test]
fn refused_prompt_is_not_recorded() {
    let (clock, limits) = setup();
    for _ in 0..30 {
        limits.admit_prompt(ProviderId::Claude, "t1").unwrap();
    }
    for _ in 0..10 {
        assert!(limits.admit_prompt(ProviderId::Claude, "t1").is_err());
    }
    assert_eq!(
        limits.meters(ProviderId::Claude).prompts_last_hour.current,
        30
    );
    // Once the original 30 age out, a full 30 are admitted again, so the refusals left nothing behind.
    mins(&clock, 60);
    for _ in 0..30 {
        limits.admit_prompt(ProviderId::Claude, "t1").unwrap();
    }
    assert!(limits.admit_prompt(ProviderId::Claude, "t1").is_err());
}

#[test]
fn prompt_window_slides() {
    let (clock, limits) = setup();
    limits.admit_prompt(ProviderId::Claude, "t1").unwrap();
    mins(&clock, 30);
    for _ in 0..29 {
        limits.admit_prompt(ProviderId::Claude, "t1").unwrap();
    }
    assert!(limits.admit_prompt(ProviderId::Claude, "t1").is_err());
    // 59m59s after the first prompt it still counts; at exactly 60 minutes it has left the window.
    mins(&clock, 29);
    clock.advance(Duration::from_secs(59));
    assert!(limits.admit_prompt(ProviderId::Claude, "t1").is_err());
    clock.advance(Duration::from_secs(1));
    limits.admit_prompt(ProviderId::Claude, "t1").unwrap();
    assert!(limits.admit_prompt(ProviderId::Claude, "t1").is_err());
}

#[test]
fn prompt_windows_are_per_provider() {
    let (_clock, limits) = setup();
    for _ in 0..30 {
        limits.admit_prompt(ProviderId::Claude, "t1").unwrap();
    }
    assert!(limits.admit_prompt(ProviderId::Claude, "t1").is_err());
    limits.admit_prompt(ProviderId::Codex, "t2").unwrap();
}

// ---- turns per task ---------------------------------------------------------------------------------------------

#[test]
fn forty_first_turn_refused() {
    let (_clock, limits) = setup();
    for n in 1..=40 {
        assert_eq!(limits.record_turn("task-a").unwrap(), n);
    }
    let refused = refusal(limits.record_turn("task-a"));
    assert_eq!(refused.rule, 1);
    assert_eq!(refused.kind, CeilingKind::TurnsPerTask);
    assert!(refused.retry_at.is_none());
    assert_eq!(
        limits.task_turns("task-a").current,
        40,
        "refusal not counted"
    );
}

#[test]
fn turns_are_counted_per_task_id() {
    let (_clock, limits) = setup();
    for _ in 0..40 {
        limits.record_turn("task-a").unwrap();
    }
    assert!(limits.record_turn("task-a").is_err());
    assert_eq!(limits.record_turn("task-b").unwrap(), 1);
}

#[test]
fn turns_survive_sessions_and_permits() {
    let (_clock, limits) = setup();
    {
        let _permit = limits.acquire_session(ProviderId::Claude).unwrap();
        for _ in 0..40 {
            limits.record_turn("task-a").unwrap();
        }
    }
    let _new_session = limits.acquire_session(ProviderId::Claude).unwrap();
    assert!(limits.record_turn("task-a").is_err());
}

// ---- run minutes per day ----------------------------------------------------------------------------------------

#[test]
fn run_minutes_capped_at_480() {
    let (clock, limits) = setup();
    limits.run_started(ProviderId::Claude).unwrap();
    mins(&clock, 479);
    limits.admit_prompt(ProviderId::Claude, "t1").unwrap();
    assert_eq!(
        limits.meters(ProviderId::Claude).run_minutes_today.current,
        479
    );
    mins(&clock, 1);
    let refused = refusal(limits.admit_prompt(ProviderId::Claude, "t1"));
    assert_eq!(refused.rule, 1);
    assert_eq!(refused.kind, CeilingKind::RunMinutesPerDay);
    let midnight = Utc.with_ymd_and_hms(2026, 10, 30, 0, 0, 0).unwrap();
    assert_eq!(refused.retry_at, Some(midnight));

    limits.run_stopped(ProviderId::Claude);
    let again = refusal(limits.run_started(ProviderId::Claude));
    assert_eq!(again.kind, CeilingKind::RunMinutesPerDay);
    // The cap is per provider.
    limits.run_started(ProviderId::Codex).unwrap();
}

#[test]
fn run_minutes_accumulate_across_runs() {
    let (clock, limits) = setup();
    for _ in 0..4 {
        limits.run_started(ProviderId::Codex).unwrap();
        mins(&clock, 100);
        limits.run_stopped(ProviderId::Codex);
        mins(&clock, 10); // idle time between runs does not count
    }
    assert_eq!(
        limits.meters(ProviderId::Codex).run_minutes_today.current,
        400
    );
    limits.run_started(ProviderId::Codex).unwrap();
    mins(&clock, 80);
    assert!(limits.admit_prompt(ProviderId::Codex, "t1").is_err());
}

#[test]
fn run_counter_resets_at_utc_midnight_only() {
    let (clock, limits) = setup_at(Utc.with_ymd_and_hms(2026, 10, 29, 14, 0, 0).unwrap());
    limits.run_started(ProviderId::Claude).unwrap();
    mins(&clock, 480);
    limits.run_stopped(ProviderId::Claude);
    assert!(limits.run_started(ProviderId::Claude).is_err());
    mins(&clock, 60 + 59); // 23:59 UTC
    assert!(limits.run_started(ProviderId::Claude).is_err());
    mins(&clock, 1); // 00:00 UTC
    limits.run_started(ProviderId::Claude).unwrap();
    assert_eq!(
        limits.meters(ProviderId::Claude).run_minutes_today.current,
        0
    );
}

#[test]
fn midnight_reset_does_not_reset_other_counters() {
    let (clock, limits) = setup_at(Utc.with_ymd_and_hms(2026, 10, 29, 23, 30, 0).unwrap());
    for _ in 0..40 {
        limits.record_turn("task-a").unwrap();
    }
    let _a = limits.acquire_session(ProviderId::Claude).unwrap();
    let _b = limits.acquire_session(ProviderId::Claude).unwrap();
    mins(&clock, 31); // past midnight, window still holds nothing, turns and sessions must stay
    assert!(limits.record_turn("task-a").is_err());
    assert!(limits.acquire_session(ProviderId::Claude).is_err());
}

#[test]
fn a_run_spanning_midnight_only_counts_the_new_day() {
    let (clock, limits) = setup_at(Utc.with_ymd_and_hms(2026, 10, 29, 23, 0, 0).unwrap());
    limits.run_started(ProviderId::Claude).unwrap();
    mins(&clock, 90); // 00:30 next day
    assert_eq!(
        limits.meters(ProviderId::Claude).run_minutes_today.current,
        30
    );
    limits.run_stopped(ProviderId::Claude);
    assert_eq!(
        limits.meters(ProviderId::Claude).run_minutes_today.current,
        30
    );
}

#[test]
fn overlapping_runs_count_wall_clock_once() {
    let (clock, limits) = setup();
    limits.run_started(ProviderId::Claude).unwrap();
    limits.run_started(ProviderId::Claude).unwrap();
    mins(&clock, 10);
    limits.run_stopped(ProviderId::Claude);
    mins(&clock, 10);
    limits.run_stopped(ProviderId::Claude);
    assert_eq!(
        limits.meters(ProviderId::Claude).run_minutes_today.current,
        20
    );
    limits.run_stopped(ProviderId::Claude); // extra stop is harmless
    mins(&clock, 10);
    assert_eq!(
        limits.meters(ProviderId::Claude).run_minutes_today.current,
        20
    );
}

// ---- presence ---------------------------------------------------------------------------------------------------

#[test]
fn idle_30_blocks_prompts() {
    let (_clock, limits) = setup();
    limits.set_presence(Presence {
        idle_minutes: 29,
        app_in_background: false,
    });
    limits.admit_prompt(ProviderId::Claude, "t1").unwrap();
    limits.set_presence(Presence {
        idle_minutes: 30,
        app_in_background: false,
    });
    let refused = refusal(limits.admit_prompt(ProviderId::Claude, "t1"));
    assert_eq!(refused.rule, 1);
    assert_eq!(refused.kind, CeilingKind::UserIdle);
    assert!(refused.message.contains("30"));
    let refused = refusal(limits.run_started(ProviderId::Claude));
    assert_eq!(refused.kind, CeilingKind::UserIdle);
    // The user comes back.
    limits.set_presence(Presence::default());
    limits.admit_prompt(ProviderId::Claude, "t1").unwrap();
    limits.run_started(ProviderId::Claude).unwrap();
}

#[test]
fn background_app_blocks_prompts_and_runs() {
    let (_clock, limits) = setup();
    limits.set_presence(Presence {
        idle_minutes: 0,
        app_in_background: true,
    });
    let refused = refusal(limits.admit_prompt(ProviderId::Codex, "t1"));
    assert_eq!(refused.kind, CeilingKind::AppBackground);
    let refused = refusal(limits.run_started(ProviderId::Codex));
    assert_eq!(refused.kind, CeilingKind::AppBackground);
}

#[test]
fn presence_refusal_records_nothing() {
    let (_clock, limits) = setup();
    limits.set_presence(Presence {
        idle_minutes: 45,
        app_in_background: false,
    });
    for _ in 0..50 {
        assert!(limits.admit_prompt(ProviderId::Claude, "t1").is_err());
    }
    limits.set_presence(Presence::default());
    assert_eq!(
        limits.meters(ProviderId::Claude).prompts_last_hour.current,
        0
    );
}

// ---- user limits never loosen -----------------------------------------------------------------------------------

#[test]
fn user_limit_cannot_loosen() {
    let loose = UserLimits {
        concurrent_sessions: Some(99),
        prompts_per_hour: Some(99),
        turns_per_task: Some(99),
        run_minutes_per_day: Some(99_999),
        idle_pause_minutes: Some(99),
    };
    assert_eq!(
        EffectiveLimits::with_user(&loose),
        EffectiveLimits::ceilings()
    );

    let clock = SimClock::new(noon());
    let limits = ProviderLimits::with_user_limits(Arc::new(clock.clone()), &loose);
    let m = limits.meters(ProviderId::Claude);
    assert_eq!(m.sessions.limit, 2);
    assert_eq!(m.prompts_last_hour.limit, 30);
    assert_eq!(m.run_minutes_today.limit, 480);
    assert_eq!(limits.task_turns("t").limit, 40);
    for _ in 0..30 {
        limits.admit_prompt(ProviderId::Claude, "t1").unwrap();
    }
    assert!(limits.admit_prompt(ProviderId::Claude, "t1").is_err());
    limits.set_presence(Presence {
        idle_minutes: 30,
        app_in_background: false,
    });
    assert!(limits.admit_prompt(ProviderId::Codex, "t1").is_err());
}

#[test]
fn stricter_user_limits_apply() {
    let strict = UserLimits {
        concurrent_sessions: Some(1),
        prompts_per_hour: Some(3),
        turns_per_task: Some(5),
        run_minutes_per_day: Some(60),
        idle_pause_minutes: Some(10),
    };
    let clock = SimClock::new(noon());
    let limits = ProviderLimits::with_user_limits(Arc::new(clock.clone()), &strict);
    let _a = limits.acquire_session(ProviderId::Claude).unwrap();
    let refused = refusal(limits.acquire_session(ProviderId::Claude));
    assert_eq!(refused.kind, CeilingKind::ConcurrentSessions);
    for _ in 0..3 {
        limits.admit_prompt(ProviderId::Claude, "t1").unwrap();
    }
    assert!(limits.admit_prompt(ProviderId::Claude, "t1").is_err());
    for _ in 0..5 {
        limits.record_turn("t1").unwrap();
    }
    assert!(limits.record_turn("t1").is_err());
    limits.set_presence(Presence {
        idle_minutes: 10,
        app_in_background: false,
    });
    assert_eq!(
        refusal(limits.run_started(ProviderId::Codex)).kind,
        CeilingKind::UserIdle
    );
    assert_eq!(limits.meters(ProviderId::Codex).run_minutes_today.limit, 60);
}

#[test]
fn zero_user_value_is_raised_to_the_rule_bound() {
    let zero = UserLimits {
        concurrent_sessions: Some(0),
        prompts_per_hour: Some(0),
        turns_per_task: Some(0),
        run_minutes_per_day: Some(0),
        idle_pause_minutes: Some(0),
    };
    let e = EffectiveLimits::with_user(&zero);
    assert_eq!(e.concurrent_sessions(), 1);
    assert_eq!(e.prompts_per_hour(), 1);
    assert_eq!(e.turns_per_task(), 1);
    assert_eq!(e.run_minutes_per_day(), 30);
    assert_eq!(e.idle_pause_minutes(), 5);
}

#[test]
fn ceilings_come_from_the_compliance_constants() {
    use crate::compliance::ceilings as c;
    let e = EffectiveLimits::ceilings();
    assert_eq!(e.concurrent_sessions(), c::MAX_CONCURRENT_SESSIONS);
    assert_eq!(e.prompts_per_hour(), c::MAX_PROMPTS_PER_HOUR);
    assert_eq!(e.turns_per_task(), c::MAX_TURNS_PER_TASK);
    assert_eq!(e.run_minutes_per_day(), c::MAX_RUN_MINUTES_PER_DAY);
    assert_eq!(e.idle_pause_minutes(), c::IDLE_PAUSE_MINUTES);
    for key in [
        "concurrent_sessions",
        "prompts_per_hour",
        "turns_per_task",
        "run_minutes_per_day",
        "idle_pause_minutes",
    ] {
        assert!(c::LIMIT_RULES.iter().any(|r| r.key == key), "{key}");
    }
}

// ---- snapshot / load --------------------------------------------------------------------------------------------

#[test]
fn snapshot_round_trips_through_json_and_load() {
    let (clock, limits) = setup();
    for _ in 0..7 {
        limits.admit_prompt(ProviderId::Claude, "t1").unwrap();
    }
    for _ in 0..12 {
        limits.record_turn("t1").unwrap();
    }
    limits.run_started(ProviderId::Codex).unwrap();
    mins(&clock, 45);
    limits.run_stopped(ProviderId::Codex);

    let json = serde_json::to_string(&limits.snapshot()).unwrap();
    let restored_snapshot: LimitsSnapshot = serde_json::from_str(&json).unwrap();

    // A fresh instance (an app restart) loads it and sees the same counters.
    let fresh = ProviderLimits::new(Arc::new(clock.clone()));
    fresh.load(&restored_snapshot);
    assert_eq!(
        fresh.meters(ProviderId::Claude).prompts_last_hour.current,
        7
    );
    assert_eq!(fresh.task_turns("t1").current, 12);
    assert_eq!(
        fresh.meters(ProviderId::Codex).run_minutes_today.current,
        45
    );
    assert_eq!(fresh.snapshot(), limits.snapshot());
}

#[test]
fn loaded_prompts_still_age_out_and_count_against_the_cap() {
    let (clock, limits) = setup();
    for _ in 0..30 {
        limits.admit_prompt(ProviderId::Claude, "t1").unwrap();
    }
    let snap = limits.snapshot();
    let fresh = ProviderLimits::new(Arc::new(clock.clone()));
    fresh.load(&snap);
    assert!(fresh.admit_prompt(ProviderId::Claude, "t1").is_err());
    mins(&clock, 60);
    fresh.admit_prompt(ProviderId::Claude, "t1").unwrap();
}

#[test]
fn load_never_lowers_a_counter() {
    let (_clock, limits) = setup();
    for _ in 0..10 {
        limits.record_turn("t1").unwrap();
    }
    for _ in 0..5 {
        limits.admit_prompt(ProviderId::Claude, "t1").unwrap();
    }
    let stale = LimitsSnapshot::default();
    limits.load(&stale);
    assert_eq!(limits.task_turns("t1").current, 10);
    assert_eq!(
        limits.meters(ProviderId::Claude).prompts_last_hour.current,
        5
    );

    // Loading the same snapshot twice does not double count.
    let snap = limits.snapshot();
    limits.load(&snap);
    limits.load(&snap);
    assert_eq!(
        limits.meters(ProviderId::Claude).prompts_last_hour.current,
        5
    );
    assert_eq!(limits.task_turns("t1").current, 10);
}

#[test]
fn load_ignores_run_minutes_from_a_past_day() {
    let (clock, limits) = setup();
    let mut snap = LimitsSnapshot::default();
    snap.run.insert(
        ProviderId::Claude,
        RunDay {
            day: clock.now().date_naive() - chrono::Days::new(1),
            seconds: 480 * 60,
        },
    );
    limits.load(&snap);
    limits.run_started(ProviderId::Claude).unwrap();
}

#[test]
fn load_applies_run_minutes_for_today() {
    let (clock, limits) = setup();
    let mut snap = LimitsSnapshot::default();
    snap.run.insert(
        ProviderId::Claude,
        RunDay {
            day: clock.now().date_naive(),
            seconds: 480 * 60,
        },
    );
    limits.load(&snap);
    assert_eq!(
        refusal(limits.run_started(ProviderId::Claude)).kind,
        CeilingKind::RunMinutesPerDay
    );
}

// ---- provider ids and refusals ----------------------------------------------------------------------------------

#[test]
fn provider_ids_match_the_contract() {
    let ids: Vec<&str> = ProviderId::ALL.iter().map(|p| p.as_str()).collect();
    assert_eq!(ids, ["claude", "codex", "grok", "kimi", "gemini", "glm"]);
    for p in ProviderId::ALL {
        assert_eq!(p.as_str().parse::<ProviderId>().unwrap(), p);
        assert_eq!(
            serde_json::to_string(&p).unwrap(),
            format!("\"{}\"", p.as_str())
        );
    }
    assert!("openai".parse::<ProviderId>().is_err());
}

#[test]
fn refusal_serializes_for_the_ipc_mapping() {
    let (_clock, limits) = setup();
    let _a = limits.acquire_session(ProviderId::Claude).unwrap();
    let _b = limits.acquire_session(ProviderId::Claude).unwrap();
    let refused = refusal(limits.acquire_session(ProviderId::Claude));
    let v = serde_json::to_value(&refused).unwrap();
    assert_eq!(v["rule"], 1);
    assert_eq!(v["kind"], "concurrent_sessions");
    assert_eq!(refused.to_string(), refused.message);
}

// ---- structural guards ------------------------------------------------------------------------------------------

fn module_sources(dir: &str) -> Vec<(String, String)> {
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("src")
        .join(dir);
    let mut out = Vec::new();
    for entry in std::fs::read_dir(&root).unwrap() {
        let path = entry.unwrap().path();
        if path.extension().is_some_and(|e| e == "rs") {
            let name = path.file_name().unwrap().to_string_lossy().into_owned();
            out.push((name, std::fs::read_to_string(&path).unwrap().to_lowercase()));
        }
    }
    assert!(!out.is_empty());
    out
}

#[test]
fn no_timer_api() {
    // Needles are assembled so this file does not contain them itself.
    let needles = [
        ["inter", "val"].concat(),
        ["cr", "on"].concat(),
        ["sched", "ule"].concat(),
        ["tokio::", "time"].concat(),
        ["sle", "ep"].concat(),
    ];
    for (name, source) in module_sources("limits") {
        for needle in &needles {
            assert!(
                !source.contains(needle.as_str()),
                "limits/{name} mentions `{needle}`: subscription limits have no timer API (rule 1)"
            );
        }
    }
}

#[test]
fn no_direct_os_clock_reads_outside_the_system_clock() {
    let needles = [
        ["Instant", "::now"].concat().to_lowercase(),
        ["SystemTime", "::now"].concat().to_lowercase(),
        ["Utc", "::now"].concat().to_lowercase(),
        ["Local", "::now"].concat().to_lowercase(),
    ];
    for dir in ["limits", "events", "clock"] {
        for (name, source) in module_sources(dir) {
            if dir == "clock" && (name == "system.rs" || name == "mod.rs") {
                continue; // the real clock, and its test that compares against it
            }
            for needle in &needles {
                assert!(
                    !source.contains(needle.as_str()),
                    "{dir}/{name} reads the OS clock directly (`{needle}`)"
                );
            }
        }
    }
}

#[test]
fn limits_module_has_no_environment_or_file_access() {
    let needles = [
        ["std::", "env"].concat(),
        ["std::", "fs"].concat(),
        ["File", "::open"].concat().to_lowercase(),
    ];
    for (name, source) in module_sources("limits") {
        if name == "tests.rs" {
            continue; // the guards read source files
        }
        for needle in &needles {
            assert!(
                !source.contains(needle.as_str()),
                "limits/{name} uses `{needle}`: ceilings are not configurable at runtime"
            );
        }
    }
}
