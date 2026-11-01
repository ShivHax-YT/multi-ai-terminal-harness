//! The native simulated worker stays fail-closed while guarded directory creation is unavailable.
//! Git must not be used as an indirect mkdir/checkout bypass around the file-access boundary.
use serde::Serialize;

#[derive(Clone, Debug, Serialize)]
pub struct SampleResult {
    pub isolation: String,
    pub worktree: String,
    pub output: String,
    pub diff: String,
    pub source_unchanged: bool,
}

pub(crate) fn run_sample(_task: &str) -> Result<SampleResult, String> {
    // No filesystem calls or child processes. A private directory alone cannot prevent a
    // same-user pathname swap before Git starts. Never claim worktree isolation until safe.
    Err("Native worktree execution is unavailable: guarded directory creation is blocked. No files were changed and no worker was started. Use the browser memory demo to try the workflow.".into())
}
