//! Harness core: lead, scheduler, adapters and compliance.
//!
//! Automation in this crate talks to provider CLIs only through documented headless or ACP transports (rule 3). It has
//! no route to an interactive terminal.

pub mod compliance;

// Phase 1 modules, registered once by the lead (shared file); each is owned by the brief named in its mod.rs.
pub mod clock;
pub mod events;
pub mod limits;
pub mod usage;
pub mod pacing;
pub mod fs_guard;
pub mod binary;
pub mod plan;
pub mod approval;
pub mod worktree;
pub mod process;
pub mod adapters;
pub mod session;
pub mod scheduler;
pub mod status;
pub mod settings;
pub mod killswitch;
pub mod verify;
pub mod review;
pub mod lead;
