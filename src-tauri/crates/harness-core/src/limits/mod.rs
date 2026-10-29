//! Rule 1 ceiling enforcement (T-111): concurrent sessions, prompts per hour, turns per task, run minutes per day and
//! the idle/background presence rule.
//!
//! Pure in-memory logic over an injected [`Clock`](crate::clock::Clock). Every limit comes from
//! `compliance::ceilings`; a user may only make one stricter, and `min(user, ceiling)` is the only combination. The
//! module has no timer API: it answers "may this happen now?" and never starts anything on its own.

mod config;
mod presence;
mod refusal;
mod runclock;
mod timeline;
mod tracker;

pub use crate::provider::{ProviderId, UnknownProvider};
pub use config::{EffectiveLimits, UserLimits};
pub use presence::Presence;
pub use refusal::{CeilingKind, Refusal};
pub use tracker::{
    LimitsSnapshot, Meter, PromptRecord, ProviderLimits, ProviderMeters, RunDay, RunGuard,
    SessionPermit,
};

#[cfg(test)]
mod tests;
