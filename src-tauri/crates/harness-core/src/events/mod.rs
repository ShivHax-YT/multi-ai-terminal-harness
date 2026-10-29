//! Backend events and the sink they go to (T-111).
//!
//! The names mirror the IPC contract (`docs/tasks/T-101-ipc-contract.md`, "Events"). Every event carries a full snapshot
//! and the UI replaces its cached copy. The payload is a JSON value built by the module that owns the type, so this
//! module depends on none of them. Payload text can come from a model or a CLI and is untrusted; the sink never
//! interprets it.

use serde_json::Value;
use std::sync::{Arc, Mutex, MutexGuard};

/// One event for the UI. Each variant holds the full snapshot as JSON.
#[derive(Debug, Clone, PartialEq)]
pub enum BackendEvent {
    ProviderChanged(Value),
    LeadChanged(Value),
    PlanChanged(Value),
    SessionChanged(Value),
    TerminalOutput(Value),
    UsageChanged(Value),
}

impl BackendEvent {
    /// Every event name in the contract.
    pub const NAMES: [&'static str; 6] = [
        "provider_changed",
        "lead_changed",
        "plan_changed",
        "session_changed",
        "terminal_output",
        "usage_changed",
    ];

    /// The contract's event name.
    pub fn name(&self) -> &'static str {
        match self {
            Self::ProviderChanged(_) => "provider_changed",
            Self::LeadChanged(_) => "lead_changed",
            Self::PlanChanged(_) => "plan_changed",
            Self::SessionChanged(_) => "session_changed",
            Self::TerminalOutput(_) => "terminal_output",
            Self::UsageChanged(_) => "usage_changed",
        }
    }

    /// The snapshot carried by the event.
    pub fn payload(&self) -> &Value {
        match self {
            Self::ProviderChanged(v)
            | Self::LeadChanged(v)
            | Self::PlanChanged(v)
            | Self::SessionChanged(v)
            | Self::TerminalOutput(v)
            | Self::UsageChanged(v) => v,
        }
    }
}

/// Where backend modules publish events. The app implements it over the Tauri event bus.
pub trait EventSink: Send + Sync {
    fn emit(&self, event: BackendEvent);
}

impl<S: EventSink + ?Sized> EventSink for Arc<S> {
    fn emit(&self, event: BackendEvent) {
        (**self).emit(event);
    }
}

/// Drops every event.
#[derive(Debug, Clone, Copy, Default)]
pub struct NullSink;

impl EventSink for NullSink {
    fn emit(&self, _event: BackendEvent) {}
}

/// Keeps every event in order, for tests. Clones share one log.
#[derive(Debug, Clone, Default)]
pub struct RecordingSink {
    events: Arc<Mutex<Vec<BackendEvent>>>,
}

impl RecordingSink {
    pub fn new() -> Self {
        Self::default()
    }

    /// Copy of everything emitted so far.
    pub fn events(&self) -> Vec<BackendEvent> {
        self.lock().clone()
    }

    /// Event names in emission order.
    pub fn names(&self) -> Vec<&'static str> {
        self.lock().iter().map(BackendEvent::name).collect()
    }

    /// Removes and returns everything emitted so far.
    pub fn take(&self) -> Vec<BackendEvent> {
        std::mem::take(&mut *self.lock())
    }

    pub fn len(&self) -> usize {
        self.lock().len()
    }

    pub fn is_empty(&self) -> bool {
        self.lock().is_empty()
    }

    fn lock(&self) -> MutexGuard<'_, Vec<BackendEvent>> {
        self.events.lock().unwrap_or_else(|p| p.into_inner())
    }
}

impl EventSink for RecordingSink {
    fn emit(&self, event: BackendEvent) {
        self.lock().push(event);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn all() -> Vec<BackendEvent> {
        vec![
            BackendEvent::ProviderChanged(json!({"provider": "claude"})),
            BackendEvent::LeadChanged(json!({})),
            BackendEvent::PlanChanged(json!({})),
            BackendEvent::SessionChanged(json!({})),
            BackendEvent::TerminalOutput(json!({})),
            BackendEvent::UsageChanged(json!({})),
        ]
    }

    #[test]
    fn names_match_the_contract() {
        let got: Vec<&str> = all().iter().map(BackendEvent::name).collect();
        assert_eq!(got, BackendEvent::NAMES);
        assert_eq!(
            got,
            [
                "provider_changed",
                "lead_changed",
                "plan_changed",
                "session_changed",
                "terminal_output",
                "usage_changed"
            ]
        );
    }

    #[test]
    fn payload_is_the_snapshot_given() {
        let event = BackendEvent::ProviderChanged(json!({"provider": "claude"}));
        assert_eq!(event.payload(), &json!({"provider": "claude"}));
    }

    #[test]
    fn recording_sink_keeps_order() {
        let sink = RecordingSink::new();
        assert!(sink.is_empty());
        for event in all() {
            sink.emit(event);
        }
        assert_eq!(sink.len(), 6);
        assert_eq!(sink.names(), BackendEvent::NAMES);
    }

    #[test]
    fn recording_sink_take_empties_the_log() {
        let sink = RecordingSink::new();
        sink.emit(BackendEvent::UsageChanged(json!({"n": 1})));
        let taken = sink.take();
        assert_eq!(taken.len(), 1);
        assert!(sink.is_empty());
    }

    #[test]
    fn recording_sink_clones_share_the_log() {
        let sink = RecordingSink::new();
        let as_trait: Arc<dyn EventSink> = Arc::new(sink.clone());
        as_trait.emit(BackendEvent::LeadChanged(json!({})));
        assert_eq!(sink.names(), vec!["lead_changed"]);
    }

    #[test]
    fn null_sink_accepts_everything() {
        let sink = NullSink;
        for event in all() {
            sink.emit(event);
        }
    }
}
