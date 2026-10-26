//! Harness core: lead, scheduler, adapters and compliance.
//!
//! Automation in this crate talks to provider CLIs only through documented headless or ACP transports (rule 3). It has
//! no route to an interactive terminal.

pub mod compliance;
