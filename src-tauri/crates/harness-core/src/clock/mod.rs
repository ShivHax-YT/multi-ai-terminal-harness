//! The one injectable clock (T-111).
//!
//! Every time-dependent rule (rolling windows, daily counters, idle checks, pacing) reads time through [`Clock`] so a
//! simulated clock can drive a 24-hour run in milliseconds. Outside [`SystemClock`], no code in this crate reads the
//! operating system clock directly.

mod system;
pub use system::SystemClock;

#[cfg(any(test, feature = "sim"))]
mod sim;
#[cfg(any(test, feature = "sim"))]
pub use sim::SimClock;

use chrono::{DateTime, Utc};
use std::sync::Arc;
use std::time::Duration;

/// A source of wall-clock and monotonic time.
pub trait Clock: Send + Sync {
    /// Current wall-clock time in UTC. May jump if the user changes the system time.
    fn now(&self) -> DateTime<Utc>;
    /// Time since an arbitrary fixed origin. Never goes backwards; use it for elapsed-time measurements.
    fn monotonic(&self) -> Duration;
}

impl<C: Clock + ?Sized> Clock for Arc<C> {
    fn now(&self) -> DateTime<Utc> {
        (**self).now()
    }
    fn monotonic(&self) -> Duration {
        (**self).monotonic()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn start() -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 10, 29, 12, 0, 0).unwrap()
    }

    #[test]
    fn sim_clock_starts_where_told() {
        let clock = SimClock::new(start());
        assert_eq!(clock.now(), start());
        assert_eq!(clock.monotonic(), Duration::ZERO);
    }

    #[test]
    fn sim_clock_moves_only_when_advanced() {
        let clock = SimClock::new(start());
        let first = clock.now();
        assert_eq!(clock.now(), first, "reading twice must not move time");
        clock.advance(Duration::from_secs(90));
        assert_eq!(clock.now(), start() + chrono::Duration::seconds(90));
        assert_eq!(clock.monotonic(), Duration::from_secs(90));
        clock.advance(Duration::from_millis(500));
        assert_eq!(clock.monotonic(), Duration::from_millis(90_500));
    }

    #[test]
    fn sim_clock_clones_share_time() {
        let clock = SimClock::new(start());
        let other = clock.clone();
        clock.advance(Duration::from_secs(60));
        assert_eq!(other.now(), clock.now());
    }

    #[test]
    fn sim_clock_works_behind_a_trait_object() {
        let sim = SimClock::new(start());
        let dynamic: Arc<dyn Clock> = Arc::new(sim.clone());
        sim.advance(Duration::from_secs(5));
        assert_eq!(dynamic.monotonic(), Duration::from_secs(5));
    }

    #[test]
    fn wall_jumps_move_now_but_not_monotonic() {
        let clock = SimClock::new(start());
        clock.advance(Duration::from_secs(60));
        clock.jump_wall_forward(Duration::from_secs(3600));
        assert_eq!(clock.now(), start() + chrono::Duration::seconds(3660));
        assert_eq!(clock.monotonic(), Duration::from_secs(60));
        clock.jump_wall_back(Duration::from_secs(7200));
        assert_eq!(clock.now(), start() + chrono::Duration::seconds(-3540));
        assert_eq!(clock.monotonic(), Duration::from_secs(60));
        clock.advance(Duration::from_secs(10));
        assert_eq!(clock.now(), start() + chrono::Duration::seconds(-3530));
    }
}
