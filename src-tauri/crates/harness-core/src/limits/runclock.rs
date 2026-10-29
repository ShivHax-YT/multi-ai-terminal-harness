//! Daily automated run time for one provider, counted per run.

use super::timeline::Tick;
use chrono::{NaiveDate, NaiveTime};
use std::time::Duration;

/// Every active run adds its own elapsed time, so two overlapping runs for an hour use two hours of the day's budget.
/// Time accrues as an exact [`Duration`], so any number of very short runs add up with nothing rounded away.
#[derive(Debug)]
pub(super) struct RunClock {
    pub(super) day: NaiveDate,
    pub(super) used: Duration,
    active: u32,
    last_mono: Duration,
}

impl RunClock {
    pub(super) fn new(tick: Tick) -> Self {
        Self {
            day: tick.now.date_naive(),
            used: Duration::ZERO,
            active: 0,
            last_mono: tick.mono,
        }
    }

    /// Brings the counter up to `tick`: accrues elapsed monotonic time for each active run, then rolls to a later UTC
    /// day. The day never moves backwards, and a stretch that crosses midnight counts only its part after midnight.
    pub(super) fn settle(&mut self, tick: Tick) {
        let elapsed = tick.mono.saturating_sub(self.last_mono);
        self.last_mono = self.last_mono.max(tick.mono);

        let today = tick.now.date_naive();
        if today > self.day {
            let since_midnight = (tick.now - today.and_time(NaiveTime::MIN).and_utc())
                .to_std()
                .unwrap_or(Duration::ZERO);
            self.day = today;
            self.used = elapsed.min(since_midnight).saturating_mul(self.active);
        } else {
            self.used = self
                .used
                .saturating_add(elapsed.saturating_mul(self.active));
        }
    }

    pub(super) fn open(&mut self) {
        self.active = self.active.saturating_add(1);
    }

    pub(super) fn close(&mut self) {
        self.active = self.active.saturating_sub(1);
    }
}
