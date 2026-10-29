//! The one door: every open, read, listing, stat and write of an app-supplied path goes through [`FileGuard`].
//!
//! Each call runs the same pipeline: require an absolute path, refuse if the lexical form is denied, canonicalize
//! (resolving symlinks), refuse if the canonical form is denied (deny wins over every allow rule), require a registered
//! root, perform the operation, and record one [`TraceEvent`]. Files are opened with `O_NOFOLLOW` on the canonical path
//! and refused when they have more than one hard link, so a link planted inside a worktree cannot reach a credential
//! file.

use std::fs::{File, Metadata, OpenOptions, ReadDir};
use std::io::Read;
use std::path::{Component, Path, PathBuf};
use std::sync::{Arc, RwLock};

use super::denylist::{lexical_normalize, DenyMatcher, Denylist};
use super::trace::{hash_path, TraceEvent, TraceOp, TraceOutcome, TraceSink};
use super::GuardError;

/// What a registered root is for. Only the app data directory and worktrees accept writes from the app.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RootKind {
    /// The user's repository. Read only for the app.
    Repo,
    /// One worker's git worktree.
    Worktree,
    /// The app's own data directory (logs, state).
    AppData,
}

impl RootKind {
    fn writable(self) -> bool {
        matches!(self, RootKind::Worktree | RootKind::AppData)
    }
}

/// A refusal before the operation ran: which path to hash in the trace, how to label it, and the error to return.
struct Refusal {
    target: PathBuf,
    outcome: TraceOutcome,
    error: GuardError,
}

impl Refusal {
    fn denied(target: PathBuf) -> Refusal {
        let error = GuardError::Denied {
            path_hash: hash_path(&target),
        };
        Refusal {
            target,
            outcome: TraceOutcome::Denied,
            error,
        }
    }

    fn refused(target: &Path, error: GuardError) -> Refusal {
        Refusal {
            target: target.to_path_buf(),
            outcome: TraceOutcome::Refused,
            error,
        }
    }
}

/// The file-access layer for one account home and one set of registered roots.
pub struct FileGuard {
    matcher: DenyMatcher,
    roots: RwLock<Vec<(RootKind, PathBuf)>>,
    sink: Arc<dyn TraceSink>,
}

impl std::fmt::Debug for FileGuard {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("FileGuard").finish_non_exhaustive()
    }
}

impl FileGuard {
    /// Build a guard from the embedded denylist. `home` is the account's home directory, already expanded by the caller.
    pub fn new(home: &Path, sink: Arc<dyn TraceSink>) -> Result<FileGuard, GuardError> {
        let denylist = Denylist::embedded().map_err(GuardError::Denylist)?;
        FileGuard::with_denylist(denylist, home, sink)
    }

    /// Build a guard from an explicit denylist (tests).
    pub fn with_denylist(
        denylist: &Denylist,
        home: &Path,
        sink: Arc<dyn TraceSink>,
    ) -> Result<FileGuard, GuardError> {
        if !home.is_absolute() {
            return Err(GuardError::NotAbsolute);
        }
        Ok(FileGuard {
            matcher: DenyMatcher::new(denylist, home),
            roots: RwLock::new(Vec::new()),
            sink,
        })
    }

    /// Register a root the app may access. The root must exist, must not be the filesystem root and must not be denied.
    pub fn register_root(&self, kind: RootKind, path: &Path) -> Result<(), GuardError> {
        let result = self.try_register_root(kind, path);
        let outcome = match &result {
            Ok(()) => TraceOutcome::Allowed,
            Err(GuardError::Io(_)) => TraceOutcome::IoError,
            Err(GuardError::Denied { .. }) => TraceOutcome::Denied,
            Err(_) => TraceOutcome::Refused,
        };
        self.sink
            .record(TraceEvent::now(path, TraceOp::RegisterRoot, outcome));
        result
    }

    fn try_register_root(&self, kind: RootKind, path: &Path) -> Result<(), GuardError> {
        if !path.is_absolute() {
            return Err(GuardError::NotAbsolute);
        }
        if self.matcher.is_denied(&lexical_normalize(path)) {
            return Err(GuardError::Denied {
                path_hash: hash_path(path),
            });
        }
        let canonical = path.canonicalize()?;
        if self.matcher.is_denied(&canonical) {
            return Err(GuardError::Denied {
                path_hash: hash_path(&canonical),
            });
        }
        if canonical.parent().is_none() {
            return Err(GuardError::RootRejected);
        }
        let mut roots = self.roots.write().unwrap_or_else(|p| p.into_inner());
        if !roots.iter().any(|(k, p)| *k == kind && *p == canonical) {
            roots.push((kind, canonical));
        }
        Ok(())
    }

    /// Open a file for reading.
    pub fn open_read(&self, path: &Path) -> Result<File, GuardError> {
        self.run(path, TraceOp::OpenRead, false, open_file_read)
    }

    /// Read a whole file as UTF-8 text.
    pub fn read_to_string(&self, path: &Path) -> Result<String, GuardError> {
        self.run(path, TraceOp::ReadToString, false, |canon| {
            let mut file = open_file_read(canon)?;
            let mut text = String::new();
            file.read_to_string(&mut text)?;
            Ok(text)
        })
    }

    /// List a directory.
    pub fn read_dir(&self, path: &Path) -> Result<ReadDir, GuardError> {
        self.run(path, TraceOp::ReadDir, false, |canon| {
            Ok(std::fs::read_dir(canon)?)
        })
    }

    /// Stat a path (following links, after the link has been resolved and checked).
    pub fn metadata(&self, path: &Path) -> Result<Metadata, GuardError> {
        self.run(path, TraceOp::Metadata, false, |canon| {
            Ok(std::fs::metadata(canon)?)
        })
    }

    /// Create or truncate a file for writing. App-owned paths only: the path must be under a worktree or app data root.
    pub fn create_write(&self, path: &Path) -> Result<File, GuardError> {
        self.run(path, TraceOp::CreateWrite, true, open_file_write)
    }

    /// Resolve a CLI binary path for the binary verifier (rule 6) and nothing else. Returns the canonical path of a
    /// regular, executable file. It never opens the file and never lists or reads its directory, so the denylist
    /// refusals for the surrounding directory stay in force for every other call.
    pub fn exec_resolve(&self, path: &Path) -> Result<PathBuf, GuardError> {
        match self.try_exec_resolve(path) {
            Ok(canonical) => {
                self.sink.record(TraceEvent::now(
                    &canonical,
                    TraceOp::ExecResolve,
                    TraceOutcome::Allowed,
                ));
                Ok(canonical)
            }
            Err(error) => {
                let outcome = if matches!(error, GuardError::Io(_)) {
                    TraceOutcome::IoError
                } else {
                    TraceOutcome::Refused
                };
                self.sink
                    .record(TraceEvent::now(path, TraceOp::ExecResolve, outcome));
                Err(error)
            }
        }
    }

    fn try_exec_resolve(&self, path: &Path) -> Result<PathBuf, GuardError> {
        if !path.is_absolute() {
            return Err(GuardError::NotAbsolute);
        }
        let canonical = path.canonicalize()?;
        let meta = std::fs::metadata(&canonical)?;
        if !meta.is_file() {
            return Err(GuardError::NotAFile);
        }
        if !is_executable(&meta) {
            return Err(GuardError::NotExecutable);
        }
        Ok(canonical)
    }

    /// The shared pipeline: authorize, run the action on the canonical path, record one event.
    fn run<T>(
        &self,
        path: &Path,
        op: TraceOp,
        write: bool,
        action: impl FnOnce(&Path) -> Result<T, GuardError>,
    ) -> Result<T, GuardError> {
        let canonical = match self.authorize(path, write) {
            Ok(canonical) => canonical,
            Err(refusal) => {
                self.sink
                    .record(TraceEvent::now(&refusal.target, op, refusal.outcome));
                return Err(refusal.error);
            }
        };
        let result = action(&canonical);
        let outcome = match &result {
            Ok(_) => TraceOutcome::Allowed,
            Err(GuardError::Io(_)) => TraceOutcome::IoError,
            Err(_) => TraceOutcome::Refused,
        };
        self.sink.record(TraceEvent::now(&canonical, op, outcome));
        result
    }

    fn authorize(&self, path: &Path, write: bool) -> Result<PathBuf, Refusal> {
        if !path.is_absolute() {
            return Err(Refusal::refused(path, GuardError::NotAbsolute));
        }
        let lexical = lexical_normalize(path);
        if self.matcher.is_denied(&lexical) {
            return Err(Refusal::denied(lexical));
        }
        let canonical = resolve(path).map_err(|e| {
            let outcome = if matches!(e, GuardError::Io(_)) {
                TraceOutcome::IoError
            } else {
                TraceOutcome::Refused
            };
            Refusal {
                target: path.to_path_buf(),
                outcome,
                error: e,
            }
        })?;
        if self.matcher.is_denied(&canonical) {
            return Err(Refusal::denied(canonical));
        }
        let roots = self.roots.read().unwrap_or_else(|p| p.into_inner());
        let mut covered = false;
        for (kind, root) in roots.iter() {
            if canonical.starts_with(root) {
                covered = true;
                if !write || kind.writable() {
                    return Ok(canonical);
                }
            }
        }
        if covered {
            Err(Refusal::refused(&canonical, GuardError::ReadOnlyRoot))
        } else {
            let error = GuardError::OutsideRoots {
                path_hash: hash_path(&canonical),
            };
            Err(Refusal {
                target: canonical,
                outcome: TraceOutcome::OutsideRoots,
                error,
            })
        }
    }
}

/// Canonicalize `path`. When the path does not exist yet, canonicalize its deepest existing ancestor and append the
/// missing tail, so a refusal (and a write target) does not depend on the file existing. A missing tail with `..` in it
/// is refused, and so is a dangling symlink in the first missing position.
fn resolve(path: &Path) -> Result<PathBuf, GuardError> {
    match path.canonicalize() {
        Ok(canonical) => return Ok(canonical),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(GuardError::Io(e)),
    }
    let mut tail: Vec<std::ffi::OsString> = Vec::new();
    let mut prefix = path.to_path_buf();
    loop {
        let name = match prefix.components().next_back() {
            Some(Component::Normal(name)) => name.to_os_string(),
            _ => return Err(GuardError::InvalidPath),
        };
        tail.push(name);
        if !prefix.pop() {
            return Err(GuardError::InvalidPath);
        }
        match prefix.canonicalize() {
            Ok(base) => {
                if let Some(first_missing) = tail.last() {
                    // lstat of the first missing name: it exists only when it is a dangling symlink.
                    if std::fs::symlink_metadata(prefix.join(first_missing)).is_ok() {
                        return Err(GuardError::DanglingLink);
                    }
                }
                let mut out = base;
                out.extend(tail.iter().rev());
                return Ok(out);
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(GuardError::Io(e)),
        }
    }
}

fn open_file_read(canonical: &Path) -> Result<File, GuardError> {
    let mut options = OpenOptions::new();
    options.read(true);
    let file = open_nofollow(&mut options, canonical)?;
    reject_multi_link(&file)?;
    Ok(file)
}

fn open_file_write(canonical: &Path) -> Result<File, GuardError> {
    // No truncate flag: a hard-linked file must be refused before its contents are touched.
    let mut options = OpenOptions::new();
    options.write(true).create(true);
    let file = open_nofollow(&mut options, canonical)?;
    let meta = file.metadata()?;
    if !meta.is_file() {
        return Err(GuardError::NotAFile);
    }
    reject_multi_link(&file)?;
    file.set_len(0)?;
    Ok(file)
}

#[cfg(unix)]
fn open_nofollow(options: &mut OpenOptions, path: &Path) -> Result<File, GuardError> {
    use std::os::unix::fs::OpenOptionsExt;
    options.custom_flags(libc::O_NOFOLLOW);
    Ok(options.open(path)?)
}

#[cfg(not(unix))]
fn open_nofollow(options: &mut OpenOptions, path: &Path) -> Result<File, GuardError> {
    Ok(options.open(path)?)
}

#[cfg(unix)]
fn reject_multi_link(file: &File) -> Result<(), GuardError> {
    use std::os::unix::fs::MetadataExt;
    let meta = file.metadata()?;
    if meta.is_file() && meta.nlink() > 1 {
        return Err(GuardError::HardLinked);
    }
    Ok(())
}

#[cfg(not(unix))]
fn reject_multi_link(_file: &File) -> Result<(), GuardError> {
    Ok(())
}

#[cfg(unix)]
fn is_executable(meta: &Metadata) -> bool {
    use std::os::unix::fs::PermissionsExt;
    meta.permissions().mode() & 0o111 != 0
}

#[cfg(not(unix))]
fn is_executable(_meta: &Metadata) -> bool {
    true
}
