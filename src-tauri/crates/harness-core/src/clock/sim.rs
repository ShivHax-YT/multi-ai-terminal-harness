//! A simulated clock that moves only when a test advances it.

use super::Clock;
use chrono::{DateTime, TimeDelta, Utc};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

#[derive(Debug, Default)]
struct Timeline {
    /// Real elapsed time: drives both readings.
    elapsed: Duration,
    /// How far the wall clock has been moved away from real time (the user changing the system date).
    wall_shift: TimeDelta,
}

/// Deterministic clock for tests and the 24-hour simulation. Clones share one timeline.
#[derive(Debug, Clone)]
pub struct SimClock {
    start: DateTime<Utc>,
    timeline: Arc<Mutex<Timeline>>,
}

impl SimClock {
    pub fn new(start: DateTime<Utc>) -> Self {
        Self {
            start,
            timeline: Arc::new(Mutex::new(Timeline::default())),
        }
    }

    /// Moves real time forward: both the wall clock and the monotonic clock advance. There is no way to move it back.
    pub fn advance(&self, by: Duration) {
        let mut t = self.lock();
        t.elapsed = t.elapsed.saturating_add(by);
    }

    /// Simulates the user setting the system date forward. The monotonic clock does not move.
    pub fn jump_wall_forward(&self, by: Duration) {
        let mut t = self.lock();
        let by = TimeDelta::from_std(by).unwrap_or(TimeDelta::MAX);
        t.wall_shift = t.wall_shift.checked_add(&by).unwrap_or(t.wall_shift);
    }

    /// Simulates the user setting the system date backward. The monotonic clock does not move.
    pub fn jump_wall_back(&self, by: Duration) {
        let mut t = self.lock();
        let by = TimeDelta::from_std(by).unwrap_or(TimeDelta::MAX);
        t.wall_shift = t.wall_shift.checked_sub(&by).unwrap_or(t.wall_shift);
    }

    fn lock(&self) -> MutexGuard<'_, Timeline> {
        self.timeline.lock().unwrap_or_else(|p| p.into_inner())
    }
}

impl Clock for SimClock {
    fn now(&self) -> DateTime<Utc> {
        let t = self.lock();
        let real = TimeDelta::from_std(t.elapsed).unwrap_or(TimeDelta::MAX);
        let delta = real.checked_add(&t.wall_shift).unwrap_or(real);
        self.start.checked_add_signed(delta).unwrap_or(self.start)
    }

    fn monotonic(&self) -> Duration {
        self.lock().elapsed
    }
}
