//! A simulated clock that moves only when a test advances it.

use super::Clock;
use chrono::{DateTime, TimeDelta, Utc};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

/// Deterministic clock for tests and the 24-hour simulation. Clones share one timeline.
#[derive(Debug, Clone)]
pub struct SimClock {
    start: DateTime<Utc>,
    elapsed: Arc<Mutex<Duration>>,
}

impl SimClock {
    pub fn new(start: DateTime<Utc>) -> Self {
        Self {
            start,
            elapsed: Arc::new(Mutex::new(Duration::ZERO)),
        }
    }

    /// Moves time forward. There is no way to move it back.
    pub fn advance(&self, by: Duration) {
        let mut elapsed = self.lock();
        *elapsed = elapsed.saturating_add(by);
    }

    fn lock(&self) -> MutexGuard<'_, Duration> {
        self.elapsed.lock().unwrap_or_else(|p| p.into_inner())
    }
}

impl Clock for SimClock {
    fn now(&self) -> DateTime<Utc> {
        let elapsed = *self.lock();
        let delta = TimeDelta::from_std(elapsed).unwrap_or(TimeDelta::MAX);
        self.start.checked_add_signed(delta).unwrap_or(self.start)
    }

    fn monotonic(&self) -> Duration {
        *self.lock()
    }
}
