//! In-memory enforcement of the rule 1 ceilings, driven by an injected clock.
//!
//! All state is per provider (or per task id for turns). Nothing here keys on an account, profile or session, and there
//! is no function that lowers a counter other than the natural aging of the rolling window and the UTC-midnight roll of
//! the daily run counter (rule 2). Time comes from the monotonic clock (see `timeline`), never from the user-settable
//! wall clock after the first reading.
//!
//! Integration requirements for the callers (usage store, dispatch, 24-hour simulation):
//! - Keep ONE `ProviderLimits` for the whole app and pass clones of it around. Two instances would each start from zero.
//! - Call [`ProviderLimits::load`] with the persisted snapshot before the first admission after a start.
//! - Report presence with [`ProviderLimits::set_presence`] at least every few minutes; until the first report and after
//!   it goes stale, everything is refused.
//! - Dispatching one automated prompt needs all four, and the types enforce it: [`ProviderLimits::admit_prompt`] and
//!   [`ProviderLimits::record_turn`] each take the open [`RunGuard`] and the [`SessionPermit`] (same provider, from this
//!   instance), so a dispatch without a run and a session does not compile. Call both before dispatching.
//! - While a run is active, poll [`ProviderLimits::must_pause`]; an active run passing the daily budget is otherwise
//!   only stopped at the next admission.

use super::config::{EffectiveLimits, UserLimits};
use super::presence::Presence;
use super::refusal::{CeilingKind, Refusal};
use super::runclock::RunClock;
use super::timeline::{Tick, Timeline};
use crate::clock::Clock;
use crate::provider::ProviderId;
use chrono::{DateTime, NaiveDate, NaiveTime, TimeDelta, Utc};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap, VecDeque};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

const WINDOW_MINUTES: i64 = 60;
/// A presence report older than this is treated as the user being away. Not a user setting; it only makes things stricter.
const PRESENCE_MAX_AGE: Duration = Duration::from_secs(5 * 60);
/// How far the wall clock may differ from the time proven by a saved snapshot before `load` trusts the snapshot instead.
const CLOCK_TOLERANCE: TimeDelta = TimeDelta::minutes(5);

/// A value against its limit and the ceiling (`Meter` in the IPC contract).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct Meter {
    pub current: u32,
    /// The user's stricter value when set, else the ceiling.
    pub limit: u32,
    pub ceiling: u32,
}

/// The per-provider meters this module can fill in.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct ProviderMeters {
    pub sessions: Meter,
    pub prompts_last_hour: Meter,
    pub run_minutes_today: Meter,
}

/// One admitted prompt, kept for the rolling window.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PromptRecord {
    pub at: DateTime<Utc>,
    pub task_id: String,
}

/// Automated run time used on one UTC day, in whole seconds rounded up (never down, so a persisted value cannot be lower
/// than the live counter). The usage store must keep seconds, not minutes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct RunDay {
    pub day: NaiveDate,
    pub seconds: u64,
}

/// Clock readings taken when a snapshot was written. On load in the same boot they prove how much real time has passed,
/// so a system date changed in between (to expire the prompt window or roll the day) is detected and ignored.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ClockAnchor {
    /// `Clock::boot_id` when saved. Without a known, equal boot id nothing can be proven.
    pub boot_id: Option<String>,
    /// Monotonic reading when saved.
    pub mono: Duration,
    /// Trusted UTC time when saved.
    pub wall: DateTime<Utc>,
}

/// What the usage store persists (T-112): enough to rebuild every counter after a restart. Sessions and active runs are
/// not included because their guards die with the process. A crash loses the live stretch of any active run, so the
/// store should snapshot periodically while a run is active.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct LimitsSnapshot {
    pub prompts: BTreeMap<ProviderId, Vec<PromptRecord>>,
    pub turns: BTreeMap<String, u32>,
    pub run: BTreeMap<ProviderId, RunDay>,
    /// Absent in snapshots written before this field existed; `load` then relies on the wall clock alone.
    #[serde(default)]
    pub anchor: Option<ClockAnchor>,
}

/// Enforces the ceilings for subscription providers. Cheap to clone; clones share state.
#[derive(Clone)]
pub struct ProviderLimits {
    inner: Arc<Inner>,
}

struct Inner {
    clock: Arc<dyn Clock>,
    limits: EffectiveLimits,
    state: Mutex<State>,
}

#[derive(Default)]
struct State {
    timeline: Option<Timeline>,
    presence: Option<PresenceReport>,
    sessions: HashMap<ProviderId, u32>,
    prompts: HashMap<ProviderId, VecDeque<PromptRecord>>,
    turns: HashMap<String, u32>,
    runs: HashMap<ProviderId, RunClock>,
}

#[derive(Clone, Copy)]
struct PresenceReport {
    presence: Presence,
    /// Monotonic reading when the app reported it; the report ages from here.
    at: Duration,
}

impl State {
    /// A fresh reading of trusted time. The first call anchors the timeline.
    fn tick(&mut self, clock: &dyn Clock) -> Tick {
        self.timeline
            .get_or_insert_with(|| Timeline::anchored(clock))
            .tick(clock)
    }

    /// The run clock for `provider`, settled to `tick`.
    fn run(&mut self, provider: ProviderId, tick: Tick) -> &mut RunClock {
        let run = self
            .runs
            .entry(provider)
            .or_insert_with(|| RunClock::new(tick));
        run.settle(tick);
        run
    }
}

impl ProviderLimits {
    /// Enforces exactly the compiled ceilings.
    pub fn new(clock: Arc<dyn Clock>) -> Self {
        Self::build(clock, EffectiveLimits::ceilings())
    }

    /// Enforces `min(user, ceiling)` for each limit.
    pub fn with_user_limits(clock: Arc<dyn Clock>, user: &UserLimits) -> Self {
        Self::build(clock, EffectiveLimits::with_user(user))
    }

    fn build(clock: Arc<dyn Clock>, limits: EffectiveLimits) -> Self {
        Self {
            inner: Arc::new(Inner {
                clock,
                limits,
                state: Mutex::new(State::default()),
            }),
        }
    }

    /// The limits in force.
    pub fn effective_limits(&self) -> EffectiveLimits {
        self.inner.limits
    }

    /// Records what the app reports about the user, stamped with the monotonic clock. Presence is never inferred here.
    /// Until the first report, and again when a report is older than five minutes, automation is refused. The reported
    /// idle time keeps growing with the monotonic time since the report, so a report of 29 idle minutes is 30 a minute
    /// later even if no new report arrives.
    pub fn set_presence(&self, presence: Presence) {
        let mut state = self.lock();
        let tick = state.tick(&*self.inner.clock);
        state.presence = Some(PresenceReport {
            presence,
            at: tick.mono,
        });
    }

    /// The last report, or `None` when the app has not reported yet.
    pub fn presence(&self) -> Option<Presence> {
        self.lock().presence.map(|r| r.presence)
    }

    /// Takes one concurrent-session slot for `provider`; dropping the permit frees it, also when a thread panics.
    pub fn acquire_session(&self, provider: ProviderId) -> Result<SessionPermit, Refusal> {
        let limit = self.inner.limits.concurrent_sessions();
        let mut state = self.lock();
        let held = state.sessions.entry(provider).or_insert(0);
        if *held >= limit {
            return Err(Refusal::rule1(
                CeilingKind::ConcurrentSessions,
                format!("{provider} already has {limit} concurrent automated sessions"),
                None,
            ));
        }
        *held += 1;
        drop(state);
        Ok(SessionPermit {
            provider,
            inner: Arc::clone(&self.inner),
        })
    }

    /// Admits one automated prompt for the provider of `run` and `session`, or refuses. A refusal records nothing.
    ///
    /// Taking the open [`RunGuard`] and the [`SessionPermit`] makes both a compile-time requirement; they must be for
    /// the same provider and come from this instance, or the call is refused. This is still only one of the checks of a
    /// dispatch: the caller must also reserve a turn with [`record_turn`](Self::record_turn). The caller must persist
    /// ([`snapshot`](Self::snapshot)) BEFORE it dispatches the prompt, so a crash after dispatch cannot lose the count.
    pub fn admit_prompt(
        &self,
        run: &RunGuard,
        session: &SessionPermit,
        task_id: &str,
    ) -> Result<(), Refusal> {
        let provider = self.coupled_provider(run, session)?;
        let limits = self.inner.limits;
        let mut state = self.lock();
        let tick = state.tick(&*self.inner.clock);
        hold_check(&mut state, provider, tick, &limits)?;

        let window = state.prompts.entry(provider).or_default();
        prune(window, tick.now);
        let cap = to_len(limits.prompts_per_hour());
        if window.len() >= cap {
            // The entry whose expiry first leaves room for one more prompt.
            let blocking = window.len() - cap;
            let retry_at = window
                .get(blocking)
                .map(|r| r.at + TimeDelta::minutes(WINDOW_MINUTES));
            return Err(Refusal::rule1(
                CeilingKind::PromptsPerHour,
                format!(
                    "{provider} has used {} automated prompts in the last hour",
                    limits.prompts_per_hour()
                ),
                retry_at,
            ));
        }
        window.push_back(PromptRecord {
            at: tick.now,
            task_id: task_id.to_owned(),
        });
        Ok(())
    }

    /// Counts one turn of `task_id` run on the provider of `run` and `session`, and returns the new count. Like
    /// [`admit_prompt`](Self::admit_prompt) it needs the open run and the session permit (same provider, this instance).
    /// Refused at the per-task ceiling and whenever [`must_pause`](Self::must_pause) is true for the provider. A refusal
    /// counts nothing.
    pub fn record_turn(
        &self,
        run: &RunGuard,
        session: &SessionPermit,
        task_id: &str,
    ) -> Result<u32, Refusal> {
        let provider = self.coupled_provider(run, session)?;
        let limits = self.inner.limits;
        let mut state = self.lock();
        let tick = state.tick(&*self.inner.clock);
        hold_check(&mut state, provider, tick, &limits)?;
        let limit = limits.turns_per_task();
        let used = state.turns.entry(task_id.to_owned()).or_insert(0);
        if *used >= limit {
            return Err(Refusal::rule1(
                CeilingKind::TurnsPerTask,
                format!("A task may take at most {limit} turns"),
                None,
            ));
        }
        *used += 1;
        Ok(*used)
    }

    /// Opens one automated run for `provider`. The run counts against the day's run time until the returned guard is
    /// dropped. Each open run counts separately: two overlapping one-hour runs use two hours. Refused when the day's run
    /// time is used up or presence is not good.
    pub fn run_started(&self, provider: ProviderId) -> Result<RunGuard, Refusal> {
        let limits = self.inner.limits;
        let mut state = self.lock();
        let tick = state.tick(&*self.inner.clock);
        hold_check(&mut state, provider, tick, &limits)?;
        state.run(provider, tick).open();
        drop(state);
        Ok(RunGuard {
            provider,
            inner: Arc::clone(&self.inner),
        })
    }

    /// Why automation for `provider` must stop now, if it must: the day's run budget is used up, or presence is
    /// missing, stale, idle or in the background. Poll this while a run is active.
    pub fn pause_reason(&self, provider: ProviderId) -> Option<Refusal> {
        let limits = self.inner.limits;
        let mut state = self.lock();
        let tick = state.tick(&*self.inner.clock);
        hold_check(&mut state, provider, tick, &limits).err()
    }

    /// True when automation for `provider` must stop: see [`pause_reason`](Self::pause_reason). Callers with an active run
    /// must poll this, because a run that passes the budget is otherwise only stopped at the next admission.
    pub fn must_pause(&self, provider: ProviderId) -> bool {
        self.pause_reason(provider).is_some()
    }

    /// Meters for one provider as of now.
    pub fn meters(&self, provider: ProviderId) -> ProviderMeters {
        let limits = self.inner.limits;
        let mut state = self.lock();
        let tick = state.tick(&*self.inner.clock);
        let sessions = state.sessions.get(&provider).copied().unwrap_or(0);
        let prompts = state.prompts.entry(provider).or_default();
        prune(prompts, tick.now);
        let prompts = to_u32(prompts.len());
        let run_minutes = state.run(provider, tick).used.as_secs() / 60;
        ProviderMeters {
            sessions: Meter {
                current: sessions,
                limit: limits.concurrent_sessions(),
                ceiling: crate::compliance::ceilings::MAX_CONCURRENT_SESSIONS,
            },
            prompts_last_hour: Meter {
                current: prompts,
                limit: limits.prompts_per_hour(),
                ceiling: crate::compliance::ceilings::MAX_PROMPTS_PER_HOUR,
            },
            run_minutes_today: Meter {
                current: u32::try_from(run_minutes).unwrap_or(u32::MAX),
                limit: limits.run_minutes_per_day(),
                ceiling: crate::compliance::ceilings::MAX_RUN_MINUTES_PER_DAY,
            },
        }
    }

    /// Turn meter for one task.
    pub fn task_turns(&self, task_id: &str) -> Meter {
        let state = self.lock();
        Meter {
            current: state.turns.get(task_id).copied().unwrap_or(0),
            limit: self.inner.limits.turns_per_task(),
            ceiling: crate::compliance::ceilings::MAX_TURNS_PER_TASK,
        }
    }

    /// Everything the usage store needs to persist, including the live stretch of any active run.
    pub fn snapshot(&self) -> LimitsSnapshot {
        let mut state = self.lock();
        let tick = state.tick(&*self.inner.clock);
        let mut out = LimitsSnapshot::default();
        for (provider, window) in &mut state.prompts {
            prune(window, tick.now);
            if !window.is_empty() {
                out.prompts
                    .insert(*provider, window.iter().cloned().collect());
            }
        }
        out.turns = state.turns.iter().map(|(k, v)| (k.clone(), *v)).collect();
        out.anchor = Some(ClockAnchor {
            boot_id: self.inner.clock.boot_id(),
            mono: tick.mono,
            wall: tick.now,
        });
        for (provider, run) in &mut state.runs {
            run.settle(tick);
            out.run.insert(
                *provider,
                RunDay {
                    day: run.day,
                    seconds: run.used.as_secs() + u64::from(run.used.subsec_nanos() > 0),
                },
            );
        }
        out
    }

    /// Merges a persisted snapshot into the counters. Loading can only raise a counter: prompts are unioned, turns and
    /// run time take the larger value, and run time from an earlier day is ignored. A saved day later than the current
    /// one (the system date moved back, or a previous run was ahead) is kept with its usage, never discarded. A stale or
    /// empty snapshot therefore never resets anything (rule 2).
    pub fn load(&self, snapshot: &LimitsSnapshot) {
        let mut state = self.lock();
        let mut tick = state.tick(&*self.inner.clock);
        if let Some(expected) = self.proven_now(snapshot, tick) {
            if (tick.now - expected).abs() > CLOCK_TOLERANCE {
                // The system date was changed since the snapshot was written: trust the proven time instead.
                if let Some(timeline) = state.timeline.as_mut() {
                    timeline.reanchor(expected, tick.mono);
                }
                tick = state.tick(&*self.inner.clock);
            }
        }
        for (provider, records) in &snapshot.prompts {
            let window = state.prompts.entry(*provider).or_default();
            // Multiset union: identical records at one instant are distinct prompts, so add only the surplus.
            let mut remaining: Vec<&PromptRecord> = records.iter().collect();
            for held in window.iter() {
                if let Some(i) = remaining.iter().position(|r| *r == held) {
                    remaining.swap_remove(i);
                }
            }
            window.extend(remaining.into_iter().cloned());
            window.make_contiguous().sort_by_key(|r| r.at);
            prune(window, tick.now);
        }
        for (task, count) in &snapshot.turns {
            let used = state.turns.entry(task.clone()).or_insert(0);
            *used = (*used).max(*count);
        }
        for (provider, saved) in &snapshot.run {
            let run = state.run(*provider, tick);
            if saved.day >= run.day {
                run.day = saved.day;
                run.used = run.used.max(Duration::from_secs(saved.seconds));
            }
        }
    }

    /// The time a snapshot proves it is now: its saved time plus the real time since, valid only when it was saved in
    /// this same boot (equal, known boot ids), when the monotonic clock is comparable. Across a reboot, or with an
    /// unknown boot id, nothing can be proven and this is `None`; the wall clock is used and `load` still never lowers
    /// a counter. Residual (documented in the handoff): a reboot plus a date change can still expire old entries.
    fn proven_now(&self, snapshot: &LimitsSnapshot, tick: Tick) -> Option<DateTime<Utc>> {
        let saved = snapshot.anchor.as_ref()?;
        let saved_boot = saved.boot_id.as_ref()?;
        if self.inner.clock.boot_id().as_ref() != Some(saved_boot) || tick.mono < saved.mono {
            return None;
        }
        let real = TimeDelta::from_std(tick.mono - saved.mono).ok()?;
        saved.wall.checked_add_signed(real)
    }

    /// The provider shared by `run` and `session`, if both belong to this instance and agree.
    fn coupled_provider(
        &self,
        run: &RunGuard,
        session: &SessionPermit,
    ) -> Result<ProviderId, Refusal> {
        let ours = Arc::ptr_eq(&run.inner, &self.inner) && Arc::ptr_eq(&session.inner, &self.inner);
        if !ours || run.provider != session.provider {
            return Err(Refusal::rule1(
                CeilingKind::DispatchNotCoupled,
                "A dispatch needs an open run and a session permit for the same provider",
                None,
            ));
        }
        Ok(run.provider)
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.inner.state.lock().unwrap_or_else(|p| p.into_inner())
    }
}

/// One held concurrent-session slot. Dropping it releases the slot, also while a panic unwinds.
#[must_use = "dropping the permit releases the session slot immediately"]
pub struct SessionPermit {
    provider: ProviderId,
    inner: Arc<Inner>,
}

impl SessionPermit {
    pub fn provider(&self) -> ProviderId {
        self.provider
    }
}

impl std::fmt::Debug for SessionPermit {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SessionPermit")
            .field("provider", &self.provider)
            .finish()
    }
}

impl Drop for SessionPermit {
    fn drop(&mut self) {
        let mut state = self.inner.state.lock().unwrap_or_else(|p| p.into_inner());
        if let Some(held) = state.sessions.get_mut(&self.provider) {
            *held = held.saturating_sub(1);
        }
    }
}

/// One open automated run. Its elapsed time counts against the day's run budget until it is dropped, also while a
/// panic unwinds. There is no separate stop call, so an extra or missing stop cannot make the count drift.
#[must_use = "dropping the guard ends the run immediately"]
pub struct RunGuard {
    provider: ProviderId,
    inner: Arc<Inner>,
}

impl RunGuard {
    pub fn provider(&self) -> ProviderId {
        self.provider
    }
}

impl std::fmt::Debug for RunGuard {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("RunGuard")
            .field("provider", &self.provider)
            .finish()
    }
}

impl Drop for RunGuard {
    fn drop(&mut self) {
        let mut state = self.inner.state.lock().unwrap_or_else(|p| p.into_inner());
        let tick = state.tick(&*self.inner.clock);
        let run = state.run(self.provider, tick);
        run.close();
    }
}

/// Presence and run-budget checks shared by admission, run start, turn counting and the pause poll.
fn hold_check(
    state: &mut State,
    provider: ProviderId,
    tick: Tick,
    limits: &EffectiveLimits,
) -> Result<(), Refusal> {
    presence_check(state.presence.as_ref(), tick.mono, limits)?;
    let budget = Duration::from_secs(u64::from(limits.run_minutes_per_day()) * 60);
    let run = state.run(provider, tick);
    if run.used >= budget {
        let retry_at = run
            .day
            .succ_opt()
            .map(|d| d.and_time(NaiveTime::MIN).and_utc());
        return Err(Refusal::rule1(
            CeilingKind::RunMinutesPerDay,
            format!(
                "{provider} has used its {} minutes of automated run time today",
                limits.run_minutes_per_day()
            ),
            retry_at,
        ));
    }
    Ok(())
}

fn presence_check(
    report: Option<&PresenceReport>,
    mono: Duration,
    limits: &EffectiveLimits,
) -> Result<(), Refusal> {
    let Some(report) = report else {
        return Err(Refusal::rule1(
            CeilingKind::PresenceUnknown,
            "Automation waits until the app reports that the user is present",
            None,
        ));
    };
    if report.presence.app_in_background {
        return Err(Refusal::rule1(
            CeilingKind::AppBackground,
            "Automation pauses while the app is in the background",
            None,
        ));
    }
    if mono.saturating_sub(report.at) >= PRESENCE_MAX_AGE {
        return Err(Refusal::rule1(
            CeilingKind::UserIdle,
            "Automation pauses because the app's last presence report is out of date",
            None,
        ));
    }
    // Idle time keeps growing after the report: reported idle plus the monotonic time since it was reported.
    let idle_limit = limits.idle_pause_minutes();
    let idle_now = Duration::from_secs(u64::from(report.presence.idle_minutes) * 60)
        .saturating_add(mono.saturating_sub(report.at));
    if idle_now >= Duration::from_secs(u64::from(idle_limit) * 60) {
        return Err(Refusal::rule1(
            CeilingKind::UserIdle,
            format!("Automation pauses after {idle_limit} minutes without the user present"),
            None,
        ));
    }
    Ok(())
}

fn prune(window: &mut VecDeque<PromptRecord>, now: DateTime<Utc>) {
    let cutoff = now - TimeDelta::minutes(WINDOW_MINUTES);
    while window.front().is_some_and(|r| r.at <= cutoff) {
        window.pop_front();
    }
}

fn to_len(n: u32) -> usize {
    usize::try_from(n).unwrap_or(usize::MAX)
}

fn to_u32(n: usize) -> u32 {
    u32::try_from(n).unwrap_or(u32::MAX)
}
