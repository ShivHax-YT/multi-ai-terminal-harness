//! PTY view crate (hard rule 3).
//!
//! Spawns interactive CLI sessions for the human to watch and drive. Its write path is reachable only from the app
//! shell's `pty_write` command, which the UI calls from keyboard events in the terminal view. The core crate (lead,
//! scheduler, adapters) has no dependency on this crate, so the compiler forbids automation from reaching it.
//!
//! Output is kept only in a bounded in-memory ring. It is never written to disk or logs (rule 4).

mod ring;

use portable_pty::{native_pty_system, ChildKiller, CommandBuilder, MasterPty, PtySize};
use ring::Ring;
use std::io::{self, Read, Write};
use std::path::PathBuf;
use std::sync::{Arc, Mutex, MutexGuard};

/// The most bytes one `write` call accepts. The UI splits longer pastes.
pub const MAX_WRITE_BYTES: usize = 4 * 1024;
/// Scrollback kept per session.
pub const SCROLLBACK_BYTES: usize = 256 * 1024;

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

/// A human-driven PTY. `write` exists only here, and only the app shell's human input command calls it.
pub struct InteractivePty {
    master: Mutex<Box<dyn MasterPty + Send>>,
    writer: Mutex<Box<dyn Write + Send>>,
    killer: Mutex<Box<dyn ChildKiller + Send + Sync>>,
    ring: Arc<Mutex<Ring>>,
    size: Mutex<(u16, u16)>,
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
        let mut child = pair.slave.spawn_command(command).map_err(other)?;
        // The child holds its own copy. Keeping ours would hide the hangup when it exits.
        drop(pair.slave);
        let mut reader = pair.master.try_clone_reader().map_err(other)?;
        let writer = pair.master.take_writer().map_err(other)?;
        let killer = child.clone_killer();
        let ring = Arc::new(Mutex::new(Ring::new(SCROLLBACK_BYTES)));
        let output_ring = ring.clone();
        std::thread::spawn(move || {
            let mut buffer = [0u8; 16 * 1024];
            loop {
                match reader.read(&mut buffer) {
                    Ok(0) | Err(_) => return,
                    Ok(n) => {
                        let seq = lock(&output_ring).push(&buffer[..n]);
                        on_output(seq, &buffer[..n]);
                    }
                }
            }
        });
        std::thread::spawn(move || {
            let code = child
                .wait()
                .ok()
                .and_then(|status| i32::try_from(status.exit_code()).ok());
            on_exit(code);
        });
        Ok(InteractivePty {
            master: Mutex::new(pair.master),
            writer: Mutex::new(writer),
            killer: Mutex::new(killer),
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
        let mut writer = lock(&self.writer);
        writer.write_all(bytes)?;
        writer.flush()
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

    /// Ends the session. Output stays readable through `attach`.
    pub fn kill(&self) -> io::Result<()> {
        lock(&self.killer).kill()
    }
}

impl Drop for InteractivePty {
    fn drop(&mut self) {
        let _ = lock(&self.killer).kill();
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
        pty.kill().unwrap();
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
        // SAFETY: test process; the variable is unique to this test.
        unsafe { std::env::set_var("HARNESS_TEST_MUST_NOT_LEAK", "leaked") };
        let (_pty, out, _exit) = start(spec("/usr/bin/env", &[], &[("ONLY_THIS", "yes")]));
        let text = read_until(&out, "ONLY_THIS=yes");
        assert!(!text.contains("HARNESS_TEST_MUST_NOT_LEAK"));
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
    fn no_disk_or_log() {
        for source in [include_str!("lib.rs"), include_str!("ring.rs")] {
            let production = source.split("#[cfg(test)]").next().unwrap();
            for banned in ["fs::", "File::", "log::", "println!", "eprintln!", "dbg!"] {
                assert!(!production.contains(banned), "found {banned}");
            }
        }
    }
}
