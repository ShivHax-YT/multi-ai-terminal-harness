//! Harness core: lead, scheduler, adapters and compliance.
//!
//! Automation in this crate talks to provider CLIs only through documented headless or ACP transports (rule 3). It has
//! no route to an interactive terminal.

pub mod compliance;

// Phase 1 modules, registered once by the lead (shared file); each is owned by the brief named in its mod.rs.
pub mod adapters;
pub mod approval;
pub mod binary;
pub mod clock;
pub mod events;
pub mod fs_guard;
pub mod killswitch;
pub mod lead;
pub mod limits;
pub mod pacing;
pub mod plan;
pub mod process;
pub mod provider;
pub mod review;
pub mod scheduler;
pub mod session;
pub mod settings;
pub mod status;
pub mod usage;
pub mod verify;
pub mod worktree;
