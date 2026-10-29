//! The trace hook: one event per call through the file-access layer.
//!
//! An event holds a SHA-256 hash of the path, never the path, so the trace itself carries no sensitive path. The
//! credential canary (rule 4) hashes the paths it planted and checks that no event matches. The app installs a sink in
//! production; tests install a [`RecordingSink`].

use std::path::Path;
use std::sync::Mutex;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

/// What the caller asked the layer to do.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TraceOp {
    OpenRead,
    ReadToString,
    ReadDir,
    Metadata,
    CreateWrite,
    ExecResolve,
    RegisterRoot,
}

/// How the layer answered.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TraceOutcome {
    /// The layer allowed the call and the underlying operation succeeded.
    Allowed,
    /// The path is on the credential denylist.
    Denied,
    /// The path is not under any registered root (or not under a writable one).
    OutsideRoots,
    /// Refused for another reason (relative path, link trick, not an executable file).
    Refused,
    /// The layer allowed the call but the operating system reported an error.
    IoError,
}

/// One record of a call through the layer.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TraceEvent {
    /// Lowercase hex SHA-256 of the path bytes (see [`hash_path`]).
    pub path_hash: String,
    pub op: TraceOp,
    pub outcome: TraceOutcome,
    pub at: DateTime<Utc>,
}

impl TraceEvent {
    pub(crate) fn now(path: &Path, op: TraceOp, outcome: TraceOutcome) -> TraceEvent {
        TraceEvent {
            path_hash: hash_path(path),
            op,
            outcome,
            at: Utc::now(),
        }
    }
}

/// Lowercase hex SHA-256 of the path's bytes. The layer hashes the canonical path when it could resolve one, otherwise
/// the path as given.
pub fn hash_path(path: &Path) -> String {
    let digest = Sha256::digest(path.as_os_str().as_encoded_bytes());
    hex::encode(digest)
}

/// Receives every trace event. Implementations must not block for long and must not record anything but the event.
pub trait TraceSink: Send + Sync {
    fn record(&self, event: TraceEvent);
}

/// A sink that keeps events in memory, for tests and the canary.
#[derive(Debug, Default)]
pub struct RecordingSink {
    events: Mutex<Vec<TraceEvent>>,
}

impl RecordingSink {
    pub fn new() -> RecordingSink {
        RecordingSink::default()
    }

    /// A copy of every event recorded so far, oldest first.
    pub fn events(&self) -> Vec<TraceEvent> {
        self.lock().clone()
    }

    /// Events whose path hash equals the hash of `path`.
    pub fn events_for(&self, path: &Path) -> Vec<TraceEvent> {
        let wanted = hash_path(path);
        self.lock()
            .iter()
            .filter(|e| e.path_hash == wanted)
            .cloned()
            .collect()
    }

    pub fn clear(&self) {
        self.lock().clear();
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Vec<TraceEvent>> {
        self.events
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

impl TraceSink for RecordingSink {
    fn record(&self, event: TraceEvent) {
        self.lock().push(event);
    }
}

/// A sink that drops every event.
#[derive(Debug, Default, Clone, Copy)]
pub struct NullSink;

impl TraceSink for NullSink {
    fn record(&self, _event: TraceEvent) {}
}
