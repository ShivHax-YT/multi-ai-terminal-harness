//! User presence, supplied by the app. This module never infers it.

use serde::{Deserialize, Serialize};

/// What the app reports about the user. Defaults to present and in the foreground.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Presence {
    /// Whole minutes since the user last used the machine.
    pub idle_minutes: u32,
    pub app_in_background: bool,
}
