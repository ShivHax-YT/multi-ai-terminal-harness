//! The real clock. The only file in the crate allowed to read the operating system clock.

use super::Clock;
use chrono::{DateTime, Utc};
use std::time::{Duration, Instant};

/// Reads the operating system clocks.
///
/// On macOS the monotonic reading keeps counting while the machine sleeps, so a sleep is not mistaken for a clock jump.
/// Elsewhere it is the standard library's monotonic clock.
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
        #[cfg(target_os = "macos")]
        if let Some(d) = continuous_monotonic() {
            return d;
        }
        self.origin.elapsed()
    }
}

/// `CLOCK_MONOTONIC` on macOS counts sleep time, unlike `Instant`.
#[cfg(target_os = "macos")]
fn continuous_monotonic() -> Option<Duration> {
    let mut ts = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    // SAFETY: `ts` is a valid, writable timespec for the duration of the call.
    let rc = unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut ts) };
    if rc != 0 {
        return None;
    }
    let secs = u64::try_from(ts.tv_sec).ok()?;
    let nanos = u32::try_from(ts.tv_nsec).ok()?;
    Some(Duration::new(secs, nanos))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn monotonic_never_goes_backwards() {
        let clock = SystemClock::new();
        let mut last = clock.monotonic();
        for _ in 0..1000 {
            let next = clock.monotonic();
            assert!(next >= last);
            last = next;
        }
    }

    #[test]
    fn wall_clock_is_close_to_utc() {
        let clock = SystemClock::new();
        let drift = (clock.now() - Utc::now()).num_seconds().abs();
        assert!(drift < 5);
    }
}
