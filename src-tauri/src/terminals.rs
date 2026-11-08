//! Human-driven CLI terminals (T-106, T-123 Option A). The human starts each one with a click; only keystrokes from
//! the terminal view reach it, through `pty_write`. Nothing in harness-core can reach this module (rule 3).
//!
//! The PTY runs this app's own closed `--provider-session=<id>` mode rather than the CLI itself. That wrapper owns the
//! controlling terminal, then launches the CLI through the kernel-enforced identity requirement and hands it the
//! foreground, so Ctrl-C and window-size signals reach the CLI directly (rule 6).

use base64::Engine;
use harness_core::clock::{Clock, SystemClock};
use pty_view::{Attach, InteractivePty, InteractiveSpec, StopSignal};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::time::{Duration, Instant};
use tauri::Emitter;

/// Ended sessions kept so their last output stays readable.
const MAX_ENDED_KEPT: usize = 20;

struct Entry {
    /// `SessionView` in the contract.
    view: Value,
    pty: Option<Arc<InteractivePty>>,
    revision: u64,
    stop_requested: bool,
}

#[derive(Default)]
pub struct Terminals {
    entries: Mutex<BTreeMap<u64, Entry>>,
    next_id: AtomicU64,
    shutting_down: AtomicBool,
    app: OnceLock<tauri::AppHandle>,
}

#[derive(Debug, PartialEq, Eq)]
pub enum TerminalError {
    NotFound,
    AtCeiling,
    TakeoverOff,
    Ended,
    Failed(&'static str),
}

fn session_id(number: u64) -> String {
    format!("t-{number}")
}

fn parse_id(id: &str) -> Option<u64> {
    id.strip_prefix("t-")?.parse().ok()
}

fn is_live(view: &Value) -> bool {
    matches!(
        view["state"]["kind"].as_str(),
        Some("spawning" | "running" | "stopping")
    )
}

fn has_ended(view: &Value) -> bool {
    matches!(view["state"]["kind"].as_str(), Some("exited" | "killed"))
}

fn bump(entry: &mut Entry) {
    entry.revision += 1;
    entry.view["revision"] = json!(entry.revision);
}

impl Terminals {
    pub fn shared() -> &'static Terminals {
        static SHARED: OnceLock<Terminals> = OnceLock::new();
        SHARED.get_or_init(Terminals::default)
    }

    pub fn bind_app(&self, app: tauri::AppHandle) {
        let _ = self.app.set(app);
    }

    fn entries(&self) -> MutexGuard<'_, BTreeMap<u64, Entry>> {
        self.entries.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn emit(&self, event: &str, payload: Value) {
        if let Some(app) = self.app.get() {
            let _ = app.emit(event, payload);
        }
    }

    /// Starts a session. The ceiling counts this provider's live terminals (rule 1; T-123 decision).
    pub fn start(
        &'static self,
        provider: &str,
        title: &str,
        folder: &str,
        spec: InteractiveSpec,
    ) -> Result<Value, TerminalError> {
        let number = self.next_id.fetch_add(1, Ordering::Relaxed) + 1;
        let id = session_id(number);
        let mut entries = self.entries();
        if self.shutting_down.load(Ordering::Acquire) {
            return Err(TerminalError::Failed("The app is shutting down."));
        }
        let live = entries
            .values()
            .filter(|e| e.view["provider"] == provider && is_live(&e.view))
            .count();
        if live >= harness_core::compliance::ceilings::MAX_CONCURRENT_SESSIONS as usize {
            return Err(TerminalError::AtCeiling);
        }
        let output_id = id.clone();
        let pty = InteractivePty::start(
            spec,
            move |seq, bytes| {
                let data = base64::engine::general_purpose::STANDARD.encode(bytes);
                self.emit(
                    "terminal_output",
                    json!({ "session_id": output_id, "seq": seq, "data_b64": data }),
                );
            },
            move |code| self.finished(number, code),
        )
        .map_err(|_| TerminalError::Failed("The terminal could not start."))?;
        let view = json!({
            "session_id": id,
            "kind": "interactive",
            "provider": provider,
            "title": title,
            "worktree": folder,
            "state": { "kind": "running" },
            "paused": null,
            "turns": { "current": 0, "limit": 0 },
            "started_at": SystemClock::new().now().to_rfc3339(),
            "takeover": true,
        });
        let mut entry = Entry {
            view,
            pty: Some(Arc::new(pty)),
            revision: 0,
            stop_requested: false,
        };
        bump(&mut entry);
        let view = entry.view.clone();
        entries.insert(number, entry);
        Self::prune(&mut entries);
        drop(entries);
        self.emit("session_changed", view.clone());
        Ok(view)
    }

    fn prune(entries: &mut BTreeMap<u64, Entry>) {
        let ended: Vec<u64> = entries
            .iter()
            .filter(|(_, e)| !is_live(&e.view))
            .map(|(id, _)| *id)
            .collect();
        for id in ended
            .iter()
            .take(ended.len().saturating_sub(MAX_ENDED_KEPT))
        {
            entries.remove(id);
        }
    }

    fn finished(&self, number: u64, code: Option<i32>) {
        let view = {
            let mut entries = self.entries();
            let Some(entry) = entries.get_mut(&number) else {
                return;
            };
            if has_ended(&entry.view) {
                return;
            }
            if entry.stop_requested {
                entry.view["state"] = json!({ "kind": "killed" });
            } else {
                entry.view["state"] = match code {
                    Some(code) => json!({ "kind": "exited", "code": code }),
                    None => json!({ "kind": "exited" }),
                };
            }
            entry.view["takeover"] = json!(false);
            bump(entry);
            entry.view.clone()
        };
        self.emit("session_changed", view);
    }

    pub fn list(&self) -> Value {
        Value::Array(self.entries().values().map(|e| e.view.clone()).collect())
    }

    fn pty(&self, id: &str) -> Result<(Arc<InteractivePty>, Value), TerminalError> {
        let number = parse_id(id).ok_or(TerminalError::NotFound)?;
        let entries = self.entries();
        let entry = entries.get(&number).ok_or(TerminalError::NotFound)?;
        let pty = entry.pty.clone().ok_or(TerminalError::NotFound)?;
        Ok((pty, entry.view.clone()))
    }

    /// Human keystrokes only. Refused unless take-over is on (rule 3).
    pub fn write(&self, id: &str, data: &str) -> Result<(), TerminalError> {
        let entries = self.entries();
        let entry = parse_id(id)
            .and_then(|number| entries.get(&number))
            .ok_or(TerminalError::TakeoverOff)?;
        if entry.view["takeover"] != true {
            return Err(TerminalError::TakeoverOff);
        }
        if !is_live(&entry.view) {
            return Err(TerminalError::Ended);
        }
        // Keep the authorization and nonblocking write in one state transition.
        entry
            .pty
            .as_ref()
            .ok_or(TerminalError::TakeoverOff)?
            .write(data.as_bytes())
            .map_err(|_| TerminalError::Failed("The keystroke did not reach the terminal."))
    }

    pub fn resize(&self, id: &str, cols: u16, rows: u16) -> Result<(), TerminalError> {
        if !(2..=1000).contains(&cols) || !(2..=1000).contains(&rows) {
            return Err(TerminalError::Failed("The terminal size is out of range."));
        }
        let (pty, view) = self.pty(id)?;
        if !is_live(&view) {
            return Ok(());
        }
        pty.resize(cols, rows)
            .map_err(|_| TerminalError::Failed("The terminal could not be resized."))
    }

    pub fn attach(&self, id: &str) -> Result<Attach, TerminalError> {
        Ok(self.pty(id)?.0.attach())
    }

    pub fn set_takeover(&self, id: &str, enabled: bool) -> Result<Value, TerminalError> {
        let number = parse_id(id).ok_or(TerminalError::NotFound)?;
        let view = {
            let mut entries = self.entries();
            let entry = entries.get_mut(&number).ok_or(TerminalError::NotFound)?;
            if !is_live(&entry.view) {
                return Err(TerminalError::Ended);
            }
            // Stop already dropped take-over. Do not turn it back on while the process is still exiting.
            if entry.view["state"]["kind"] == "stopping" {
                entry.view["takeover"] = json!(false);
                return Ok(entry.view.clone());
            }
            entry.view["takeover"] = json!(enabled);
            bump(entry);
            entry.view.clone()
        };
        self.emit("session_changed", view.clone());
        Ok(view)
    }

    /// Starts signal escalation and retains the ceiling slot until the child is reaped.
    pub fn kill(&self, id: &str) -> Result<Value, TerminalError> {
        let number = parse_id(id).ok_or(TerminalError::NotFound)?;
        let view = {
            let mut entries = self.entries();
            let entry = entries.get_mut(&number).ok_or(TerminalError::NotFound)?;
            if has_ended(&entry.view) || entry.stop_requested {
                return Ok(entry.view.clone());
            }
            let pty = entry.pty.as_ref().ok_or(TerminalError::NotFound)?;
            entry.view["state"] = match pty.kill() {
                StopSignal::Sent => {
                    entry.stop_requested = true;
                    json!({ "kind": "stopping" })
                }
                StopSignal::AlreadyExited => match pty.collected_exit() {
                    Some(code) => json!({ "kind": "exited", "code": code }),
                    None => json!({ "kind": "exited" }),
                },
            };
            entry.view["takeover"] = json!(false);
            bump(entry);
            entry.view.clone()
        };
        self.emit("session_changed", view.clone());
        Ok(view)
    }

    /// Quit: refuse new sessions, request stop and give the monitor time to reap.
    pub fn shutdown(&self) {
        self.shutting_down.store(true, Ordering::Release);
        let ids: Vec<String> = self
            .entries()
            .values()
            .filter(|entry| is_live(&entry.view))
            .filter_map(|entry| {
                entry.view["session_id"]
                    .as_str()
                    .map(std::borrow::ToOwned::to_owned)
            })
            .collect();
        for id in &ids {
            let _ = self.kill(id);
        }
        let deadline = Instant::now() + Duration::from_secs(2);
        while Instant::now() < deadline {
            if !self.entries().values().any(|entry| is_live(&entry.view)) {
                return;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    fn fresh() -> &'static Terminals {
        Box::leak(Box::default())
    }

    fn cat() -> InteractiveSpec {
        InteractiveSpec {
            program: "/bin/cat".into(),
            args: vec![],
            cwd: "/".into(),
            env: vec![],
            cols: 80,
            rows: 24,
        }
    }

    fn shell(script: &str) -> InteractiveSpec {
        InteractiveSpec {
            program: "/bin/sh".into(),
            args: vec!["-c".into(), script.into()],
            cwd: "/".into(),
            env: vec![("PATH".into(), "/bin:/usr/bin".into())],
            cols: 80,
            rows: 24,
        }
    }

    fn kind(t: &Terminals) -> String {
        t.list()[0]["state"]["kind"]
            .as_str()
            .unwrap_or_default()
            .to_owned()
    }

    fn start(t: &'static Terminals, provider: &str) -> Result<String, TerminalError> {
        t.start(provider, "folder", "/folder", cat())
            .map(|v| v["session_id"].as_str().unwrap().to_owned())
    }

    fn wait_for(mut ready: impl FnMut() -> bool) {
        let deadline = Instant::now() + Duration::from_secs(10);
        while !ready() {
            assert!(Instant::now() < deadline, "timed out");
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    #[test]
    fn keystrokes_reach_the_terminal_only_while_takeover_is_on() {
        let t = fresh();
        let id = start(t, "claude").unwrap();
        t.write(&id, "typed by a person\n").unwrap();
        wait_for(|| {
            String::from_utf8_lossy(&t.attach(&id).unwrap().scrollback)
                .contains("typed by a person")
        });
        t.set_takeover(&id, false).unwrap();
        assert_eq!(t.write(&id, "x"), Err(TerminalError::TakeoverOff));
        t.set_takeover(&id, true).unwrap();
        assert_eq!(t.write(&id, "x"), Ok(()));
        t.kill(&id).unwrap();
    }

    #[test]
    fn an_unknown_session_never_accepts_input() {
        assert_eq!(fresh().write("t-9", "x"), Err(TerminalError::TakeoverOff));
        assert_eq!(
            fresh().write("nonsense", "x"),
            Err(TerminalError::TakeoverOff)
        );
    }

    #[test]
    fn the_concurrent_ceiling_applies_per_provider_and_frees_on_stop() {
        let t = fresh();
        let first = start(t, "claude").unwrap();
        let _second = start(t, "claude").unwrap();
        assert_eq!(start(t, "claude"), Err(TerminalError::AtCeiling));
        // A different provider has its own count.
        let other = start(t, "codex").unwrap();
        t.kill(&first).unwrap();
        wait_for(|| {
            let list = t.list();
            let view = list
                .as_array()
                .unwrap()
                .iter()
                .find(|v| v["session_id"] == first)
                .unwrap();
            !is_live(view)
        });
        let third = start(t, "claude").unwrap();
        t.shutdown();
        let _ = (third, other);
    }

    #[test]
    fn the_slot_stays_occupied_until_the_process_exits() {
        let t = fresh();
        // SIGHUP is caught and the process keeps running long enough that a replacement must be refused.
        let script = "trap 'sleep 0.4; exit 0' HUP; echo ready; while :; do sleep 0.05; done";
        let first = t.start("claude", "f", "/f", shell(script)).unwrap()["session_id"]
            .as_str()
            .unwrap()
            .to_owned();
        let second = t.start("claude", "f", "/f", shell(script)).unwrap()["session_id"]
            .as_str()
            .unwrap()
            .to_owned();
        wait_for(|| {
            t.attach(&first)
                .unwrap()
                .scrollback
                .windows(5)
                .any(|w| w == b"ready")
                && t.attach(&second)
                    .unwrap()
                    .scrollback
                    .windows(5)
                    .any(|w| w == b"ready")
        });
        let stopping = t.kill(&first).unwrap();
        assert_eq!(stopping["state"]["kind"], "stopping");
        assert_eq!(stopping["takeover"], false);
        assert_eq!(start(t, "claude"), Err(TerminalError::AtCeiling));
        // Stop is idempotent while the process is still alive, and the slot stays taken.
        assert_eq!(t.kill(&first).unwrap()["state"]["kind"], "stopping");
        assert_eq!(start(t, "claude"), Err(TerminalError::AtCeiling));
        wait_for(|| {
            t.list()
                .as_array()
                .unwrap()
                .iter()
                .find(|view| view["session_id"] == first)
                .unwrap()["state"]["kind"]
                == "killed"
        });
        let third = start(t, "claude").unwrap();
        t.kill(&second).unwrap();
        t.kill(&third).unwrap();
        t.shutdown();
    }

    #[test]
    fn stop_escalates_for_a_child_that_ignores_hangup_and_terminate() {
        let t = fresh();
        // This shell can exit only when the monitor escalates past HUP and TERM.
        let script = "trap '' HUP TERM; echo ready; while :; do read _; done";
        let held = t.start("claude", "f", "/f", shell(script)).unwrap()["session_id"]
            .as_str()
            .unwrap()
            .to_owned();
        let _other = start(t, "claude").unwrap();
        wait_for(|| {
            t.attach(&held)
                .unwrap()
                .scrollback
                .windows(5)
                .any(|w| w == b"ready")
        });
        assert_eq!(t.kill(&held).unwrap()["state"]["kind"], "stopping");
        assert_eq!(start(t, "claude"), Err(TerminalError::AtCeiling));
        wait_for(|| {
            t.list()
                .as_array()
                .unwrap()
                .iter()
                .find(|view| view["session_id"] == held)
                .unwrap()["state"]["kind"]
                == "killed"
        });
        assert!(start(t, "claude").is_ok());
        t.shutdown();
    }

    #[test]
    fn shutdown_collects_a_live_session() {
        let t = fresh();
        let id = start(t, "claude").unwrap();
        t.shutdown();
        assert!(!is_live(&t.list()[0]));
        assert!(t.write(&id, "x").is_err());
        assert_eq!(
            start(t, "claude"),
            Err(TerminalError::Failed("The app is shutting down."))
        );
    }

    #[test]
    fn stop_records_killed_and_refuses_later_input() {
        let t = fresh();
        let id = start(t, "claude").unwrap();
        let before = t.list()[0]["revision"].as_u64().unwrap();
        let view = t.kill(&id).unwrap();
        assert!(view["state"]["kind"] == "stopping" || view["state"]["kind"] == "killed");
        assert_eq!(view["takeover"], false);
        assert_eq!(t.write(&id, "x"), Err(TerminalError::TakeoverOff));
        wait_for(|| kind(t) == "killed");
        let ended = t.list()[0]["revision"].as_u64().unwrap();
        assert!(ended > before);
        // A later stop does not signal a collected process or rewrite the record.
        assert_eq!(t.kill(&id).unwrap()["state"]["kind"], "killed");
        assert_eq!(t.list()[0]["state"]["kind"], "killed");
    }

    #[test]
    fn a_natural_exit_is_recorded_and_output_stays_readable() {
        let t = fresh();
        let spec = InteractiveSpec {
            program: "/bin/sh".into(),
            args: vec!["-c".into(), "echo bye; exit 3".into()],
            ..cat()
        };
        let id = t.start("codex", "f", "/f", spec).unwrap()["session_id"]
            .as_str()
            .unwrap()
            .to_owned();
        wait_for(|| t.list()[0]["state"]["kind"] == "exited");
        assert_eq!(t.list()[0]["state"]["code"], 3);
        wait_for(|| String::from_utf8_lossy(&t.attach(&id).unwrap().scrollback).contains("bye"));
    }
}
