//! Unit tests for the file-access layer. They live inside the crate so they can build guards over fake homes without
//! touching the real account home; `make check-fast` runs them with the other library tests.

mod canary;
mod denylist;
mod exec;
mod global;
mod links;
mod race;
mod special;
mod support;
