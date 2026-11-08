//! The file-access layer with the credential denylist (hard rule 4). Owned by T-114.
//!
//! Production file access remains closed until a kernel-enforced filesystem boundary is available. The fake-home
//! tests exercise the existing checks and hashed operation trace. A trace records guard outcomes, not kernel opens.

mod denylist;
mod open;
mod sys;
#[cfg(test)]
mod tests;
mod trace;

use std::fs::{File, Metadata};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use thiserror::Error;

pub use denylist::{
    lexical_normalize, DenyMatcher, Denylist, DenylistError, EMBEDDED_DENYLIST_TOML,
};
pub use open::{DirEntry, EntryKind, FileGuard, RootKind};
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
    #[error("file changed while it was being checked")]
    ChangedDuringCheck,
    #[error("guarded directory creation is unavailable: no race-safe implementation")]
    DirectoryCreationUnavailable,
    #[error("guarded file mutation is unavailable: no kernel-enforced rename boundary")]
    FileMutationUnavailable,
    #[error("guarded file access is unavailable: no kernel-enforced rename boundary")]
    FileAccessUnavailable,
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

/// Default account home for the verified CLI lane, obtained without trusting the
/// launch environment or opening any provider configuration/credential file.
pub(crate) fn account_home() -> Result<PathBuf, GuardError> {
    Ok(sys::account_home()?)
}

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
pub fn read_dir(path: &Path) -> Result<Vec<DirEntry>, GuardError> {
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

/// See [`FileGuard::append`].
pub fn append(path: &Path) -> Result<File, GuardError> {
    installed()?.append(path)
}

/// See [`FileGuard::create_dir_all`].
pub fn create_dir_all(path: &Path) -> Result<(), GuardError> {
    installed()?.create_dir_all(path)
}

/// See [`FileGuard::exec_resolve`]. For the binary verifier (T-115) only, hence crate-private.
#[allow(dead_code)] // consumed by the binary verifier (T-115) inside this crate
pub(crate) fn exec_resolve(path: &Path) -> Result<PathBuf, GuardError> {
    installed()?.exec_resolve(path)
}

/// See [`FileGuard::hash_executable`]. For the binary verifier (T-115) only, hence crate-private.
#[allow(dead_code)] // consumed by the binary verifier (T-115) inside this crate
pub(crate) fn hash_executable(path: &Path) -> Result<[u8; 32], GuardError> {
    installed()?.hash_executable(path)
}
