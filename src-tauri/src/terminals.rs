//! Human-driven CLI terminals (T-106, T-123 Option A). The human starts each one with a click; only keystrokes from
//! the terminal view reach it, through `pty_write`. Nothing in harness-core can reach this module (rule 3).
//!
//! The PTY runs this app's own closed `--provider-session=<id>` mode rather than the CLI itself. That wrapper owns the
//! controlling terminal, then launches the CLI through the kernel-enforced identity requirement and hands it the
//! foreground, so Ctrl-C and window-size signals reach the CLI directly (rule 6).

use base64::Engine;
use pty_view::{Attach, InteractivePty, InteractiveSpec};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use tauri::Emitter;

const DEFAULT_COLS: u16 = 100;
const DEFAULT_ROWS: u16 = 30;
/// Ended sessions kept so their last output stays readable.
const MAX_ENDED_KEPT: usize = 20;

struct Entry {
    /// `SessionView` in the contract.
    view: Value,
    pty: Option<Arc<InteractivePty>>,
}

#[derive(Default)]
pub struct Terminals {
    entries: Mutex<BTreeMap<u64, Entry>>,
    next_id: AtomicU64,
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
    matches!(view["state"]["kind"].as_str(), Some("spawning" | "running"))
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
            "started_at": harness_core::status::timestamp(),
            "takeover": true,
        });
        entries.insert(
            number,
            Entry {
                view: view.clone(),
                pty: Some(Arc::new(pty)),
            },
        );
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
            // `kill` already recorded the end.
            if !is_live(&entry.view) {
                return;
            }
            entry.view["state"] = match code {
                Some(code) => json!({ "kind": "exited", "code": code }),
                None => json!({ "kind": "exited" }),
            };
            entry.view["takeover"] = json!(false);
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
        let (pty, view) = self.pty(id).map_err(|_| TerminalError::TakeoverOff)?;
        if view["takeover"] != true {
            return Err(TerminalError::TakeoverOff);
        }
        if !is_live(&view) {
            return Err(TerminalError::Ended);
        }
        pty.write(data.as_bytes())
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
            entry.view["takeover"] = json!(enabled);
            entry.view.clone()
        };
        self.emit("session_changed", view.clone());
        Ok(view)
    }

    /// Stop. The CLI ends with its terminal; files in the folder stay.
    pub fn kill(&self, id: &str) -> Result<Value, TerminalError> {
        let number = parse_id(id).ok_or(TerminalError::NotFound)?;
        let (view, pty) = {
            let mut entries = self.entries();
            let entry = entries.get_mut(&number).ok_or(TerminalError::NotFound)?;
            if is_live(&entry.view) {
                entry.view["state"] = json!({ "kind": "killed" });
                entry.view["takeover"] = json!(false);
            }
            (entry.view.clone(), entry.pty.clone())
        };
        if let Some(pty) = pty {
            let _ = pty.kill();
        }
        self.emit("session_changed", view.clone());
        Ok(view)
    }
}

/// The spec for a real provider session: this app's closed wrapper mode, in the folder the human picked.
pub fn provider_spec(
    provider: &str,
    folder: std::path::PathBuf,
) -> Result<InteractiveSpec, String> {
    let program =
        std::env::current_exe().map_err(|_| "The app could not locate itself.".to_owned())?;
    Ok(InteractiveSpec {
        program,
        args: vec![format!("--provider-session={provider}")],
        cwd: folder,
        env: harness_core::status::human_terminal_env()?,
        cols: DEFAULT_COLS,
        rows: DEFAULT_ROWS,
    })
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
        let third = start(t, "claude").unwrap();
        t.kill(&third).unwrap();
        t.kill(&_second).unwrap();
        t.kill(&other).unwrap();
    }

    #[test]
    fn stop_records_killed_and_refuses_later_input() {
        let t = fresh();
        let id = start(t, "claude").unwrap();
        let view = t.kill(&id).unwrap();
        assert_eq!(view["state"]["kind"], "killed");
        assert_eq!(view["takeover"], false);
        assert_eq!(t.write(&id, "x"), Err(TerminalError::TakeoverOff));
        // The exit that follows does not overwrite the recorded state.
        std::thread::sleep(Duration::from_millis(200));
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
