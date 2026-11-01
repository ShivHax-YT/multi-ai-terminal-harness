//! Bounded native CLI probes, separate from worker execution (T-133).
//!
//! The kernel permits only pinned signed native images. This does not provide a filesystem
//! sandbox for Git, workers, or tests, which remain unavailable.

#[cfg(target_os = "macos")]
mod signed_probe;

#[derive(Debug, thiserror::Error)]
pub(crate) enum ProbeError {
    #[error("the operating system refused the native CLI launch")]
    Verification,
    #[error("the CLI probe exceeded its time limit")]
    Timeout,
    #[error("the CLI probe exceeded its output limit")]
    OutputLimit,
    #[error("the CLI probe could not be completed")]
    Failed,
    #[error("the official CLI has not stopped; further probes are blocked until it exits")]
    CleanupPending,
    #[error("verified native CLI probes are unavailable on this platform")]
    Unsupported,
}

pub(crate) struct Capture {
    pub code: i32,
    pub stdout: String,
    pub stderr: String,
}

#[derive(Clone, Copy)]
pub(crate) struct SignaturePolicy {
    pub team: &'static str,
    pub identifier: &'static str,
    pub release_cdhash: &'static str,
    pub platform_test: bool,
}

pub(crate) fn probe(
    path: &std::path::Path,
    home: &std::path::Path,
    policy: SignaturePolicy,
    args: &[&str],
) -> Result<Capture, ProbeError> {
    #[cfg(target_os = "macos")]
    {
        signed_probe::run(path, home, policy, args, std::time::Duration::from_secs(20))
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (path, home, policy, args);
        Err(ProbeError::Unsupported)
    }
}

pub(crate) fn terminal_login(
    path: &std::path::Path,
    home: &std::path::Path,
    policy: SignaturePolicy,
    args: &[&str],
) -> Result<i32, ProbeError> {
    #[cfg(target_os = "macos")]
    {
        signed_probe::terminal_login(path, home, policy, args)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (path, home, policy, args);
        Err(ProbeError::Unsupported)
    }
}
