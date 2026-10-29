//! In-memory enforcement of the rule 1 ceilings, driven by an injected clock.
//!
//! All state is per provider (or per task id for turns). Nothing here keys on an account, profile or session, and there
//! is no function that lowers a counter other than the natural aging of the rolling window and the UTC-midnight roll of
//! the daily run counter (rule 2).

use super::config::{EffectiveLimits, UserLimits};
use super::presence::Presence;
use super::provider::ProviderId;
use super::refusal::{CeilingKind, Refusal};
use crate::clock::Clock;
use chrono::{DateTime, NaiveDate, NaiveTime, TimeDelta, Utc};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap, VecDeque};
use std::sync::{Arc, Mutex, MutexGuard};

const WINDOW_MINUTES: i64 = 60;

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

/// Automated run seconds used on one UTC day.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct RunDay {
    pub day: NaiveDate,
    pub seconds: u64,
}

/// What the usage store persists (T-112): enough to rebuild every counter after a restart. Sessions are not included
/// because permits die with the process.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct LimitsSnapshot {
    pub prompts: BTreeMap<ProviderId, Vec<PromptRecord>>,
    pub turns: BTreeMap<String, u32>,
    pub run: BTreeMap<ProviderId, RunDay>,
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
    presence: Presence,
    sessions: HashMap<ProviderId, u32>,
    prompts: HashMap<ProviderId, VecDeque<PromptRecord>>,
    turns: HashMap<String, u32>,
    runs: HashMap<ProviderId, RunClock>,
}

/// Daily automated run time for one provider. Time accrues as wall-clock while at least one run is active, so two
/// overlapping runs do not count twice.
struct RunClock {
    day: NaiveDate,
    closed_secs: u64,
    active: u32,
    since: Option<DateTime<Utc>>,
}

impl RunClock {
    fn new(day: NaiveDate) -> Self {
        Self {
            day,
            closed_secs: 0,
            active: 0,
            since: None,
        }
    }

    /// Rolls to a later UTC day. A clock that moves backwards never rolls, so it cannot be used to reset the counter.
    fn roll(&mut self, now: DateTime<Utc>) {
        let today = now.date_naive();
        if today > self.day {
            self.day = today;
            self.closed_secs = 0;
            if self.active > 0 {
                self.since = Some(today.and_time(NaiveTime::MIN).and_utc());
            }
        }
    }

    fn used_secs(&self, now: DateTime<Utc>) -> u64 {
        let live = self
            .since
            .map_or(0, |s| u64::try_from((now - s).num_seconds()).unwrap_or(0));
        self.closed_secs.saturating_add(live)
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

    /// Records what the app reports about the user. Presence is never inferred here.
    pub fn set_presence(&self, presence: Presence) {
        self.lock().presence = presence;
    }

    pub fn presence(&self) -> Presence {
        self.lock().presence
    }

    /// Takes one concurrent-session slot for `provider`; dropping the permit frees it.
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

    /// Admits one automated prompt, or refuses. A refusal records nothing.
    pub fn admit_prompt(&self, provider: ProviderId, task_id: &str) -> Result<(), Refusal> {
        let now = self.inner.clock.now();
        let limits = self.inner.limits;
        let mut state = self.lock();
        presence_check(&state.presence, &limits)?;
        run_budget_check(&mut state, provider, now, &limits)?;

        let window = state.prompts.entry(provider).or_default();
        prune(window, now);
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
            at: now,
            task_id: task_id.to_owned(),
        });
        Ok(())
    }

    /// Counts one turn for `task_id` and returns the new count, or refuses at the per-task ceiling.
    pub fn record_turn(&self, task_id: &str) -> Result<u32, Refusal> {
        let limit = self.inner.limits.turns_per_task();
        let mut state = self.lock();
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

    /// Marks an automated run as active for `provider`. Refused when the day's run time is used up or the user is away.
    pub fn run_started(&self, provider: ProviderId) -> Result<(), Refusal> {
        let now = self.inner.clock.now();
        let limits = self.inner.limits;
        let mut state = self.lock();
        presence_check(&state.presence, &limits)?;
        run_budget_check(&mut state, provider, now, &limits)?;
        let run = run_clock(&mut state, provider, now);
        if run.active == 0 {
            run.since = Some(now);
        }
        run.active += 1;
        Ok(())
    }

    /// Marks an automated run as finished. Does nothing when no run is active.
    pub fn run_stopped(&self, provider: ProviderId) {
        let now = self.inner.clock.now();
        let mut state = self.lock();
        let run = run_clock(&mut state, provider, now);
        if run.active == 0 {
            return;
        }
        run.active -= 1;
        if run.active == 0 {
            run.closed_secs = run.used_secs(now);
            run.since = None;
        }
    }

    /// Meters for one provider as of now.
    pub fn meters(&self, provider: ProviderId) -> ProviderMeters {
        let now = self.inner.clock.now();
        let limits = self.inner.limits;
        let mut state = self.lock();
        let sessions = state.sessions.get(&provider).copied().unwrap_or(0);
        let prompts = state.prompts.entry(provider).or_default();
        prune(prompts, now);
        let prompts = to_u32(prompts.len());
        let run_secs = run_clock(&mut state, provider, now).used_secs(now);
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
                current: to_u32(usize::try_from(run_secs / 60).unwrap_or(usize::MAX)),
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

    /// Everything the usage store needs to persist.
    pub fn snapshot(&self) -> LimitsSnapshot {
        let now = self.inner.clock.now();
        let mut state = self.lock();
        let mut out = LimitsSnapshot::default();
        for (provider, window) in &mut state.prompts {
            prune(window, now);
            if !window.is_empty() {
                out.prompts
                    .insert(*provider, window.iter().cloned().collect());
            }
        }
        out.turns = state.turns.iter().map(|(k, v)| (k.clone(), *v)).collect();
        for (provider, run) in &mut state.runs {
            run.roll(now);
            out.run.insert(
                *provider,
                RunDay {
                    day: run.day,
                    seconds: run.used_secs(now),
                },
            );
        }
        out
    }

    /// Merges a persisted snapshot into the counters. Loading can only raise a counter: prompts are unioned, turns and
    /// run seconds take the larger value, and run seconds from an earlier day are ignored. A stale or empty snapshot
    /// therefore never resets anything (rule 2).
    pub fn load(&self, snapshot: &LimitsSnapshot) {
        let now = self.inner.clock.now();
        let mut state = self.lock();
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
            prune(window, now);
        }
        for (task, count) in &snapshot.turns {
            let used = state.turns.entry(task.clone()).or_insert(0);
            *used = (*used).max(*count);
        }
        for (provider, saved) in &snapshot.run {
            let run = run_clock(&mut state, *provider, now);
            if saved.day == run.day {
                let used = run.used_secs(now);
                if saved.seconds > used {
                    run.closed_secs = run.closed_secs.saturating_add(saved.seconds - used);
                }
            }
        }
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.inner.state.lock().unwrap_or_else(|p| p.into_inner())
    }
}

/// One held concurrent-session slot. Dropping it releases the slot.
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

fn presence_check(presence: &Presence, limits: &EffectiveLimits) -> Result<(), Refusal> {
    if presence.app_in_background {
        return Err(Refusal::rule1(
            CeilingKind::AppBackground,
            "Automation pauses while the app is in the background",
            None,
        ));
    }
    let idle_limit = limits.idle_pause_minutes();
    if presence.idle_minutes >= idle_limit {
        return Err(Refusal::rule1(
            CeilingKind::UserIdle,
            format!("Automation pauses after {idle_limit} minutes without the user present"),
            None,
        ));
    }
    Ok(())
}

fn run_budget_check(
    state: &mut State,
    provider: ProviderId,
    now: DateTime<Utc>,
    limits: &EffectiveLimits,
) -> Result<(), Refusal> {
    let budget_secs = u64::from(limits.run_minutes_per_day()) * 60;
    let run = run_clock(state, provider, now);
    if run.used_secs(now) >= budget_secs {
        return Err(Refusal::rule1(
            CeilingKind::RunMinutesPerDay,
            format!(
                "{provider} has used its {} minutes of automated run time today",
                limits.run_minutes_per_day()
            ),
            Some(next_utc_midnight(now)),
        ));
    }
    Ok(())
}

/// The run clock for `provider`, rolled to today.
fn run_clock(state: &mut State, provider: ProviderId, now: DateTime<Utc>) -> &mut RunClock {
    let run = state
        .runs
        .entry(provider)
        .or_insert_with(|| RunClock::new(now.date_naive()));
    run.roll(now);
    run
}

fn prune(window: &mut VecDeque<PromptRecord>, now: DateTime<Utc>) {
    let cutoff = now - TimeDelta::minutes(WINDOW_MINUTES);
    while window.front().is_some_and(|r| r.at <= cutoff) {
        window.pop_front();
    }
}

fn next_utc_midnight(now: DateTime<Utc>) -> DateTime<Utc> {
    now.date_naive()
        .succ_opt()
        .map_or(now + TimeDelta::hours(24), |d| {
            d.and_time(NaiveTime::MIN).and_utc()
        })
}

fn to_len(n: u32) -> usize {
    usize::try_from(n).unwrap_or(usize::MAX)
}

fn to_u32(n: usize) -> u32 {
    u32::try_from(n).unwrap_or(u32::MAX)
}
