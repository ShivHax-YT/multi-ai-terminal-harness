//! The time this module trusts.
//!
//! The wall clock can be set by the user, so it is read once, to anchor the timeline. After that, time moves with the
//! monotonic clock only: a forward jump of the system date cannot roll the day or age out the prompt window early, and
//! a backward jump cannot reduce counted run time. (On macOS the monotonic clock keeps counting while the machine is
//! suspended, so a suspend is not mistaken for a jump.) The day key and the timestamps in the prompt window come from this timeline.

use crate::clock::Clock;
use chrono::{DateTime, TimeDelta, Utc};
use std::time::Duration;

/// One reading: trusted UTC time and the monotonic reading it came from.
#[derive(Debug, Clone, Copy)]
pub(super) struct Tick {
    pub now: DateTime<Utc>,
    pub mono: Duration,
}

#[derive(Debug, Clone, Copy)]
pub(super) struct Timeline {
    anchor_wall: DateTime<Utc>,
    anchor_mono: Duration,
    last_mono: Duration,
}

impl Timeline {
    pub(super) fn anchored(clock: &dyn Clock) -> Self {
        let mono = clock.monotonic();
        Self {
            anchor_wall: clock.now(),
            anchor_mono: mono,
            last_mono: mono,
        }
    }

    /// Reads the monotonic clock and returns trusted time. Never goes backwards.
    pub(super) fn tick(&mut self, clock: &dyn Clock) -> Tick {
        let mono = clock.monotonic().max(self.last_mono);
        self.last_mono = mono;
        let elapsed = mono.saturating_sub(self.anchor_mono);
        let delta = TimeDelta::from_std(elapsed).unwrap_or(TimeDelta::MAX);
        let now = self
            .anchor_wall
            .checked_add_signed(delta)
            .unwrap_or(self.anchor_wall);
        Tick { now, mono }
    }
}
