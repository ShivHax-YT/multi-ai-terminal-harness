//! Rule 1 proofs: every ceiling is refused at its limit, and no path loosens one.

use super::*;
use crate::clock::{Clock, SimClock};
use chrono::{DateTime, NaiveDate, TimeZone, Utc};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

fn noon() -> DateTime<Utc> {
    Utc.with_ymd_and_hms(2026, 10, 29, 12, 0, 0).unwrap()
}

fn present() -> Presence {
    Presence::default()
}

/// Limits over a simulated clock, with the app having just reported that the user is present.
fn setup_at(start: DateTime<Utc>) -> (SimClock, ProviderLimits) {
    let clock = SimClock::new(start);
    let limits = ProviderLimits::new(Arc::new(clock.clone()));
    limits.set_presence(present());
    (clock, limits)
}

fn setup() -> (SimClock, ProviderLimits) {
    setup_at(noon())
}

/// Advances real time by `n` minutes while the app keeps reporting a present user every four minutes.
fn mins(clock: &SimClock, limits: &ProviderLimits, n: u64) {
    let mut left = n;
    while left > 0 {
        let step = left.min(4);
        clock.advance(Duration::from_secs(step * 60));
        limits.set_presence(present());
        left -= step;
    }
}

fn refusal<T: std::fmt::Debug>(r: Result<T, Refusal>) -> Refusal {
    r.expect_err("expected a refusal")
}

/// One dispatch-style admission: opens a run and takes a session permit for the provider, both released right away,
/// then admits a prompt with them. Refusals from any step come back unchanged.
fn admit(limits: &ProviderLimits, p: ProviderId, task: &str) -> Result<(), Refusal> {
    let run = limits.run_started(p)?;
    let session = limits.acquire_session(p)?;
    limits.admit_prompt(&run, &session, task)
}

/// Same for counting a turn.
fn turn(limits: &ProviderLimits, p: ProviderId, task: &str) -> Result<u32, Refusal> {
    let run = limits.run_started(p)?;
    let session = limits.acquire_session(p)?;
    limits.record_turn(&run, &session, task)
}

const CLAUDE: ProviderId = ProviderId::Claude;
const CODEX: ProviderId = ProviderId::Codex;

// ---- sessions ---------------------------------------------------------------------------------------------------

#[test]
fn third_session_refused() {
    let (_clock, limits) = setup();
    let a = limits.acquire_session(CLAUDE).unwrap();
    let b = limits.acquire_session(CLAUDE).unwrap();
    let refused = refusal(limits.acquire_session(CLAUDE));
    assert_eq!(refused.rule, 1);
    assert_eq!(refused.kind, CeilingKind::ConcurrentSessions);
    assert!(refused.retry_at.is_none());
    drop((a, b));
}

#[test]
fn dropping_a_permit_frees_the_slot() {
    let (_clock, limits) = setup();
    let a = limits.acquire_session(CODEX).unwrap();
    let _b = limits.acquire_session(CODEX).unwrap();
    assert!(limits.acquire_session(CODEX).is_err());
    drop(a);
    let _c = limits.acquire_session(CODEX).unwrap();
    assert!(limits.acquire_session(CODEX).is_err());
}

#[test]
fn session_slots_are_per_provider() {
    let (_clock, limits) = setup();
    let _a = limits.acquire_session(CLAUDE).unwrap();
    let _b = limits.acquire_session(CLAUDE).unwrap();
    let c = limits.acquire_session(CODEX).unwrap();
    assert_eq!(c.provider(), CODEX);
}

#[test]
fn permit_outlives_the_limits_handle_it_came_from() {
    let (_clock, limits) = setup();
    let permit = limits.acquire_session(CLAUDE).unwrap();
    let other = limits.clone();
    drop(limits);
    assert_eq!(other.meters(CLAUDE).sessions.current, 1);
    drop(permit);
    assert_eq!(other.meters(CLAUDE).sessions.current, 0);
}

#[test]
fn permit_is_released_when_a_thread_panics_holding_it() {
    let (_clock, limits) = setup();
    let _other = limits.acquire_session(CLAUDE).unwrap();
    let permit = limits.acquire_session(CLAUDE).unwrap();
    assert!(limits.acquire_session(CLAUDE).is_err());
    let worker = std::thread::spawn(move || {
        let _held = permit;
        panic!("worker died while holding a session permit");
    });
    assert!(worker.join().is_err());
    assert_eq!(limits.meters(CLAUDE).sessions.current, 1);
    let _again = limits.acquire_session(CLAUDE).unwrap();
}

#[test]
fn permit_is_released_when_a_caught_panic_unwinds_through_it() {
    let (_clock, limits) = setup();
    let result = catch_unwind(AssertUnwindSafe(|| {
        let _a = limits.acquire_session(CODEX).unwrap();
        let _b = limits.acquire_session(CODEX).unwrap();
        panic!("scope failed");
    }));
    assert!(result.is_err());
    assert_eq!(limits.meters(CODEX).sessions.current, 0);
    let _a = limits.acquire_session(CODEX).unwrap();
    let _b = limits.acquire_session(CODEX).unwrap();
}

/// A clock that panics on demand, to poison the state lock from inside a limits call.
struct PanickyClock {
    inner: SimClock,
    explode: Arc<AtomicBool>,
}

impl Clock for PanickyClock {
    fn now(&self) -> DateTime<Utc> {
        self.inner.now()
    }
    fn monotonic(&self) -> Duration {
        assert!(
            !self.explode.load(Ordering::SeqCst),
            "clock failed on purpose"
        );
        self.inner.monotonic()
    }
}

#[test]
fn permit_and_run_guard_release_even_if_the_state_lock_is_poisoned() {
    let explode = Arc::new(AtomicBool::new(false));
    let clock = PanickyClock {
        inner: SimClock::new(noon()),
        explode: Arc::clone(&explode),
    };
    let limits = ProviderLimits::new(Arc::new(clock));
    limits.set_presence(present());
    let permit = limits.acquire_session(CLAUDE).unwrap();
    let guard = limits.run_started(CLAUDE).unwrap();

    // A panic inside a limits call poisons the lock while it is held.
    explode.store(true, Ordering::SeqCst);
    let result = catch_unwind(AssertUnwindSafe(|| admit(&limits, CLAUDE, "t1")));
    assert!(result.is_err());
    explode.store(false, Ordering::SeqCst);

    drop(permit);
    drop(guard);
    assert_eq!(limits.meters(CLAUDE).sessions.current, 0);
    let _again = limits.acquire_session(CLAUDE).unwrap();
}

// ---- prompts per hour -------------------------------------------------------------------------------------------

#[test]
fn thirty_first_prompt_refused_within_hour() {
    let (clock, limits) = setup();
    let first = clock.now();
    for i in 0..30 {
        admit(&limits, CLAUDE, "t1").unwrap_or_else(|e| panic!("prompt {i} refused: {e}"));
        mins(&clock, &limits, 1);
    }
    // 30 minutes in, the window holds 30.
    let refused = refusal(admit(&limits, CLAUDE, "t1"));
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
        admit(&limits, CLAUDE, "t1").unwrap();
    }
    for _ in 0..10 {
        assert!(admit(&limits, CLAUDE, "t1").is_err());
    }
    assert_eq!(limits.meters(CLAUDE).prompts_last_hour.current, 30);
    // Once the original 30 age out, a full 30 are admitted again, so the refusals left nothing behind.
    mins(&clock, &limits, 60);
    for _ in 0..30 {
        admit(&limits, CLAUDE, "t1").unwrap();
    }
    assert!(admit(&limits, CLAUDE, "t1").is_err());
}

#[test]
fn prompt_window_slides() {
    let (clock, limits) = setup();
    admit(&limits, CLAUDE, "t1").unwrap();
    mins(&clock, &limits, 30);
    for _ in 0..29 {
        admit(&limits, CLAUDE, "t1").unwrap();
    }
    assert!(admit(&limits, CLAUDE, "t1").is_err());
    // 59m59s after the first prompt it still counts; at exactly 60 minutes it has left the window.
    mins(&clock, &limits, 29);
    clock.advance(Duration::from_secs(59));
    assert!(admit(&limits, CLAUDE, "t1").is_err());
    clock.advance(Duration::from_secs(1));
    admit(&limits, CLAUDE, "t1").unwrap();
    assert!(admit(&limits, CLAUDE, "t1").is_err());
}

#[test]
fn prompt_windows_are_per_provider() {
    let (_clock, limits) = setup();
    for _ in 0..30 {
        admit(&limits, CLAUDE, "t1").unwrap();
    }
    assert!(admit(&limits, CLAUDE, "t1").is_err());
    admit(&limits, CODEX, "t2").unwrap();
}

// ---- turns per task ---------------------------------------------------------------------------------------------

#[test]
fn forty_first_turn_refused() {
    let (_clock, limits) = setup();
    for n in 1..=40 {
        assert_eq!(turn(&limits, CLAUDE, "task-a").unwrap(), n);
    }
    let refused = refusal(turn(&limits, CLAUDE, "task-a"));
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
        turn(&limits, CLAUDE, "task-a").unwrap();
    }
    assert!(turn(&limits, CLAUDE, "task-a").is_err());
    assert_eq!(turn(&limits, CLAUDE, "task-b").unwrap(), 1);
}

#[test]
fn turns_survive_sessions_and_permits() {
    let (_clock, limits) = setup();
    {
        let _permit = limits.acquire_session(CLAUDE).unwrap();
        for _ in 0..40 {
            turn(&limits, CLAUDE, "task-a").unwrap();
        }
    }
    let _new_session = limits.acquire_session(CLAUDE).unwrap();
    assert!(turn(&limits, CLAUDE, "task-a").is_err());
}

#[test]
fn record_turn_refused_when_must_pause_and_counts_nothing() {
    let (_clock, limits) = setup();
    limits.set_presence(Presence {
        idle_minutes: 30,
        app_in_background: false,
    });
    assert!(limits.must_pause(CLAUDE));
    let refused = refusal(turn(&limits, CLAUDE, "task-a"));
    assert_eq!(refused.kind, CeilingKind::UserIdle);
    assert_eq!(limits.task_turns("task-a").current, 0);
    limits.set_presence(present());
    assert_eq!(turn(&limits, CLAUDE, "task-a").unwrap(), 1);
}

#[test]
fn record_turn_refused_once_the_run_budget_is_used() {
    let (clock, limits) = setup();
    let _run = limits.run_started(CLAUDE).unwrap();
    mins(&clock, &limits, 480);
    let refused = refusal(turn(&limits, CLAUDE, "task-a"));
    assert_eq!(refused.kind, CeilingKind::RunMinutesPerDay);
    // Another provider's budget is separate.
    assert_eq!(turn(&limits, CODEX, "task-b").unwrap(), 1);
}

// ---- run minutes per day ----------------------------------------------------------------------------------------

#[test]
fn run_minutes_capped_at_480() {
    let (clock, limits) = setup();
    let run = limits.run_started(CLAUDE).unwrap();
    mins(&clock, &limits, 479);
    admit(&limits, CLAUDE, "t1").unwrap();
    assert_eq!(limits.meters(CLAUDE).run_minutes_today.current, 479);
    mins(&clock, &limits, 1);
    let refused = refusal(admit(&limits, CLAUDE, "t1"));
    assert_eq!(refused.rule, 1);
    assert_eq!(refused.kind, CeilingKind::RunMinutesPerDay);
    let midnight = Utc.with_ymd_and_hms(2026, 10, 30, 0, 0, 0).unwrap();
    assert_eq!(refused.retry_at, Some(midnight));

    drop(run);
    let again = refusal(limits.run_started(CLAUDE));
    assert_eq!(again.kind, CeilingKind::RunMinutesPerDay);
    // The cap is per provider.
    let _other = limits.run_started(CODEX).unwrap();
}

#[test]
fn run_minutes_accumulate_across_runs() {
    let (clock, limits) = setup();
    for _ in 0..4 {
        let run = limits.run_started(CODEX).unwrap();
        mins(&clock, &limits, 100);
        drop(run);
        mins(&clock, &limits, 10); // time between runs does not count
    }
    assert_eq!(limits.meters(CODEX).run_minutes_today.current, 400);
    let _run = limits.run_started(CODEX).unwrap();
    mins(&clock, &limits, 80);
    assert!(admit(&limits, CODEX, "t1").is_err());
}

#[test]
fn run_counter_resets_at_utc_midnight_only() {
    let (clock, limits) = setup_at(Utc.with_ymd_and_hms(2026, 10, 29, 14, 0, 0).unwrap());
    let run = limits.run_started(CLAUDE).unwrap();
    mins(&clock, &limits, 480);
    drop(run);
    assert!(limits.run_started(CLAUDE).is_err());
    mins(&clock, &limits, 60 + 59); // 23:59 UTC
    assert!(limits.run_started(CLAUDE).is_err());
    mins(&clock, &limits, 1); // 00:00 UTC
    let _run = limits.run_started(CLAUDE).unwrap();
    assert_eq!(limits.meters(CLAUDE).run_minutes_today.current, 0);
}

#[test]
fn midnight_reset_does_not_reset_other_counters() {
    let (clock, limits) = setup_at(Utc.with_ymd_and_hms(2026, 10, 29, 23, 30, 0).unwrap());
    for _ in 0..40 {
        turn(&limits, CLAUDE, "task-a").unwrap();
    }
    let run = limits.run_started(CLAUDE).unwrap();
    let a = limits.acquire_session(CLAUDE).unwrap();
    let _b = limits.acquire_session(CLAUDE).unwrap();
    mins(&clock, &limits, 31); // past midnight: turns and sessions must stay
    let refused = refusal(limits.record_turn(&run, &a, "task-a"));
    assert_eq!(refused.kind, CeilingKind::TurnsPerTask);
    assert!(limits.acquire_session(CLAUDE).is_err());
}

#[test]
fn a_run_spanning_midnight_only_counts_the_new_day() {
    let (clock, limits) = setup_at(Utc.with_ymd_and_hms(2026, 10, 29, 23, 0, 0).unwrap());
    let run = limits.run_started(CLAUDE).unwrap();
    mins(&clock, &limits, 90); // 00:30 next day
    assert_eq!(limits.meters(CLAUDE).run_minutes_today.current, 30);
    drop(run);
    assert_eq!(limits.meters(CLAUDE).run_minutes_today.current, 30);
}

#[test]
fn overlapping_runs_count_per_run() {
    let (clock, limits) = setup();
    let a = limits.run_started(CLAUDE).unwrap();
    let b = limits.run_started(CLAUDE).unwrap();
    mins(&clock, &limits, 10);
    drop(a);
    drop(b);
    assert_eq!(limits.meters(CLAUDE).run_minutes_today.current, 20);
    mins(&clock, &limits, 10);
    assert_eq!(
        limits.meters(CLAUDE).run_minutes_today.current,
        20,
        "no run is open, so nothing accrues"
    );
}

#[test]
fn two_concurrent_runs_hit_the_cap_at_four_wall_hours() {
    let (clock, limits) = setup();
    let _a = limits.run_started(CLAUDE).unwrap();
    let _b = limits.run_started(CLAUDE).unwrap();
    mins(&clock, &limits, 4 * 60 - 1);
    admit(&limits, CLAUDE, "t1").unwrap();
    assert!(!limits.must_pause(CLAUDE));
    mins(&clock, &limits, 1);
    let refused = refusal(admit(&limits, CLAUDE, "t1"));
    assert_eq!(refused.kind, CeilingKind::RunMinutesPerDay);
    assert_eq!(limits.meters(CLAUDE).run_minutes_today.current, 480);
}

#[test]
fn dropping_a_run_guard_ends_the_run_even_on_panic() {
    let (clock, limits) = setup();
    let run = limits.run_started(CLAUDE).unwrap();
    let worker = std::thread::spawn(move || {
        let _held = run;
        panic!("worker died mid-run");
    });
    assert!(worker.join().is_err());
    let before = limits.meters(CLAUDE).run_minutes_today.current;
    mins(&clock, &limits, 30);
    assert_eq!(limits.meters(CLAUDE).run_minutes_today.current, before);
}

#[test]
fn runs_accrue_in_milliseconds_so_short_runs_add_up() {
    let (clock, limits) = setup();
    for _ in 0..100 {
        let run = limits.run_started(CLAUDE).unwrap();
        clock.advance(Duration::from_millis(300));
        drop(run);
    }
    let seconds = limits.snapshot().run[&CLAUDE].seconds;
    assert_eq!(seconds, 30, "100 runs of 300 ms are 30 s");
}

#[test]
fn a_backward_wall_clock_jump_never_reduces_run_time() {
    let (clock, limits) = setup();
    let _run = limits.run_started(CLAUDE).unwrap();
    mins(&clock, &limits, 60);
    clock.jump_wall_back(Duration::from_secs(3 * 3600));
    assert_eq!(limits.meters(CLAUDE).run_minutes_today.current, 60);
    mins(&clock, &limits, 60);
    assert_eq!(limits.meters(CLAUDE).run_minutes_today.current, 120);
}

#[test]
fn a_backward_wall_clock_jump_cannot_roll_a_day_back_and_reopen_the_budget() {
    let (clock, limits) = setup_at(Utc.with_ymd_and_hms(2026, 10, 29, 8, 0, 0).unwrap());
    let run = limits.run_started(CLAUDE).unwrap();
    mins(&clock, &limits, 480);
    drop(run);
    clock.jump_wall_back(Duration::from_secs(24 * 3600));
    limits.set_presence(present());
    assert!(limits.run_started(CLAUDE).is_err());
}

#[test]
fn a_forward_wall_clock_jump_does_not_roll_the_day() {
    let (clock, limits) = setup();
    let run = limits.run_started(CLAUDE).unwrap();
    mins(&clock, &limits, 480);
    drop(run);
    assert!(limits.run_started(CLAUDE).is_err());
    // The user sets the system date to tomorrow; no real time passes.
    clock.jump_wall_forward(Duration::from_secs(24 * 3600));
    limits.set_presence(present());
    let refused = refusal(limits.run_started(CLAUDE));
    assert_eq!(refused.kind, CeilingKind::RunMinutesPerDay);
    assert_eq!(limits.meters(CLAUDE).run_minutes_today.current, 480);
    // Real time still rolls the day: 20:00 plus four hours is the next UTC day.
    mins(&clock, &limits, 4 * 60);
    let _run = limits.run_started(CLAUDE).unwrap();
}

#[test]
fn a_forward_wall_clock_jump_does_not_expire_prompts() {
    let (clock, limits) = setup();
    for _ in 0..30 {
        admit(&limits, CLAUDE, "t1").unwrap();
    }
    clock.jump_wall_forward(Duration::from_secs(2 * 3600));
    limits.set_presence(present());
    let refused = refusal(admit(&limits, CLAUDE, "t1"));
    assert_eq!(refused.kind, CeilingKind::PromptsPerHour);
    assert_eq!(limits.meters(CLAUDE).prompts_last_hour.current, 30);
    // Real time still ages them out.
    mins(&clock, &limits, 60);
    admit(&limits, CLAUDE, "t1").unwrap();
}

#[test]
fn a_backward_wall_clock_jump_does_not_keep_prompts_longer_than_real_time() {
    let (clock, limits) = setup();
    for _ in 0..30 {
        admit(&limits, CLAUDE, "t1").unwrap();
    }
    clock.jump_wall_back(Duration::from_secs(5 * 3600));
    mins(&clock, &limits, 60);
    admit(&limits, CLAUDE, "t1").unwrap();
}

// ---- pause poll -------------------------------------------------------------------------------------------------

#[test]
fn must_pause_is_false_for_a_present_user_with_budget_left() {
    let (_clock, limits) = setup();
    assert!(!limits.must_pause(CLAUDE));
    assert!(limits.pause_reason(CLAUDE).is_none());
}

#[test]
fn must_pause_turns_true_when_an_active_run_passes_the_budget() {
    let (clock, limits) = setup();
    let _run = limits.run_started(CLAUDE).unwrap();
    mins(&clock, &limits, 479);
    assert!(!limits.must_pause(CLAUDE));
    mins(&clock, &limits, 1);
    // No admission was attempted: the poll alone reports it.
    assert!(limits.must_pause(CLAUDE));
    let reason = limits.pause_reason(CLAUDE).unwrap();
    assert_eq!(
        (reason.rule, reason.kind),
        (1, CeilingKind::RunMinutesPerDay)
    );
    assert!(!limits.must_pause(CODEX));
}

#[test]
fn must_pause_follows_presence() {
    let (_clock, limits) = setup();
    limits.set_presence(Presence {
        idle_minutes: 30,
        app_in_background: false,
    });
    assert!(limits.must_pause(CLAUDE));
    limits.set_presence(Presence {
        idle_minutes: 0,
        app_in_background: true,
    });
    assert!(limits.must_pause(CLAUDE));
    limits.set_presence(present());
    assert!(!limits.must_pause(CLAUDE));
}

// ---- presence ---------------------------------------------------------------------------------------------------

#[test]
fn idle_30_blocks_prompts() {
    let (_clock, limits) = setup();
    limits.set_presence(Presence {
        idle_minutes: 29,
        app_in_background: false,
    });
    admit(&limits, CLAUDE, "t1").unwrap();
    limits.set_presence(Presence {
        idle_minutes: 30,
        app_in_background: false,
    });
    let refused = refusal(admit(&limits, CLAUDE, "t1"));
    assert_eq!(refused.rule, 1);
    assert_eq!(refused.kind, CeilingKind::UserIdle);
    assert!(refused.message.contains("30"));
    let refused = refusal(limits.run_started(CLAUDE));
    assert_eq!(refused.kind, CeilingKind::UserIdle);
    // The user comes back.
    limits.set_presence(present());
    admit(&limits, CLAUDE, "t1").unwrap();
    let _run = limits.run_started(CLAUDE).unwrap();
}

#[test]
fn background_app_blocks_prompts_and_runs() {
    let (_clock, limits) = setup();
    limits.set_presence(Presence {
        idle_minutes: 0,
        app_in_background: true,
    });
    let refused = refusal(admit(&limits, CODEX, "t1"));
    assert_eq!(refused.kind, CeilingKind::AppBackground);
    let refused = refusal(limits.run_started(CODEX));
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
        assert!(admit(&limits, CLAUDE, "t1").is_err());
    }
    limits.set_presence(present());
    assert_eq!(limits.meters(CLAUDE).prompts_last_hour.current, 0);
}

#[test]
fn nothing_runs_before_the_first_presence_report() {
    let clock = SimClock::new(noon());
    let limits = ProviderLimits::new(Arc::new(clock.clone()));
    assert_eq!(limits.presence(), None);
    assert_eq!(
        refusal(admit(&limits, CLAUDE, "t1")).kind,
        CeilingKind::PresenceUnknown
    );
    assert_eq!(
        refusal(limits.run_started(CLAUDE)).kind,
        CeilingKind::PresenceUnknown
    );
    assert_eq!(
        refusal(turn(&limits, CLAUDE, "t1")).kind,
        CeilingKind::PresenceUnknown
    );
    assert!(limits.must_pause(CLAUDE));
    limits.set_presence(present());
    assert_eq!(limits.presence(), Some(present()));
    admit(&limits, CLAUDE, "t1").unwrap();
    assert!(!limits.must_pause(CLAUDE));
}

#[test]
fn a_presence_report_older_than_five_minutes_counts_as_idle() {
    let (clock, limits) = setup();
    clock.advance(Duration::from_secs(4 * 60 + 59));
    admit(&limits, CLAUDE, "t1").unwrap();
    clock.advance(Duration::from_secs(1));
    let refused = refusal(admit(&limits, CLAUDE, "t1"));
    assert_eq!((refused.rule, refused.kind), (1, CeilingKind::UserIdle));
    assert!(limits.must_pause(CLAUDE));
    assert!(limits.run_started(CLAUDE).is_err());
    // A new report from the app restores it.
    limits.set_presence(present());
    admit(&limits, CLAUDE, "t1").unwrap();
}

#[test]
fn a_wall_clock_jump_does_not_refresh_a_stale_presence_report() {
    let (clock, limits) = setup();
    clock.advance(Duration::from_secs(10 * 60));
    clock.jump_wall_back(Duration::from_secs(3600));
    assert!(limits.must_pause(CLAUDE));
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
    limits.set_presence(present());
    let m = limits.meters(CLAUDE);
    assert_eq!(m.sessions.limit, 2);
    assert_eq!(m.prompts_last_hour.limit, 30);
    assert_eq!(m.run_minutes_today.limit, 480);
    assert_eq!(limits.task_turns("t").limit, 40);
    for _ in 0..30 {
        admit(&limits, CLAUDE, "t1").unwrap();
    }
    assert!(admit(&limits, CLAUDE, "t1").is_err());
    limits.set_presence(Presence {
        idle_minutes: 30,
        app_in_background: false,
    });
    assert!(admit(&limits, CODEX, "t1").is_err());
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
    limits.set_presence(present());
    let session = limits.acquire_session(CLAUDE).unwrap();
    let refused = refusal(limits.acquire_session(CLAUDE));
    assert_eq!(refused.kind, CeilingKind::ConcurrentSessions);
    let run = limits.run_started(CLAUDE).unwrap();
    for _ in 0..3 {
        limits.admit_prompt(&run, &session, "t1").unwrap();
    }
    let refused = refusal(limits.admit_prompt(&run, &session, "t1"));
    assert_eq!(refused.kind, CeilingKind::PromptsPerHour);
    for _ in 0..5 {
        limits.record_turn(&run, &session, "t1").unwrap();
    }
    let refused = refusal(limits.record_turn(&run, &session, "t1"));
    assert_eq!(refused.kind, CeilingKind::TurnsPerTask);
    limits.set_presence(Presence {
        idle_minutes: 10,
        app_in_background: false,
    });
    assert_eq!(
        refusal(limits.run_started(CODEX)).kind,
        CeilingKind::UserIdle
    );
    assert_eq!(limits.meters(CODEX).run_minutes_today.limit, 60);
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
        admit(&limits, CLAUDE, "t1").unwrap();
    }
    for _ in 0..12 {
        turn(&limits, CLAUDE, "t1").unwrap();
    }
    let run = limits.run_started(CODEX).unwrap();
    mins(&clock, &limits, 45);
    drop(run);

    let json = serde_json::to_string(&limits.snapshot()).unwrap();
    let restored_snapshot: LimitsSnapshot = serde_json::from_str(&json).unwrap();

    // A fresh instance (an app restart) loads it and sees the same counters.
    let fresh = ProviderLimits::new(Arc::new(clock.clone()));
    fresh.set_presence(present());
    fresh.load(&restored_snapshot);
    assert_eq!(fresh.meters(CLAUDE).prompts_last_hour.current, 7);
    assert_eq!(fresh.task_turns("t1").current, 12);
    assert_eq!(fresh.meters(CODEX).run_minutes_today.current, 45);
    assert_eq!(fresh.snapshot(), limits.snapshot());
}

#[test]
fn snapshot_includes_the_live_stretch_of_an_active_run() {
    let (clock, limits) = setup();
    let _run = limits.run_started(CLAUDE).unwrap();
    mins(&clock, &limits, 20);
    assert_eq!(limits.snapshot().run[&CLAUDE].seconds, 20 * 60);
}

#[test]
fn loaded_prompts_still_age_out_and_count_against_the_cap() {
    let (clock, limits) = setup();
    for _ in 0..30 {
        admit(&limits, CLAUDE, "t1").unwrap();
    }
    let snap = limits.snapshot();
    let fresh = ProviderLimits::new(Arc::new(clock.clone()));
    fresh.set_presence(present());
    fresh.load(&snap);
    assert!(admit(&fresh, CLAUDE, "t1").is_err());
    mins(&clock, &fresh, 60);
    admit(&fresh, CLAUDE, "t1").unwrap();
}

#[test]
fn load_never_lowers_a_counter() {
    let (_clock, limits) = setup();
    for _ in 0..10 {
        turn(&limits, CLAUDE, "t1").unwrap();
    }
    for _ in 0..5 {
        admit(&limits, CLAUDE, "t1").unwrap();
    }
    let stale = LimitsSnapshot::default();
    limits.load(&stale);
    assert_eq!(limits.task_turns("t1").current, 10);
    assert_eq!(limits.meters(CLAUDE).prompts_last_hour.current, 5);

    // Loading the same snapshot twice does not double count.
    let snap = limits.snapshot();
    limits.load(&snap);
    limits.load(&snap);
    assert_eq!(limits.meters(CLAUDE).prompts_last_hour.current, 5);
    assert_eq!(limits.task_turns("t1").current, 10);
}

fn saved_run(day: NaiveDate, minutes: u64) -> LimitsSnapshot {
    let mut snap = LimitsSnapshot::default();
    snap.run.insert(
        CLAUDE,
        RunDay {
            day,
            seconds: minutes * 60,
        },
    );
    snap
}

#[test]
fn load_ignores_run_minutes_from_a_past_day() {
    let (clock, limits) = setup();
    let yesterday = clock.now().date_naive() - chrono::Days::new(1);
    limits.load(&saved_run(yesterday, 480));
    let _run = limits.run_started(CLAUDE).unwrap();
}

#[test]
fn load_applies_run_minutes_for_today() {
    let (clock, limits) = setup();
    limits.load(&saved_run(clock.now().date_naive(), 480));
    assert_eq!(
        refusal(limits.run_started(CLAUDE)).kind,
        CeilingKind::RunMinutesPerDay
    );
}

#[test]
fn load_with_future_saved_day_keeps_counter() {
    let (clock, limits) = setup();
    let today = clock.now().date_naive();
    let tomorrow = today + chrono::Days::new(1);
    // The saved counter is dated later than the current day (the system date moved back).
    limits.load(&saved_run(tomorrow, 400));
    assert_eq!(limits.meters(CLAUDE).run_minutes_today.current, 400);
    assert_eq!(limits.snapshot().run[&CLAUDE].day, tomorrow);
    let run = limits.run_started(CLAUDE).unwrap();
    mins(&clock, &limits, 80);
    drop(run);
    assert_eq!(
        refusal(limits.run_started(CLAUDE)).kind,
        CeilingKind::RunMinutesPerDay
    );
    // Still held a day later: it is released only when real time reaches the end of that later day.
    mins(&clock, &limits, 24 * 60);
    assert!(limits.run_started(CLAUDE).is_err());
    mins(&clock, &limits, 10 * 60 + 40);
    let _run = limits.run_started(CLAUDE).unwrap();
}

#[test]
fn load_keeps_the_higher_usage_when_the_current_day_is_earlier() {
    let (clock, limits) = setup();
    let run = limits.run_started(CLAUDE).unwrap();
    mins(&clock, &limits, 300);
    drop(run);
    let tomorrow = clock.now().date_naive() + chrono::Days::new(1);
    limits.load(&saved_run(tomorrow, 100));
    assert_eq!(limits.meters(CLAUDE).run_minutes_today.current, 300);
}

// ---- dispatch coupling ------------------------------------------------------------------------------------------

#[test]
fn admit_prompt_and_record_turn_accept_a_matching_run_and_session() {
    let (_clock, limits) = setup();
    let run = limits.run_started(CLAUDE).unwrap();
    let session = limits.acquire_session(CLAUDE).unwrap();
    limits.admit_prompt(&run, &session, "t1").unwrap();
    assert_eq!(limits.record_turn(&run, &session, "t1").unwrap(), 1);
    assert_eq!(limits.meters(CLAUDE).prompts_last_hour.current, 1);
}

#[test]
fn a_run_and_session_for_different_providers_are_refused() {
    let (_clock, limits) = setup();
    let run = limits.run_started(CLAUDE).unwrap();
    let session = limits.acquire_session(CODEX).unwrap();
    let refused = refusal(limits.admit_prompt(&run, &session, "t1"));
    assert_eq!(
        (refused.rule, refused.kind),
        (1, CeilingKind::DispatchNotCoupled)
    );
    let refused = refusal(limits.record_turn(&run, &session, "t1"));
    assert_eq!(refused.kind, CeilingKind::DispatchNotCoupled);
    // Nothing was counted for either provider.
    assert_eq!(limits.meters(CLAUDE).prompts_last_hour.current, 0);
    assert_eq!(limits.meters(CODEX).prompts_last_hour.current, 0);
    assert_eq!(limits.task_turns("t1").current, 0);
}

#[test]
fn a_run_or_session_from_another_instance_is_refused() {
    let (_clock, limits) = setup();
    let (_other_clock, other) = setup();
    let run = limits.run_started(CLAUDE).unwrap();
    let session = limits.acquire_session(CLAUDE).unwrap();
    let foreign_run = other.run_started(CLAUDE).unwrap();
    let foreign_session = other.acquire_session(CLAUDE).unwrap();
    for (r, s) in [(&foreign_run, &session), (&run, &foreign_session)] {
        let refused = refusal(limits.admit_prompt(r, s, "t1"));
        assert_eq!(refused.kind, CeilingKind::DispatchNotCoupled);
        let refused = refusal(limits.record_turn(r, s, "t1"));
        assert_eq!(refused.kind, CeilingKind::DispatchNotCoupled);
    }
    assert_eq!(limits.meters(CLAUDE).prompts_last_hour.current, 0);
    assert_eq!(limits.task_turns("t1").current, 0);
}

// ---- restart across a system date change -----------------------------------------------------------------------

/// A new process over the same machine: a fresh `ProviderLimits` that loads the saved snapshot.
fn restart(clock: &SimClock, saved: &LimitsSnapshot) -> ProviderLimits {
    let limits = ProviderLimits::new(Arc::new(clock.clone()));
    limits.load(saved);
    limits.set_presence(present());
    limits
}

fn exhausted_run_budget() -> (SimClock, ProviderLimits) {
    let (clock, limits) = setup();
    let run = limits.run_started(CLAUDE).unwrap();
    mins(&clock, &limits, 480);
    drop(run);
    (clock, limits)
}

#[test]
fn restart_after_a_forward_date_change_keeps_the_prompt_window() {
    let (clock, limits) = setup();
    for _ in 0..30 {
        admit(&limits, CLAUDE, "t1").unwrap();
    }
    let saved = limits.snapshot();
    drop(limits);
    // The user moves the system date forward two hours and restarts the app (same boot).
    clock.jump_wall_forward(Duration::from_secs(2 * 3600));
    let limits = restart(&clock, &saved);
    let refused = refusal(admit(&limits, CLAUDE, "t1"));
    assert_eq!(refused.kind, CeilingKind::PromptsPerHour);
    assert_eq!(limits.meters(CLAUDE).prompts_last_hour.current, 30);
    // Real time still ages the prompts out.
    mins(&clock, &limits, 60);
    admit(&limits, CLAUDE, "t1").unwrap();
}

#[test]
fn restart_after_a_forward_date_change_keeps_the_run_budget() {
    let (clock, limits) = exhausted_run_budget();
    let saved = limits.snapshot();
    drop(limits);
    clock.jump_wall_forward(Duration::from_secs(48 * 3600));
    let limits = restart(&clock, &saved);
    assert_eq!(
        refusal(limits.run_started(CLAUDE)).kind,
        CeilingKind::RunMinutesPerDay
    );
    assert!(limits.must_pause(CLAUDE));
    assert_eq!(limits.meters(CLAUDE).run_minutes_today.current, 480);
    // Real time still rolls the day: 20:00 plus four hours.
    mins(&clock, &limits, 4 * 60);
    let _run = limits.run_started(CLAUDE).unwrap();
}

#[test]
fn restart_after_a_backward_date_change_keeps_both_budgets() {
    let (clock, limits) = exhausted_run_budget();
    for _ in 0..30 {
        admit(&limits, CODEX, "t1").unwrap();
    }
    let saved = limits.snapshot();
    drop(limits);
    clock.jump_wall_back(Duration::from_secs(24 * 3600));
    let limits = restart(&clock, &saved);
    assert!(limits.run_started(CLAUDE).is_err());
    assert!(admit(&limits, CODEX, "t1").is_err());
}

#[test]
fn a_different_boot_falls_back_to_the_wall_clock_but_never_lowers_a_counter() {
    let (clock, limits) = exhausted_run_budget();
    for _ in 0..5 {
        admit(&limits, CODEX, "t1").unwrap();
    }
    turn(&limits, CODEX, "t1").unwrap();
    let saved = limits.snapshot();
    drop(limits);

    // Rebooted, date unchanged: the wall clock is trusted and the current day's counters are kept.
    clock.set_boot_id("boot-2");
    let limits = restart(&clock, &saved);
    assert!(limits.run_started(CLAUDE).is_err());
    assert_eq!(limits.meters(CODEX).prompts_last_hour.current, 5);
    assert_eq!(limits.task_turns("t1").current, 1);
    drop(limits);

    // Rebooted AND the date moved forward: nothing can be proven. This is the documented residual of the restart
    // guard (see the handoff): the old day looks like the past, so it is not carried over.
    clock.jump_wall_forward(Duration::from_secs(48 * 3600));
    clock.set_boot_id("boot-3");
    let limits = restart(&clock, &saved);
    let _run = limits.run_started(CLAUDE).unwrap();
    assert_eq!(limits.meters(CODEX).prompts_last_hour.current, 0);
    // Turn counts have no date, so they are still never lowered.
    assert_eq!(limits.task_turns("t1").current, 1);
}

/// A clock whose platform cannot tell the boot identity.
struct NoBootId(SimClock);

impl Clock for NoBootId {
    fn now(&self) -> DateTime<Utc> {
        self.0.now()
    }
    fn monotonic(&self) -> Duration {
        self.0.monotonic()
    }
}

#[test]
fn an_unknown_boot_id_proves_nothing() {
    let sim = SimClock::new(noon());
    let limits = ProviderLimits::new(Arc::new(NoBootId(sim.clone())));
    limits.set_presence(present());
    for _ in 0..30 {
        admit(&limits, CLAUDE, "t1").unwrap();
    }
    let saved = limits.snapshot();
    assert_eq!(saved.anchor.as_ref().unwrap().boot_id, None);
    sim.jump_wall_forward(Duration::from_secs(2 * 3600));
    let restarted = ProviderLimits::new(Arc::new(NoBootId(sim.clone())));
    restarted.load(&saved);
    assert_eq!(restarted.meters(CLAUDE).prompts_last_hour.current, 0);
}

#[test]
fn a_small_forward_date_change_at_the_day_boundary_does_not_reset_the_budget() {
    // 15:58 plus the 480 minute budget: the budget is used up at 23:58.
    let (clock, limits) = setup_at(Utc.with_ymd_and_hms(2026, 10, 29, 15, 58, 0).unwrap());
    let run = limits.run_started(CLAUDE).unwrap();
    mins(&clock, &limits, 480);
    drop(run);
    assert_eq!(
        clock.now(),
        Utc.with_ymd_and_hms(2026, 10, 29, 23, 58, 0).unwrap()
    );
    assert!(limits.run_started(CLAUDE).is_err());
    let saved = limits.snapshot();
    drop(limits);

    // Three minutes forward would cross midnight if the wall clock were trusted.
    clock.jump_wall_forward(Duration::from_secs(3 * 60));
    let restarted = restart(&clock, &saved);
    assert_eq!(
        refusal(restarted.run_started(CLAUDE)).kind,
        CeilingKind::RunMinutesPerDay
    );
    assert_eq!(restarted.meters(CLAUDE).run_minutes_today.current, 480);
    // Real time still rolls the day at midnight, two minutes later.
    mins(&clock, &restarted, 2);
    let _run = restarted.run_started(CLAUDE).unwrap();
}

#[test]
fn repeated_small_date_advances_across_restarts_never_expire_prompts_early() {
    let (clock, limits) = setup();
    for _ in 0..30 {
        admit(&limits, CLAUDE, "t1").unwrap();
    }
    let mut current = limits;
    // Fifteen cycles of: user sets the date 4 minutes forward, the app restarts, snapshots. Wall-clock slack accepted at
    // load would add up to 60 minutes; real time elapsed is only the 15 minutes of heartbeats below.
    for _ in 0..15 {
        let saved = current.snapshot();
        drop(current);
        clock.jump_wall_forward(Duration::from_secs(4 * 60));
        current = restart(&clock, &saved);
        mins(&clock, &current, 1);
    }
    // 15 real minutes in: the original 30 prompts are all still in the window.
    assert_eq!(current.meters(CLAUDE).prompts_last_hour.current, 30);
    assert_eq!(
        refusal(admit(&current, CLAUDE, "t1")).kind,
        CeilingKind::PromptsPerHour
    );
    // They leave only after a real hour.
    mins(&clock, &current, 45);
    admit(&current, CLAUDE, "t1").unwrap();
}

#[test]
fn snapshots_carry_the_clock_anchor_and_old_ones_still_load() {
    let (clock, limits) = setup();
    mins(&clock, &limits, 7);
    let saved = limits.snapshot();
    let anchor = saved.anchor.clone().unwrap();
    assert_eq!(anchor.boot_id, clock.boot_id());
    assert_eq!(anchor.mono, clock.monotonic());
    assert_eq!(anchor.wall, clock.now());

    let mut json: serde_json::Value = serde_json::to_value(&saved).unwrap();
    json.as_object_mut().unwrap().remove("anchor");
    let old: LimitsSnapshot = serde_json::from_value(json).unwrap();
    assert!(old.anchor.is_none());
    limits.load(&old);
}

// ---- idle time keeps growing ------------------------------------------------------------------------------------

#[test]
fn reported_idle_time_ages_without_a_new_report() {
    let (clock, limits) = setup();
    limits.set_presence(Presence {
        idle_minutes: 29,
        app_in_background: false,
    });
    admit(&limits, CLAUDE, "t1").unwrap();
    clock.advance(Duration::from_secs(59));
    admit(&limits, CLAUDE, "t1").unwrap();
    clock.advance(Duration::from_secs(1)); // 29 min reported + 60 s = 30 min idle
    let refused = refusal(admit(&limits, CLAUDE, "t1"));
    assert_eq!((refused.rule, refused.kind), (1, CeilingKind::UserIdle));
    clock.advance(Duration::from_secs(60));
    assert!(limits.must_pause(CLAUDE));
}

#[test]
fn report_29_minutes_idle_then_two_minutes_without_a_report_is_refused() {
    let (clock, limits) = setup();
    limits.set_presence(Presence {
        idle_minutes: 29,
        app_in_background: false,
    });
    clock.advance(Duration::from_secs(2 * 60));
    assert_eq!(
        refusal(admit(&limits, CLAUDE, "t1")).kind,
        CeilingKind::UserIdle
    );
    assert_eq!(
        refusal(limits.run_started(CLAUDE)).kind,
        CeilingKind::UserIdle
    );
    assert!(turn(&limits, CLAUDE, "t1").is_err());
}

// ---- run time keeps sub-millisecond remainders ------------------------------------------------------------------

#[test]
fn ten_thousand_runs_of_500_microseconds_count_five_seconds() {
    let (clock, limits) = setup();
    for _ in 0..10_000 {
        let run = limits.run_started(CLAUDE).unwrap();
        clock.advance(Duration::from_micros(500));
        drop(run);
    }
    assert_eq!(limits.snapshot().run[&CLAUDE].seconds, 5);
}

#[test]
fn run_time_is_rounded_up_in_the_snapshot_never_down() {
    let (clock, limits) = setup();
    let run = limits.run_started(CLAUDE).unwrap();
    clock.advance(Duration::from_micros(1));
    drop(run);
    assert_eq!(limits.snapshot().run[&CLAUDE].seconds, 1);
}

// ---- provider ids and refusals ----------------------------------------------------------------------------------

#[test]
fn provider_id_lives_in_the_crate_provider_module() {
    let same: crate::provider::ProviderId = ProviderId::Gemini;
    assert_eq!(same, crate::provider::ProviderId::Gemini);
}

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
    let _a = limits.acquire_session(CLAUDE).unwrap();
    let _b = limits.acquire_session(CLAUDE).unwrap();
    let refused = refusal(limits.acquire_session(CLAUDE));
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
        ["clock_get", "time"].concat(),
    ];
    for dir in ["limits", "events", "clock"] {
        for (name, source) in module_sources(dir) {
            if dir == "clock" && name == "system.rs" {
                continue; // the real clock, the one place that reads the OS
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
fn the_wall_clock_is_read_only_to_anchor_the_timeline() {
    // Every other file in limits/ must not call `.now()` on a clock at all.
    for (name, source) in module_sources("limits") {
        if name == "timeline.rs" || name == "tests.rs" {
            continue;
        }
        let call = [".no", "w()"].concat();
        assert!(
            !source.contains(call.as_str()),
            "limits/{name} reads the wall clock; only timeline.rs may, once, to anchor"
        );
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
