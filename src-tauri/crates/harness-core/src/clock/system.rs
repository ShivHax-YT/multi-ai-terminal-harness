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

    fn boot_id(&self) -> Option<String> {
        #[cfg(target_os = "macos")]
        {
            boot_session_uuid()
        }
        #[cfg(not(target_os = "macos"))]
        {
            None
        }
    }
}

/// `kern.bootsessionuuid`: a random id per boot that setting the system date does not change (unlike `kern.boottime`,
/// which follows the wall clock).
#[cfg(target_os = "macos")]
fn boot_session_uuid() -> Option<String> {
    let name = c"kern.bootsessionuuid";
    let mut len: libc::size_t = 0;
    // SAFETY: a null output buffer with a valid length pointer asks sysctl for the required size.
    let rc = unsafe {
        libc::sysctlbyname(
            name.as_ptr(),
            std::ptr::null_mut(),
            &mut len,
            std::ptr::null_mut(),
            0,
        )
    };
    if rc != 0 || len == 0 {
        return None;
    }
    let mut buf = vec![0u8; len];
    // SAFETY: `buf` is writable for `len` bytes and `len` is updated to the bytes written.
    let rc = unsafe {
        libc::sysctlbyname(
            name.as_ptr(),
            buf.as_mut_ptr().cast(),
            &mut len,
            std::ptr::null_mut(),
            0,
        )
    };
    if rc != 0 {
        return None;
    }
    buf.truncate(len);
    while buf.last() == Some(&0) {
        buf.pop();
    }
    String::from_utf8(buf).ok().filter(|s| !s.is_empty())
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

    #[cfg(target_os = "macos")]
    #[test]
    fn boot_id_is_known_and_stable_on_macos() {
        let clock = SystemClock::new();
        let first = clock.boot_id();
        assert!(first.is_some());
        assert_eq!(clock.boot_id(), first);
    }

    #[test]
    fn wall_clock_is_close_to_utc() {
        let clock = SystemClock::new();
        let drift = (clock.now() - Utc::now()).num_seconds().abs();
        assert!(drift < 5);
    }
}
