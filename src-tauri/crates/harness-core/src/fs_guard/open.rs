//! Guarded read checks and pre-mutation refusals for app-supplied paths.
//! This is not a complete same-user real-directory-rename boundary. Descriptor checks and operation traces cannot
//! prove that no prohibited open occurred. Do not enable native repository/worker access on these checks alone.
//!
//! Each call runs the same pipeline:
//! 1. require an absolute path and refuse if its lexical form is denied;
//! 2. canonicalize (resolving symlinks) and refuse if the canonical form is denied (deny wins over every allow rule);
//! 3. require a registered root (a writable one for writes);
//! 4. open the canonical path without following any symlink (`O_NOFOLLOW_ANY` on macOS);
//! 5. ask the kernel which path the open descriptor really refers to and re-run the denylist and root checks on it, so
//!    a parent directory swapped for a symlink between steps 2 and 4 cannot reach a denied file;
//! 6. read, list or stat through that descriptor, never through the path again;
//! 7. record one [`TraceEvent`].
//!
//! Regular files with more than one hard link are refused. File creation, truncation, append and directory creation
//! are unavailable; no writable handle is returned.

use std::ffi::{OsStr, OsString};
use std::fs::{self, File, Metadata};
use std::io::Read;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Component, Path, PathBuf};
use std::sync::{Arc, RwLock};

use sha2::{Digest, Sha256};

use super::denylist::{lexical_normalize, DenyMatcher, Denylist};
use super::sys::{self, OpenKind};
use super::trace::{hash_path, TraceEvent, TraceOp, TraceOutcome, TraceSink};
use super::GuardError;

/// File names the binary verifier may resolve and hash even inside a denied CLI home (hard rule 6). Nothing else in a
/// denied directory is reachable through [`FileGuard::exec_resolve`] or [`FileGuard::hash_executable`].
pub(crate) const CLI_BINARY_NAMES: [&str; 5] = ["claude", "codex", "grok", "kimi", "gemini"];

fn is_cli_binary_name(name: Option<&OsStr>) -> bool {
    name.and_then(OsStr::to_str)
        .is_some_and(|n| CLI_BINARY_NAMES.contains(&n))
}

#[cfg(test)]
pub(crate) mod test_hooks {
    use std::cell::RefCell;

    type Hook = Box<dyn FnMut()>;

    thread_local! {
        static BEFORE_OPEN: RefCell<Option<Hook>> = const { RefCell::new(None) };
    }

    /// Run `hook` on this thread between the path checks and the open of every guarded call, until cleared.
    pub(crate) fn set_before_open(hook: Option<Hook>) {
        BEFORE_OPEN.with(|h| *h.borrow_mut() = hook);
    }

    pub(super) fn before_open() {
        BEFORE_OPEN.with(|h| {
            if let Some(hook) = h.borrow_mut().as_mut() {
                hook();
            }
        });
    }
}

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

/// What a directory entry is, as reported by the directory itself (not followed).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EntryKind {
    File,
    Dir,
    Symlink,
    Other,
}

/// One entry of a guarded directory listing. `path` is under the verified directory; using it still goes through the
/// guard.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DirEntry {
    name: OsString,
    path: PathBuf,
    kind: EntryKind,
}

impl DirEntry {
    pub fn file_name(&self) -> &OsStr {
        &self.name
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn kind(&self) -> EntryKind {
        self.kind
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
            outcome: outcome_for(&error),
            error,
        }
    }
}

fn outcome_for(error: &GuardError) -> TraceOutcome {
    match error {
        GuardError::Denied { .. } => TraceOutcome::Denied,
        GuardError::OutsideRoots { .. } => TraceOutcome::OutsideRoots,
        GuardError::Io(_) => TraceOutcome::IoError,
        _ => TraceOutcome::Refused,
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
    /// Build a guard from the embedded denylist. `home` is the caller's home directory, already expanded by the
    /// caller. The denylist is applied under both `home` and the account home from the password database, so a wrong
    /// or spoofed `home` cannot hide the real one.
    pub fn new(home: &Path, sink: Arc<dyn TraceSink>) -> Result<FileGuard, GuardError> {
        let denylist = Denylist::embedded().map_err(GuardError::Denylist)?;
        let homes = FileGuard::homes_for(home)?;
        Ok(FileGuard::build(denylist, &homes, sink))
    }

    /// The homes the denylist covers for a caller-supplied `home`.
    pub(crate) fn homes_for(home: &Path) -> Result<Vec<PathBuf>, GuardError> {
        if !home.is_absolute() {
            return Err(GuardError::NotAbsolute);
        }
        let account = sys::account_home()?;
        let mut homes = vec![account];
        if !homes.iter().any(|h| h == home) {
            homes.push(home.to_path_buf());
        }
        Ok(homes)
    }

    pub(crate) fn build(
        denylist: &Denylist,
        homes: &[PathBuf],
        sink: Arc<dyn TraceSink>,
    ) -> FileGuard {
        FileGuard {
            matcher: DenyMatcher::new(denylist, homes),
            roots: RwLock::new(Vec::new()),
            sink,
        }
    }

    /// A guard over fake homes only, for unit tests. Never looks at the real account home.
    #[cfg(test)]
    pub(crate) fn for_test(homes: &[&Path], sink: Arc<dyn TraceSink>) -> FileGuard {
        let denylist = Denylist::embedded().expect("embedded denylist");
        let homes: Vec<PathBuf> = homes.iter().map(|h| h.to_path_buf()).collect();
        FileGuard::build(denylist, &homes, sink)
    }

    /// Register a root the app may access. The root must exist, must not be the filesystem root and must not be denied.
    pub fn register_root(&self, kind: RootKind, path: &Path) -> Result<(), GuardError> {
        let result = self.try_register_root(kind, path);
        self.sink.record(TraceEvent::now(
            path,
            TraceOp::RegisterRoot,
            match &result {
                Ok(()) => TraceOutcome::Allowed,
                Err(e) => outcome_for(e),
            },
        ));
        result
    }

    fn try_register_root(&self, kind: RootKind, path: &Path) -> Result<(), GuardError> {
        if !path.is_absolute() {
            return Err(GuardError::NotAbsolute);
        }
        let snap = self.matcher.snapshot();
        if snap.is_denied(&lexical_normalize(path)) {
            return Err(GuardError::Denied {
                path_hash: hash_path(path),
            });
        }
        let canonical = path.canonicalize()?;
        if snap.is_denied(&canonical) || snap.identity_denied(&canonical) {
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
        self.run(path, TraceOp::OpenRead, false, |canon| {
            Ok(self.open_checked(canon, OpenKind::Read)?.0)
        })
    }

    /// Read a whole file as UTF-8 text.
    pub fn read_to_string(&self, path: &Path) -> Result<String, GuardError> {
        self.run(path, TraceOp::ReadToString, false, |canon| {
            let (mut file, _) = self.open_checked(canon, OpenKind::Read)?;
            let mut text = String::new();
            file.read_to_string(&mut text)?;
            Ok(text)
        })
    }

    /// List a directory, through a descriptor that has been verified.
    pub fn read_dir(&self, path: &Path) -> Result<Vec<DirEntry>, GuardError> {
        self.run(path, TraceOp::ReadDir, false, |canon| {
            let (dir, verified) = self.open_checked(canon, OpenKind::Dir)?;
            let entries = sys::list_dir(&dir)?
                .into_iter()
                .map(|raw| DirEntry {
                    path: verified.join(&raw.name),
                    kind: match raw.d_type {
                        sys::DT_REG => EntryKind::File,
                        sys::DT_DIR => EntryKind::Dir,
                        sys::DT_LNK => EntryKind::Symlink,
                        _ => EntryKind::Other,
                    },
                    name: raw.name,
                })
                .collect();
            Ok(entries)
        })
    }

    /// Stat a path through a verified descriptor.
    pub fn metadata(&self, path: &Path) -> Result<Metadata, GuardError> {
        self.run(path, TraceOp::Metadata, false, |canon| {
            let (file, _) = self.open_checked(canon, OpenKind::Stat)?;
            Ok(file.metadata()?)
        })
    }

    /// Unavailable: pathname checks cannot authorize creation/truncation atomically with a
    /// same-user parent rename, and a returned writable handle would outlive its authorization.
    pub fn create_write(&self, path: &Path) -> Result<File, GuardError> {
        self.run(path, TraceOp::CreateWrite, true, |canon| {
            Ok(self.open_checked(canon, OpenKind::Write)?.0)
        })
    }

    /// Unavailable for the same reason as [`FileGuard::create_write`]. Never returns a writable handle.
    pub fn append(&self, path: &Path) -> Result<File, GuardError> {
        self.run(path, TraceOp::Append, true, |canon| {
            Ok(self.open_checked(canon, OpenKind::Append)?.0)
        })
    }

    /// Directory creation is unavailable until authorization and mutation can be made race-safe.
    /// Post-creation descriptor checks cannot undo a write into a protected directory. In particular,
    /// pinning a parent descriptor does not stop that parent being renamed into a denied subtree.
    pub fn create_dir_all(&self, path: &Path) -> Result<(), GuardError> {
        self.run(path, TraceOp::CreateDirAll, true, |_canon| {
            #[cfg(test)]
            test_hooks::before_open();
            Err(GuardError::DirectoryCreationUnavailable)
        })
    }

    /// Resolve a CLI binary path for the binary verifier (rule 6) and nothing else. Returns the canonical path of a
    /// regular, executable file. It never opens the file and never lists or reads its directory.
    ///
    /// The denylist still applies: a path inside a denied directory (or reached through a link that ends there) is
    /// refused with the same `Denied` error whether or not it exists, unless its file name is one of the five CLI binary
    /// names. That one exception exists because some official installers put the binary inside the CLI's own home.
    /// Inside a denied directory the real file must carry one of those names; elsewhere any regular executable passes.
    #[allow(dead_code)] // consumed by the binary verifier (T-115) inside this crate
    pub(crate) fn exec_resolve(&self, path: &Path) -> Result<PathBuf, GuardError> {
        let result = self.exec_target(path).map(|(canonical, _)| canonical);
        self.record_exec(path, TraceOp::ExecResolve, &result);
        result
    }

    /// SHA-256 of a CLI binary, computed inside the layer so the verifier (T-115) never holds a file handle. Same
    /// checks and the same one exception as [`FileGuard::exec_resolve`]; the descriptor is checked to be the very file
    /// that was vetted, and nothing else in its directory is opened, listed or read.
    #[allow(dead_code)] // consumed by the binary verifier (T-115) inside this crate
    pub(crate) fn hash_executable(&self, path: &Path) -> Result<[u8; 32], GuardError> {
        let result = self.try_hash_executable(path);
        self.record_exec(path, TraceOp::ExecHash, &result);
        result
    }

    fn try_hash_executable(&self, path: &Path) -> Result<[u8; 32], GuardError> {
        let (canonical, meta) = self.exec_target(path)?;
        #[cfg(test)]
        test_hooks::before_open();
        let mut file = sys::open(&canonical, OpenKind::ExecRead)?;
        let opened = file.metadata()?;
        if !opened.is_file()
            || opened.dev() != meta.dev()
            || opened.ino() != meta.ino()
            || !is_executable(&opened)
        {
            return Err(GuardError::ChangedDuringCheck);
        }
        let mut hasher = Sha256::new();
        let mut buf = [0u8; 64 * 1024];
        loop {
            let n = file.read(&mut buf)?;
            if n == 0 {
                break;
            }
            hasher.update(&buf[..n]);
        }
        Ok(hasher.finalize().into())
    }

    fn record_exec<T>(&self, path: &Path, op: TraceOp, result: &Result<T, GuardError>) {
        let (target, outcome) = match result {
            Ok(_) => (
                path.canonicalize().unwrap_or_else(|_| path.to_path_buf()),
                TraceOutcome::Allowed,
            ),
            Err(e) => (lexical_normalize(path), outcome_for(e)),
        };
        self.sink.record(TraceEvent::now(&target, op, outcome));
    }

    /// The checks shared by `exec_resolve` and `hash_executable`. Returns the canonical path and its metadata.
    fn exec_target(&self, path: &Path) -> Result<(PathBuf, Metadata), GuardError> {
        if !path.is_absolute() {
            return Err(GuardError::NotAbsolute);
        }
        let snap = self.matcher.snapshot();
        let lexical = lexical_normalize(path);
        let requested_ok = is_cli_binary_name(lexical.file_name());
        if snap.is_denied(&lexical) && !requested_ok {
            return Err(GuardError::Denied {
                path_hash: hash_path(&lexical),
            });
        }
        let canonical = resolve(path)?;
        // Inside a denied directory the real file itself must carry a CLI binary name; a link with such a name
        // pointing at some other file there is not enough.
        let name_ok = is_cli_binary_name(canonical.file_name());
        if (snap.is_denied(&canonical) || snap.identity_denied(&canonical)) && !name_ok {
            return Err(GuardError::Denied {
                path_hash: hash_path(&canonical),
            });
        }
        let meta = fs::metadata(&canonical)?;
        if snap.is_denied_object(&meta) {
            return Err(GuardError::Denied {
                path_hash: hash_path(&canonical),
            });
        }
        if !meta.is_file() {
            return Err(GuardError::NotAFile);
        }
        if !is_executable(&meta) {
            return Err(GuardError::NotExecutable);
        }
        Ok((canonical, meta))
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
            Err(e) => outcome_for(e),
        };
        self.sink.record(TraceEvent::now(&canonical, op, outcome));
        result
    }

    fn authorize(&self, path: &Path, write: bool) -> Result<PathBuf, Refusal> {
        if !path.is_absolute() {
            return Err(Refusal::refused(path, GuardError::NotAbsolute));
        }
        let snap = self.matcher.snapshot();
        let lexical = lexical_normalize(path);
        if snap.is_denied(&lexical) {
            return Err(Refusal::denied(lexical));
        }
        let canonical = resolve(path).map_err(|e| Refusal::refused(path, e))?;
        if snap.is_denied(&canonical) || snap.identity_denied(&canonical) {
            return Err(Refusal::denied(canonical));
        }
        self.check_roots(&canonical, write)
            .map_err(|e| Refusal::refused(&canonical, e))?;
        Ok(canonical)
    }

    fn check_roots(&self, canonical: &Path, write: bool) -> Result<(), GuardError> {
        let roots = self.roots.read().unwrap_or_else(|p| p.into_inner());
        let mut covered = false;
        for (kind, root) in roots.iter() {
            if canonical.starts_with(root) {
                covered = true;
                if !write || kind.writable() {
                    return Ok(());
                }
            }
        }
        if covered {
            Err(GuardError::ReadOnlyRoot)
        } else {
            Err(GuardError::OutsideRoots {
                path_hash: hash_path(canonical),
            })
        }
    }

    /// Open `canonical` without following links, then verify the descriptor: the path the kernel reports for it must
    /// pass the denylist (by name and by device/inode) and the root checks. Returns the file and the verified path.
    ///
    /// Before the open, the final path is examined with `lstat`: it must be a regular file (or a directory where that
    /// is allowed) with a single hard link, so a credential inode reached through a hard link or a special file such as
    /// a FIFO is refused without ever being opened. After the open, the descriptor is examined again and must be the
    /// same object (device and inode). `O_NONBLOCK` is cleared only once everything has passed.
    fn open_checked(
        &self,
        canonical: &Path,
        kind: OpenKind,
    ) -> Result<(File, PathBuf), GuardError> {
        let before = match fs::symlink_metadata(canonical) {
            Ok(meta) => {
                check_object(&meta, kind)?;
                Some(meta)
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
            Err(e) => return Err(e.into()),
        };
        #[cfg(test)]
        test_hooks::before_open();
        // Refuse BEFORE open(O_CREAT), truncation, or handing out a writable descriptor.
        // Neither O_NOFOLLOW_ANY nor F_GETPATH prevents a real parent-directory rename.
        if kind.writes() {
            return Err(GuardError::FileMutationUnavailable);
        }
        let file = sys::open(canonical, kind)?;
        let verified = self.verify_fd(&file, kind.writes())?;
        let opened = file.metadata()?;
        check_object(&opened, kind)?;
        if let Some(before) = &before {
            if before.dev() != opened.dev() || before.ino() != opened.ino() {
                return Err(GuardError::ChangedDuringCheck);
            }
        }
        sys::clear_nonblock(&file)?;
        Ok((file, verified))
    }

    /// Re-run the denylist and root checks on the path an open descriptor really refers to.
    pub(crate) fn verify_fd(&self, file: &File, write: bool) -> Result<PathBuf, GuardError> {
        let path = sys::fd_path(file)?;
        let snap = self.matcher.snapshot();
        if snap.is_denied(&path) || snap.identity_denied(&path) {
            return Err(GuardError::Denied {
                path_hash: hash_path(&path),
            });
        }
        self.check_roots(&path, write)?;
        Ok(path)
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
    let mut tail: Vec<OsString> = Vec::new();
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
                    if fs::symlink_metadata(prefix.join(first_missing)).is_ok() {
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

/// Refuse anything but a regular file (or a directory where `kind` allows one), and any regular file with more than
/// one hard link. FIFOs, sockets, devices and symlinks never get opened.
fn check_object(meta: &Metadata, kind: OpenKind) -> Result<(), GuardError> {
    let ft = meta.file_type();
    let acceptable = match kind {
        OpenKind::Dir => ft.is_dir(),
        OpenKind::Read | OpenKind::Stat => ft.is_file() || ft.is_dir(),
        OpenKind::Write | OpenKind::Append | OpenKind::ExecRead => ft.is_file(),
    };
    if !acceptable {
        return Err(GuardError::NotAFile);
    }
    if ft.is_file() && meta.nlink() > 1 {
        return Err(GuardError::HardLinked);
    }
    Ok(())
}

fn is_executable(meta: &Metadata) -> bool {
    meta.permissions().mode() & 0o111 != 0
}
