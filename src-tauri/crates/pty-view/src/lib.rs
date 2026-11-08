//! PTY view crate (hard rule 3).
//!
//! Primitives for human-driven sessions. The app does not expose embedded launch or a write command while the
//! native input and working-directory boundaries are unavailable. The core crate has no dependency on this crate.
//!
//! Output is kept only in a bounded in-memory ring. It is never written to disk or logs (rule 4).

mod ring;

use portable_pty::{native_pty_system, Child, CommandBuilder, MasterPty, PtySize};
use ring::Ring;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::path::PathBuf;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

/// The most bytes one `write` call accepts. The UI splits longer pastes.
pub const MAX_WRITE_BYTES: usize = 4 * 1024;
/// Scrollback kept per session.
pub const SCROLLBACK_BYTES: usize = 256 * 1024;
const POLL_INTERVAL_MS: libc::c_int = 20;
const STOP_GRACE: Duration = Duration::from_millis(500);

/// What to run. The child gets exactly `env`: nothing is inherited from the app (rules 2 and 4).
#[derive(Debug, Clone)]
pub struct InteractiveSpec {
    pub program: PathBuf,
    pub args: Vec<String>,
    pub cwd: PathBuf,
    pub env: Vec<(String, String)>,
    pub cols: u16,
    pub rows: u16,
}

/// What a viewer needs to replay a session: the ring, the `seq` it ends at and the current size.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Attach {
    pub seq: u64,
    pub scrollback: Vec<u8>,
    pub cols: u16,
    pub rows: u16,
}

/// A human-driven PTY. A caller must authenticate input before invoking `write`.
pub struct InteractivePty {
    master: Mutex<Box<dyn MasterPty + Send>>,
    io: Arc<OwnedFd>,
    owned: Arc<Mutex<OwnedChild>>,
    ring: Arc<Mutex<Ring>>,
    size: Mutex<(u16, u16)>,
}

/// What one stop request did. `AlreadyExited` means the wrapper was already waited and nothing was signaled.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StopSignal {
    Sent,
    AlreadyExited,
}

/// The waiter owns collection. Stop and writes check the same state before acting.
#[derive(Default)]
struct OwnedChild {
    child: Option<Box<dyn Child + Send + Sync>>,
    exit_code: Option<i32>,
    stop: Option<StopPhase>,
}

enum StopPhase {
    Hangup(Instant),
    Terminate(Instant),
    KillGroup(Instant),
    KillChild,
}

fn lock<T: ?Sized>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|e| e.into_inner())
}

fn other(error: impl std::fmt::Display) -> io::Error {
    io::Error::other(error.to_string())
}

impl InteractivePty {
    /// Starts `spec` on a new PTY. `on_output` gets each chunk with its `seq`; `on_exit` gets the exit code once.
    pub fn start(
        spec: InteractiveSpec,
        mut on_output: impl FnMut(u64, &[u8]) + Send + 'static,
        on_exit: impl FnOnce(Option<i32>) + Send + 'static,
    ) -> io::Result<InteractivePty> {
        let pair = native_pty_system()
            .openpty(PtySize {
                rows: spec.rows,
                cols: spec.cols,
                pixel_width: 0,
                pixel_height: 0,
            })
            .map_err(other)?;
        let mut command = CommandBuilder::new(&spec.program);
        command.args(&spec.args);
        command.cwd(&spec.cwd);
        command.env_clear();
        for (key, value) in &spec.env {
            command.env(key, value);
        }
        let fd = pair
            .master
            .as_raw_fd()
            .ok_or_else(|| io::Error::other("the terminal has no master"))?;
        // portable-pty's Unix writer sends newline and VEOF on drop. Use an owned
        // duplicate that only closes, with nonblocking reads and writes.
        let io = Arc::new(duplicate_nonblocking(fd)?);
        let owned = Arc::new(Mutex::new(OwnedChild::default()));
        let ring = Arc::new(Mutex::new(Ring::new(SCROLLBACK_BYTES)));
        let (started, ready) = std::sync::mpsc::sync_channel(0);
        let (output, child_state, master) = (ring.clone(), owned.clone(), io.clone());
        // Allocate the monitor before starting the child so no thread allocation
        // failure can leave a spawned child without an owner.
        std::thread::Builder::new().spawn(move || {
            if ready.recv().is_ok() {
                let fd = master.as_raw_fd();
                let mut reader = OutputReader::default();
                loop {
                    let exit = lock(&child_state).poll(fd);
                    reader.drain(fd, |bytes| {
                        let seq = lock(&output).push(bytes);
                        on_output(seq, bytes);
                    });
                    if let ChildPoll::Exited(code) = exit {
                        on_exit(code);
                        break;
                    }
                }
            }
        })?;
        lock(&owned).child = Some(pair.slave.spawn_command(command).map_err(other)?);
        // The child holds its own copy. Keeping ours would hide the hangup when it exits.
        drop(pair.slave);
        started.send(()).expect("the terminal monitor is waiting");
        Ok(InteractivePty {
            master: Mutex::new(pair.master),
            io,
            owned,
            ring,
            size: Mutex::new((spec.cols, spec.rows)),
        })
    }

    /// Human keystrokes only. Refuses more than [`MAX_WRITE_BYTES`] per call.
    pub fn write(&self, bytes: &[u8]) -> io::Result<()> {
        if bytes.len() > MAX_WRITE_BYTES {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "input chunk is too large",
            ));
        }
        let state = lock(&self.owned);
        if state.child.is_none() || state.stop.is_some() {
            return Err(io::Error::new(
                io::ErrorKind::BrokenPipe,
                "the terminal ended",
            ));
        }
        let mut remaining = bytes;
        while !remaining.is_empty() {
            // SAFETY: the master is owned throughout, and the slice is readable.
            let n = unsafe {
                libc::write(
                    self.io.as_raw_fd(),
                    remaining.as_ptr().cast(),
                    remaining.len(),
                )
            };
            if n > 0 {
                remaining = &remaining[n as usize..];
            } else if n == 0 {
                return Err(io::Error::new(io::ErrorKind::WriteZero, "no input written"));
            } else {
                let error = io::Error::last_os_error();
                if error.kind() != io::ErrorKind::Interrupted {
                    return Err(error);
                }
            }
        }
        Ok(())
    }

    /// Sets the window size. The kernel tells the foreground process group with SIGWINCH.
    pub fn resize(&self, cols: u16, rows: u16) -> io::Result<()> {
        lock(&self.master)
            .resize(PtySize {
                rows,
                cols,
                pixel_width: 0,
                pixel_height: 0,
            })
            .map_err(other)?;
        *lock(&self.size) = (cols, rows);
        Ok(())
    }

    pub fn attach(&self) -> Attach {
        let (seq, scrollback) = lock(&self.ring).snapshot();
        let (cols, rows) = *lock(&self.size);
        Attach {
            seq,
            scrollback,
            cols,
            rows,
        }
    }

    /// Starts bounded signal escalation. Only the monitor reaps the owned child.
    pub fn kill(&self) -> StopSignal {
        let mut state = lock(&self.owned);
        if state.child.is_none() {
            return StopSignal::AlreadyExited;
        }
        if state.stop.is_none() {
            let fd = self.io.as_raw_fd();
            let _ = signal_foreground(fd, libc::SIGCONT);
            let _ = signal_foreground(fd, libc::SIGHUP);
            state.stop = Some(StopPhase::Hangup(Instant::now()));
        }
        StopSignal::Sent
    }

    /// The exit code recorded when the child was waited, if that has happened.
    pub fn collected_exit(&self) -> Option<i32> {
        lock(&self.owned).exit_code
    }
}

fn duplicate_nonblocking(fd: RawFd) -> io::Result<OwnedFd> {
    // SAFETY: fd is live and fcntl returns a new, close-on-exec descriptor.
    let duplicate = unsafe { libc::fcntl(fd, libc::F_DUPFD_CLOEXEC, 3) };
    if duplicate < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: the duplicate has no other Rust owner.
    let owned = unsafe { OwnedFd::from_raw_fd(duplicate) };
    // SAFETY: owned keeps this file description alive.
    let flags = unsafe { libc::fcntl(duplicate, libc::F_GETFL) };
    if flags < 0 || unsafe { libc::fcntl(duplicate, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(owned)
}

#[derive(Default)]
struct OutputReader {
    closed: bool,
}

impl OutputReader {
    fn drain(&mut self, fd: RawFd, mut output: impl FnMut(&[u8])) {
        if self.closed {
            std::thread::sleep(Duration::from_millis(POLL_INTERVAL_MS as u64));
            return;
        }
        let mut poll = libc::pollfd {
            fd,
            events: libc::POLLIN,
            revents: 0,
        };
        // SAFETY: one writable pollfd and a live master.
        if unsafe { libc::poll(&mut poll, 1, POLL_INTERVAL_MS) } <= 0 {
            return;
        }
        let mut buffer = [0u8; 16 * 1024];
        // Limit each drain so continuous output cannot starve child collection
        // or Stop escalation. After exit this also bounds lingering slave output.
        for _ in 0..SCROLLBACK_BYTES / buffer.len() {
            // SAFETY: the master is live and the buffer is writable.
            let n = unsafe { libc::read(fd, buffer.as_mut_ptr().cast(), buffer.len()) };
            if n > 0 {
                output(&buffer[..n as usize]);
            } else if n == 0 {
                self.closed = true;
                return;
            } else {
                match io::Error::last_os_error().kind() {
                    io::ErrorKind::Interrupted => continue,
                    io::ErrorKind::WouldBlock => return,
                    _ => {
                        self.closed = true;
                        return;
                    }
                }
            }
        }
    }
}

/// `TIOCSIG` on the master delivers `signal` to the foreground group of this pty. On macOS the signal number is the
/// ioctl argument itself. It is not a pointer and it is not a process id.
fn signal_foreground(fd: RawFd, signal: libc::c_int) -> io::Result<()> {
    // SAFETY: `fd` is the master of this session's pty, owned by `InteractivePty` for the call. The kernel names the
    // foreground group of that terminal; this process does not choose a pid.
    let result = unsafe { libc::ioctl(fd, libc::TIOCSIG as libc::c_ulong, signal) };
    if result == -1 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}

enum ChildPoll {
    Running,
    Exited(Option<i32>),
}

impl OwnedChild {
    fn poll(&mut self, fd: RawFd) -> ChildPoll {
        let Some(child) = self.child.as_mut() else {
            return ChildPoll::Exited(self.exit_code);
        };
        match child.try_wait() {
            Ok(Some(status)) => self.exit_code = i32::try_from(status.exit_code()).ok(),
            Ok(None) => {
                match self.stop {
                    Some(StopPhase::Hangup(since)) if since.elapsed() >= STOP_GRACE => {
                        let _ = signal_foreground(fd, libc::SIGCONT);
                        let _ = signal_foreground(fd, libc::SIGTERM);
                        self.stop = Some(StopPhase::Terminate(Instant::now()));
                    }
                    Some(StopPhase::Terminate(since)) if since.elapsed() >= STOP_GRACE => {
                        let _ = signal_foreground(fd, libc::SIGKILL);
                        self.stop = Some(StopPhase::KillGroup(Instant::now()));
                    }
                    Some(StopPhase::KillGroup(since))
                        if since.elapsed() >= Duration::from_millis(POLL_INTERVAL_MS as u64) =>
                    {
                        // The process we own may no longer be in the foreground group.
                        // The child handle still owns its identity and has not been reaped.
                        let _ = child.kill();
                        self.stop = Some(StopPhase::KillChild);
                    }
                    _ => {}
                }
                return ChildPoll::Running;
            }
            // No waitable child remains. Keep the exit status unknown.
            Err(error) if error.raw_os_error() == Some(libc::ECHILD) => {}
            // A wait error, including EINTR, does not prove the child exited.
            Err(_) => return ChildPoll::Running,
        }
        self.child = None;
        ChildPoll::Exited(self.exit_code)
    }
}

impl Drop for InteractivePty {
    fn drop(&mut self) {
        let _ = self.kill();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;
    use std::time::Duration;

    fn spec(program: &str, args: &[&str], env: &[(&str, &str)]) -> InteractiveSpec {
        InteractiveSpec {
            program: program.into(),
            args: args.iter().map(|s| s.to_string()).collect(),
            cwd: "/".into(),
            env: env
                .iter()
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .collect(),
            cols: 80,
            rows: 24,
        }
    }

    fn start(
        spec: InteractiveSpec,
    ) -> (
        InteractivePty,
        mpsc::Receiver<Vec<u8>>,
        mpsc::Receiver<Option<i32>>,
    ) {
        let (out_tx, out_rx) = mpsc::channel();
        let (exit_tx, exit_rx) = mpsc::channel();
        let pty = InteractivePty::start(
            spec,
            move |_, bytes| {
                let _ = out_tx.send(bytes.to_vec());
            },
            move |code| {
                let _ = exit_tx.send(code);
            },
        )
        .expect("start");
        (pty, out_rx, exit_rx)
    }

    fn read_until(rx: &mpsc::Receiver<Vec<u8>>, needle: &str) -> String {
        let mut text = String::new();
        while !text.contains(needle) {
            match rx.recv_timeout(Duration::from_secs(10)) {
                Ok(bytes) => text.push_str(&String::from_utf8_lossy(&bytes)),
                Err(_) => panic!("did not see {needle:?} in {text:?}"),
            }
        }
        text
    }

    #[test]
    fn typed_keys_reach_the_child_and_its_output_comes_back() {
        let (pty, out, exit) = start(spec("/bin/cat", &[], &[]));
        pty.write(b"hello from a person\n").unwrap();
        read_until(&out, "hello from a person");
        pty.kill();
        exit.recv_timeout(Duration::from_secs(10)).unwrap();
    }

    #[test]
    fn write_chunk_cap() {
        let (pty, _out, _exit) = start(spec("/bin/cat", &[], &[]));
        assert!(pty.write(&vec![b'x'; MAX_WRITE_BYTES + 1]).is_err());
        assert!(pty.write(b"ok\n").is_ok());
    }

    #[test]
    fn the_exit_code_is_reported() {
        let (_pty, _out, exit) = start(spec("/bin/sh", &["-c", "exit 7"], &[]));
        assert_eq!(exit.recv_timeout(Duration::from_secs(10)).unwrap(), Some(7));
    }

    #[test]
    fn env_is_exactly_the_spec_nothing_inherited() {
        let (_pty, out, _exit) = start(spec("/usr/bin/env", &[], &[("ONLY_THIS", "yes")]));
        let text = read_until(&out, "ONLY_THIS=yes");
        assert!(!text.contains("CONFIG_DIR"));
    }

    #[test]
    fn the_child_owns_a_controlling_terminal_and_sees_resizes() {
        // A real TUI relies on this: SIGWINCH reaches it and `stty size` reports the new window.
        let script = "trap 'stty size; exit 0' WINCH; echo ready; while :; do sleep 0.05; done";
        let (pty, out, exit) = start(spec(
            "/bin/sh",
            &["-c", script],
            &[("PATH", "/bin:/usr/bin")],
        ));
        read_until(&out, "ready");
        pty.resize(101, 33).unwrap();
        read_until(&out, "33 101");
        exit.recv_timeout(Duration::from_secs(10)).unwrap();
        assert_eq!((pty.attach().cols, pty.attach().rows), (101, 33));
    }

    #[test]
    fn attach_replays_output_with_its_seq() {
        let (pty, out, _exit) = start(spec("/bin/cat", &[], &[]));
        pty.write(b"replay me\n").unwrap();
        read_until(&out, "replay me");
        let attach = pty.attach();
        assert!(attach.seq > 0);
        assert!(String::from_utf8_lossy(&attach.scrollback).contains("replay me"));
    }

    #[test]
    fn stop_signals_the_foreground_group_and_not_a_reaped_pid() {
        let (pty, _out, exit) = start(spec("/bin/cat", &[], &[]));
        assert_eq!(pty.kill(), StopSignal::Sent);
        exit.recv_timeout(Duration::from_secs(10)).unwrap();
        assert_eq!(pty.kill(), StopSignal::AlreadyExited);
        let production = include_str!("lib.rs").split("#[cfg(test)]").next().unwrap();
        assert!(
            !production.contains("libc::kill"),
            "stop must not signal a saved pid"
        );
        assert!(!production.contains("clone_killer"));
        assert!(production.contains("TIOCSIG"));
    }

    #[test]
    fn no_disk_or_log() {
        for source in [include_str!("lib.rs"), include_str!("ring.rs")] {
            let production = source.split("#[cfg(test)]").next().unwrap();
            for banned in ["fs::", "File::", "log::", "println!", "eprintln!", "dbg!"] {
                assert!(!production.contains(banned), "found {banned}");
            }
        }
    }
}
