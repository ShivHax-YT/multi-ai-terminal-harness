//! Provider ids as the IPC contract spells them (`ProviderId` in `docs/tasks/T-101-ipc-contract.md`).
//!
//! The one definition for the crate: usage, pacing, adapters and limits all key on this enum.

use serde::{Deserialize, Serialize};
use std::fmt;
use std::str::FromStr;

/// A provider id (`ProviderId` in the IPC contract). Counters are keyed by provider only: there is no account, profile or
/// session key (rule 2).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ProviderId {
    Claude,
    Codex,
    Grok,
    Kimi,
    Gemini,
    Glm,
}

impl ProviderId {
    /// Every provider, in contract order.
    pub const ALL: [ProviderId; 6] = [
        ProviderId::Claude,
        ProviderId::Codex,
        ProviderId::Grok,
        ProviderId::Kimi,
        ProviderId::Gemini,
        ProviderId::Glm,
    ];

    /// The contract's string id.
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Claude => "claude",
            Self::Codex => "codex",
            Self::Grok => "grok",
            Self::Kimi => "kimi",
            Self::Gemini => "gemini",
            Self::Glm => "glm",
        }
    }
}

impl fmt::Display for ProviderId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Returned by [`ProviderId::from_str`] for an id outside the contract's set.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("unknown provider id")]
pub struct UnknownProvider;

impl FromStr for ProviderId {
    type Err = UnknownProvider;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Self::ALL
            .into_iter()
            .find(|p| p.as_str() == s)
            .ok_or(UnknownProvider)
    }
}
