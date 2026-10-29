//! The real clock. The only file in the crate allowed to read the operating system clock.

use super::Clock;
use chrono::{DateTime, Utc};
use std::time::{Duration, Instant};

/// Reads the operating system clocks.
#[derive(Debug, Clone, Copy)]
pub struct SystemClock {
    origin: Instant,
}

impl SystemClock {
    pub fn new() -> Self {
        Self {
            origin: Instant::now(),
        }
    }
}

impl Default for SystemClock {
    fn default() -> Self {
        Self::new()
    }
}

impl Clock for SystemClock {
    fn now(&self) -> DateTime<Utc> {
        Utc::now()
    }

    fn monotonic(&self) -> Duration {
        self.origin.elapsed()
    }
}
