//! Fixed-argument probes launched with Apple's kernel-enforced code requirement.
//! There is no pathname-based verifier subprocess and no candidate-content read.
//! This is an executable identity gate, not a sandbox for provider tools or Git.

use super::{Capture, ProbeError, SignaturePolicy};
use std::ffi::{c_void, CString, OsStr};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

const OUTPUT_LIMIT: usize = 64 * 1024;
static ACTIVE: AtomicBool = AtomicBool::new(false);

extern "C" {
    fn harness_probe_start(
        path: *const libc::c_char,
        home: *const libc::c_char,
        team: *const libc::c_char,
        identifier: *const libc::c_char,
        release_cdhash: *const libc::c_char,
        platform_test: bool,
        argv: *const *const libc::c_char,
        argc: usize,
        stdout: i32,
        stderr: i32,
        stdin: i32,
    ) -> *mut c_void;
    fn harness_probe_poll(handle: *mut c_void, code: *mut i32) -> bool;
    fn harness_probe_cancel(handle: *mut c_void);
    fn harness_probe_wait(handle: *mut c_void);
    fn harness_probe_release(handle: *mut c_void);
}

struct Permit;
impl Drop for Permit {
    fn drop(&mut self) {
        ACTIVE.store(false, Ordering::Release);
    }
}

fn cstring(value: &OsStr) -> Result<CString, ProbeError> {
    CString::new(value.as_bytes()).map_err(|_| ProbeError::Failed)
}

fn pipe() -> Result<(OwnedFd, OwnedFd), ProbeError> {
    let mut fds = [-1; 2];
    // SAFETY: two writable slots; successful descriptors become owned immediately.
    if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
        return Err(ProbeError::Failed);
    }
    // SAFETY: pipe gave us two distinct, owned descriptors.
    let originals = unsafe { [OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])] };
    let duplicate = |fd: &OwnedFd| -> Result<OwnedFd, ProbeError> {
        // Keep pipes clear of stdin/stdout/stderr, even in a GUI process with
        // closed standard descriptors. CLOEXEC is set atomically on duplicates.
        // SAFETY: fd is valid; the returned descriptor is newly owned.
        let dup = unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_DUPFD_CLOEXEC, 3) };
        if dup < 0 {
            return Err(ProbeError::Failed);
        }
        // SAFETY: dup was just created and has no other Rust owner.
        Ok(unsafe { OwnedFd::from_raw_fd(dup) })
    };
    let read = duplicate(&originals[0])?;
    let write = duplicate(&originals[1])?;
    // SAFETY: read is our pipe endpoint, and only its flags are changed.
    if unsafe { libc::fcntl(read.as_raw_fd(), libc::F_SETFL, libc::O_NONBLOCK) } < 0 {
        return Err(ProbeError::Failed);
    }
    Ok((read, write))
}

struct Task {
    handle: usize,
    permit: Option<Permit>,
}
impl Task {
    fn exited(&self) -> Option<i32> {
        let mut code = 0;
        // SAFETY: handle is a retained Foundation Process, exclusively owned here.
        unsafe { harness_probe_poll(self.handle as *mut c_void, &mut code) }.then_some(code)
    }

    fn cancel(&self, reason: ProbeError) -> ProbeError {
        // Foundation owns reaping and cancellation. Never signal a cached PID,
        // which could refer to a different process after an asynchronous reap.
        // SAFETY: this task still owns the retained Process reference.
        unsafe { harness_probe_cancel(self.handle as *mut c_void) };
        let deadline = Instant::now() + Duration::from_secs(2);
        while Instant::now() < deadline {
            if self.exited().is_some() {
                return reason;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        // Do not claim cancellation/timeout cleanup completed if SIGTERM has
        // not stopped the official CLI. The retained reaper also retains its
        // permit, blocking additional probes until actual exit.
        ProbeError::CleanupPending
    }
}

impl Drop for Task {
    fn drop(&mut self) {
        let handle = self.handle;
        if self.exited().is_some() {
            // SAFETY: release the one retained Process reference exactly once.
            unsafe { harness_probe_release(handle as *mut c_void) };
        } else {
            // SAFETY: still owned; public Process API handles its process identity.
            unsafe { harness_probe_cancel(handle as *mut c_void) };
            let permit = self.permit.take();
            // Transfer exclusive ownership to a reaper, without a raw-PID signal.
            std::thread::spawn(move || {
                // SAFETY: this is now the sole owner; Process is NS_SWIFT_SENDABLE.
                unsafe {
                    harness_probe_wait(handle as *mut c_void);
                    harness_probe_release(handle as *mut c_void);
                }
                drop(permit);
            });
        }
    }
}

fn drain(fd: &OwnedFd, bytes: &mut Vec<u8>) -> Result<(), ProbeError> {
    let mut buffer = [0u8; 4096];
    loop {
        // SAFETY: valid nonblocking pipe and a buffer of the requested size.
        let n = unsafe { libc::read(fd.as_raw_fd(), buffer.as_mut_ptr().cast(), buffer.len()) };
        if n > 0 {
            bytes.extend_from_slice(&buffer[..n as usize]);
            if bytes.len() > OUTPUT_LIMIT {
                return Err(ProbeError::OutputLimit);
            }
        } else if n == 0 {
            return Ok(());
        } else {
            match std::io::Error::last_os_error().raw_os_error() {
                Some(libc::EINTR) => continue,
                Some(libc::EAGAIN) => return Ok(()),
                _ => return Err(ProbeError::Failed),
            }
        }
    }
}

pub(super) fn run(
    path: &Path,
    home: &Path,
    policy: SignaturePolicy,
    args: &[&str],
    timeout: Duration,
) -> Result<Capture, ProbeError> {
    run_with_hook(path, home, policy, args, timeout, || {})
}

fn run_with_hook(
    path: &Path,
    home: &Path,
    policy: SignaturePolicy,
    args: &[&str],
    timeout: Duration,
    before_spawn: impl FnOnce(),
) -> Result<Capture, ProbeError> {
    // Status is not inference, but serialize it to bound native subprocess use.
    // A hung cleanup retains this slot; repeated refreshes cannot leak children.
    ACTIVE
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .map_err(|_| ProbeError::CleanupPending)?;
    let permit = Permit;
    if !path.is_absolute() || !home.is_absolute() {
        return Err(ProbeError::Verification);
    }
    let path = cstring(path.as_os_str())?;
    let home = cstring(home.as_os_str())?;
    let team = CString::new(policy.team).map_err(|_| ProbeError::Verification)?;
    let identifier = CString::new(policy.identifier).map_err(|_| ProbeError::Verification)?;
    let release_cdhash =
        CString::new(policy.release_cdhash).map_err(|_| ProbeError::Verification)?;
    let arguments: Vec<CString> = args
        .iter()
        .map(|s| CString::new(*s).map_err(|_| ProbeError::Failed))
        .collect::<Result<_, _>>()?;
    let argv: Vec<_> = arguments.iter().map(|s| s.as_ptr()).collect();
    let (out, out_write) = pipe()?;
    let (err, err_write) = pipe()?;
    before_spawn();
    // SAFETY: strings and arrays live through the synchronous call; the native
    // bridge installs the code requirement BEFORE Process.run. Only inherited
    // pipe descriptors are passed, never handles for candidate file contents.
    let handle = unsafe {
        harness_probe_start(
            path.as_ptr(),
            home.as_ptr(),
            team.as_ptr(),
            identifier.as_ptr(),
            release_cdhash.as_ptr(),
            policy.platform_test,
            argv.as_ptr(),
            argv.len(),
            out_write.as_raw_fd(),
            err_write.as_raw_fd(),
            -1,
        )
    };
    if handle.is_null() {
        return Err(ProbeError::Verification);
    }
    let task = Task {
        handle: handle as usize,
        permit: Some(permit),
    };
    drop(out_write);
    drop(err_write);
    let deadline = Instant::now() + timeout;
    let mut stdout = Vec::new();
    let mut stderr = Vec::new();
    loop {
        if Instant::now() >= deadline {
            return Err(task.cancel(ProbeError::Timeout));
        }
        for (fd, bytes) in [(&out, &mut stdout), (&err, &mut stderr)] {
            if let Err(error) = drain(fd, bytes) {
                return Err(task.cancel(error));
            }
        }
        if stdout.len() + stderr.len() > OUTPUT_LIMIT {
            return Err(task.cancel(ProbeError::OutputLimit));
        }
        if let Some(code) = task.exited() {
            drain(&out, &mut stdout)?;
            drain(&err, &mut stderr)?;
            if stdout.len() + stderr.len() > OUTPUT_LIMIT {
                return Err(ProbeError::OutputLimit);
            }
            if code < 0 {
                return Err(ProbeError::Verification);
            }
            return Ok(Capture {
                code,
                stdout: String::from_utf8(stdout).map_err(|_| ProbeError::Failed)?,
                stderr: String::from_utf8(stderr).map_err(|_| ProbeError::Failed)?,
            });
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}

/// Human-owned Terminal session. The inherited descriptors carry login I/O
/// directly between the CLI and the human; no output bytes enter app buffers.
pub(super) fn terminal_login(
    path: &Path,
    home: &Path,
    policy: SignaturePolicy,
    args: &[&str],
) -> Result<i32, ProbeError> {
    let path = cstring(path.as_os_str())?;
    let home = cstring(home.as_os_str())?;
    let team = CString::new(policy.team).map_err(|_| ProbeError::Verification)?;
    let identifier = CString::new(policy.identifier).map_err(|_| ProbeError::Verification)?;
    let release_cdhash =
        CString::new(policy.release_cdhash).map_err(|_| ProbeError::Verification)?;
    let arguments: Vec<CString> = args
        .iter()
        .map(|s| CString::new(*s).map_err(|_| ProbeError::Failed))
        .collect::<Result<_, _>>()?;
    let argv: Vec<_> = arguments.iter().map(|s| s.as_ptr()).collect();
    // SAFETY: same bridge and kernel requirement as probes; only standard
    // Terminal descriptors are inherited. No general command path is exposed.
    let handle = unsafe {
        harness_probe_start(
            path.as_ptr(),
            home.as_ptr(),
            team.as_ptr(),
            identifier.as_ptr(),
            release_cdhash.as_ptr(),
            policy.platform_test,
            argv.as_ptr(),
            argv.len(),
            1,
            2,
            0,
        )
    };
    if handle.is_null() {
        return Err(ProbeError::Verification);
    }
    let task = Task {
        handle: handle as usize,
        permit: None,
    };
    // SAFETY: the human owns this interactive flow, and Foundation owns the process.
    unsafe { harness_probe_wait(handle) };
    task.exited().ok_or(ProbeError::Failed)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::os::unix::fs::{symlink, PermissionsExt};
    use std::sync::Mutex;

    // Keep these process-global lane tests sequential while the rest of the
    // crate's tests remain parallel. They never invoke an actual provider.
    static SERIAL: Mutex<()> = Mutex::new(());
    const ECHO: SignaturePolicy = SignaturePolicy {
        team: "",
        identifier: "com.apple.echo",
        release_cdhash: "",
        platform_test: true,
    };

    #[test]
    fn the_kernel_allows_the_exact_signed_image_and_passes_arguments_as_data() {
        let _serial = SERIAL.lock().unwrap();
        let text = "literal ; $(touch unwanted) <script>data</script>";
        let result = run(
            Path::new("/bin/echo"),
            Path::new("/var/empty"),
            ECHO,
            &[text],
            Duration::from_secs(5),
        )
        .unwrap();
        assert_eq!(result.code, 0);
        assert_eq!(result.stdout, format!("{text}\n"));
    }

    #[test]
    fn the_kernel_refuses_a_wrong_signer() {
        let _serial = SERIAL.lock().unwrap();
        let wrong = SignaturePolicy {
            team: "untrusted",
            identifier: "com.apple.echo",
            release_cdhash: "0000000000000000000000000000000000000000",
            platform_test: false,
        };
        assert!(matches!(
            run(
                Path::new("/bin/echo"),
                Path::new("/var/empty"),
                wrong,
                &[],
                Duration::from_secs(5)
            ),
            Err(ProbeError::Verification)
        ));
    }

    #[test]
    fn the_kernel_refuses_a_different_release_with_the_same_signer_and_identifier() {
        let _serial = SERIAL.lock().unwrap();
        let policy = SignaturePolicy {
            release_cdhash: "0000000000000000000000000000000000000000",
            ..ECHO
        };
        assert!(matches!(
            run(
                Path::new("/bin/echo"),
                Path::new("/var/empty"),
                policy,
                &[],
                Duration::from_secs(5)
            ),
            Err(ProbeError::Verification)
        ));
    }

    #[test]
    fn a_swapped_script_never_reaches_its_first_instruction() {
        let _serial = SERIAL.lock().unwrap();
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("candidate");
        let marker = dir.path().join("must-not-exist");
        fs::copy("/bin/echo", &path).unwrap();
        let result = run_with_hook(
            &path,
            Path::new("/var/empty"),
            ECHO,
            &[],
            Duration::from_secs(5),
            || {
                fs::rename(&path, dir.path().join("old")).unwrap();
                fs::write(
                    &path,
                    format!("#!/bin/sh\n/usr/bin/touch '{}'\n", marker.display()),
                )
                .unwrap();
                fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
            },
        );
        assert!(matches!(result, Err(ProbeError::Verification)));
        assert!(!marker.exists(), "unverified script executed");
    }

    #[test]
    fn a_parent_swap_cannot_launch_a_different_signed_image() {
        let _serial = SERIAL.lock().unwrap();
        let dir = tempfile::tempdir().unwrap();
        let parent = dir.path().join("install");
        fs::create_dir(&parent).unwrap();
        let path = parent.join("candidate");
        fs::copy("/bin/echo", &path).unwrap();
        let result = run_with_hook(
            &path,
            Path::new("/var/empty"),
            ECHO,
            &["30"],
            Duration::from_secs(5),
            || {
                fs::rename(&parent, dir.path().join("old")).unwrap();
                fs::create_dir(&parent).unwrap();
                symlink("/bin/sleep", &path).unwrap();
            },
        );
        assert!(matches!(result, Err(ProbeError::Verification)));
    }

    #[test]
    fn timeouts_stop_the_owned_process_before_releasing_the_lane() {
        let _serial = SERIAL.lock().unwrap();
        let policy = SignaturePolicy {
            team: "",
            identifier: "com.apple.sleep",
            release_cdhash: "",
            platform_test: true,
        };
        assert!(matches!(
            run(
                Path::new("/bin/sleep"),
                Path::new("/var/empty"),
                policy,
                &["30"],
                Duration::from_millis(200)
            ),
            Err(ProbeError::Timeout)
        ));
        assert!(
            !ACTIVE.load(Ordering::Acquire),
            "process cleanup still owns the lane"
        );
    }

    #[test]
    fn output_is_bounded_and_the_process_is_stopped() {
        let _serial = SERIAL.lock().unwrap();
        let policy = SignaturePolicy {
            team: "",
            identifier: "com.apple.yes",
            release_cdhash: "",
            platform_test: true,
        };
        assert!(matches!(
            run(
                Path::new("/usr/bin/yes"),
                Path::new("/var/empty"),
                policy,
                &[],
                Duration::from_secs(5)
            ),
            Err(ProbeError::OutputLimit)
        ));
        assert!(!ACTIVE.load(Ordering::Acquire));
    }

    #[test]
    fn the_bridge_contains_no_pathname_verifier_or_candidate_content_read() {
        let bridge = include_str!("../../native/launch_gate.swift");
        assert!(bridge.contains("task.launchRequirement ="));
        assert!(!bridge.contains("codesign"));
        assert!(!bridge.contains("forReadingAtPath"));
        assert!(!bridge.contains("contentsOf:"));
        assert!(!bridge.contains("Data(contentsOf"));
    }
}
