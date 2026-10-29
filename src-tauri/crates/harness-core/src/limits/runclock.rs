//! Daily automated run time for one provider, counted per run.

use super::timeline::Tick;
use chrono::{NaiveDate, NaiveTime};
use std::time::Duration;

/// Every active run adds its own elapsed time, so two overlapping runs for an hour use two hours of the day's budget.
/// Time accrues in whole milliseconds with the sub-millisecond remainder carried, so many short runs add up.
#[derive(Debug)]
pub(super) struct RunClock {
    pub(super) day: NaiveDate,
    pub(super) used_ms: u64,
    active: u32,
    last_mono: Duration,
}

impl RunClock {
    pub(super) fn new(tick: Tick) -> Self {
        Self {
            day: tick.now.date_naive(),
            used_ms: 0,
            active: 0,
            last_mono: tick.mono,
        }
    }

    /// Brings the counter up to `tick`: accrues elapsed monotonic time for each active run, then rolls to a later UTC
    /// day. The day never moves backwards, and a stretch that crosses midnight counts only its part after midnight.
    pub(super) fn settle(&mut self, tick: Tick) {
        let elapsed = tick.mono.saturating_sub(self.last_mono);
        let whole_ms = u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX);
        if self.active == 0 {
            self.last_mono = tick.mono;
        } else {
            self.last_mono += Duration::from_millis(whole_ms);
        }
        let runs = u64::from(self.active);

        let today = tick.now.date_naive();
        if today > self.day {
            let since_midnight = (tick.now - today.and_time(NaiveTime::MIN).and_utc())
                .num_milliseconds()
                .max(0);
            let since_midnight = u64::try_from(since_midnight).unwrap_or(0);
            self.day = today;
            self.used_ms = runs.saturating_mul(whole_ms.min(since_midnight));
        } else {
            self.used_ms = self.used_ms.saturating_add(runs.saturating_mul(whole_ms));
        }
    }

    pub(super) fn open(&mut self) {
        self.active = self.active.saturating_add(1);
    }

    pub(super) fn close(&mut self) {
        self.active = self.active.saturating_sub(1);
    }
}
