//! The file-access layer with the credential denylist (hard rule 4). Owned by T-114.
//!
//! App code opens files outside the repo or a worktree only through this module. Every call checks the denylist first
//! (deny wins over any allow rule), requires a registered root, and records one trace event holding a hash of the path.
//! The credential canary reads that trace to prove the app never opened a planted credential file.
//!
//! Use a [`FileGuard`] directly, or [`install`] one process-wide and call the free functions. Nothing is installed
//! implicitly: until [`install`] runs, the free functions fail closed with [`GuardError::NotInstalled`].

mod denylist;
mod open;
mod trace;

use std::fs::{File, Metadata, ReadDir};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use thiserror::Error;

pub use denylist::{
    lexical_normalize, DenyMatcher, Denylist, DenylistError, EMBEDDED_DENYLIST_TOML,
};
pub use open::{FileGuard, RootKind};
pub use trace::{hash_path, NullSink, RecordingSink, TraceEvent, TraceOp, TraceOutcome, TraceSink};

/// Why the layer refused or failed a call. Messages carry a path hash at most, never a path.
#[derive(Debug, Error)]
pub enum GuardError {
    #[error("path is on the credential denylist (hash {path_hash})")]
    Denied { path_hash: String },
    #[error("path is outside every registered root (hash {path_hash})")]
    OutsideRoots { path_hash: String },
    #[error("path is under a read-only root")]
    ReadOnlyRoot,
    #[error("path must be absolute")]
    NotAbsolute,
    #[error("path cannot be resolved safely")]
    InvalidPath,
    #[error("path is a dangling symbolic link")]
    DanglingLink,
    #[error("file has more than one hard link")]
    HardLinked,
    #[error("not a regular file")]
    NotAFile,
    #[error("file is not executable")]
    NotExecutable,
    #[error("root rejected")]
    RootRejected,
    #[error("denylist unusable: {0}")]
    Denylist(DenylistError),
    #[error("file-access layer is not installed")]
    NotInstalled,
    #[error("file-access layer is already installed")]
    AlreadyInstalled,
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
}

static INSTALLED: OnceLock<FileGuard> = OnceLock::new();

/// Make `guard` the process-wide layer. Can succeed once per process.
pub fn install(guard: FileGuard) -> Result<(), GuardError> {
    INSTALLED
        .set(guard)
        .map_err(|_| GuardError::AlreadyInstalled)
}

fn installed() -> Result<&'static FileGuard, GuardError> {
    INSTALLED.get().ok_or(GuardError::NotInstalled)
}

/// See [`FileGuard::register_root`].
pub fn register_root(kind: RootKind, path: &Path) -> Result<(), GuardError> {
    installed()?.register_root(kind, path)
}

/// See [`FileGuard::open_read`].
pub fn open_read(path: &Path) -> Result<File, GuardError> {
    installed()?.open_read(path)
}

/// See [`FileGuard::read_to_string`].
pub fn read_to_string(path: &Path) -> Result<String, GuardError> {
    installed()?.read_to_string(path)
}

/// See [`FileGuard::read_dir`].
pub fn read_dir(path: &Path) -> Result<ReadDir, GuardError> {
    installed()?.read_dir(path)
}

/// See [`FileGuard::metadata`].
pub fn metadata(path: &Path) -> Result<Metadata, GuardError> {
    installed()?.metadata(path)
}

/// See [`FileGuard::create_write`].
pub fn create_write(path: &Path) -> Result<File, GuardError> {
    installed()?.create_write(path)
}

/// See [`FileGuard::exec_resolve`]. For the binary verifier (T-115) only.
pub fn exec_resolve(path: &Path) -> Result<PathBuf, GuardError> {
    installed()?.exec_resolve(path)
}
