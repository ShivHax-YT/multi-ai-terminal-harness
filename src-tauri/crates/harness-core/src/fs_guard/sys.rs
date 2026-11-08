//! Operating-system calls behind the file-access layer: no-follow opens, the path of an open descriptor, directory
//! listing through a descriptor and the account home from the password database. This is the only file in the crate
//! with `unsafe` blocks; each one wraps one libc call with a checked result.

use std::ffi::{CStr, OsStr, OsString};
use std::fs::{File, OpenOptions};
use std::io;
use std::os::fd::AsRawFd;
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};

/// How a file is opened. Every kind refuses to traverse a symlink in any component of the path where the operating
/// system can (macOS `O_NOFOLLOW_ANY`) and in the final component everywhere else.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum OpenKind {
    /// Read the contents.
    Read,
    /// Open only to stat through the descriptor.
    Stat,
    /// Open a directory to list it.
    Dir,
    /// Create or open for writing. Never truncates; the caller truncates after the descriptor is verified.
    Write,
    /// Create or open for appending.
    Append,
    /// Open a CLI binary to hash it.
    ExecRead,
}

impl OpenKind {
    pub(super) fn writes(self) -> bool {
        matches!(self, OpenKind::Write | OpenKind::Append)
    }
}

#[cfg(target_os = "macos")]
const NOFOLLOW: i32 = libc::O_NOFOLLOW_ANY;
#[cfg(not(target_os = "macos"))]
const NOFOLLOW: i32 = libc::O_NOFOLLOW;

/// Open `path` (already canonical) without following symlinks. The caller must still verify the descriptor with
/// [`fd_path`].
pub(super) fn open(path: &Path, kind: OpenKind) -> io::Result<File> {
    let mut options = OpenOptions::new();
    match kind {
        OpenKind::Read | OpenKind::Stat | OpenKind::ExecRead => {
            // O_NONBLOCK so opening a FIFO planted in a worktree cannot hang the app.
            options.read(true).custom_flags(NOFOLLOW | libc::O_NONBLOCK);
        }
        OpenKind::Dir => {
            options
                .read(true)
                .custom_flags(NOFOLLOW | libc::O_DIRECTORY | libc::O_NONBLOCK);
        }
        OpenKind::Write | OpenKind::Append => {
            // Defense in depth: no lower-level path around the pre-open refusal.
            return Err(io::Error::from(io::ErrorKind::Unsupported));
        }
    }
    options.open(path)
}

/// Clear `O_NONBLOCK` on a descriptor that has been checked, so the caller gets ordinary blocking reads.
pub(super) fn clear_nonblock(file: &File) -> io::Result<()> {
    let fd = file.as_raw_fd();
    // SAFETY: F_GETFL takes no argument and only reads the descriptor's flags.
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags == -1 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: F_SETFL takes an int of flags; fd is open for the lifetime of `file`.
    if unsafe { libc::fcntl(fd, libc::F_SETFL, flags & !libc::O_NONBLOCK) } == -1 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// The path the kernel reports for an open descriptor. The layer re-runs every check on this path after each open.
#[cfg(target_os = "macos")]
pub(super) fn fd_path(file: &File) -> io::Result<PathBuf> {
    let mut buf = vec![0u8; libc::PATH_MAX as usize + 1];
    // SAFETY: F_GETPATH writes a NUL-terminated path of at most PATH_MAX bytes into the buffer we own.
    let rc = unsafe { libc::fcntl(file.as_raw_fd(), libc::F_GETPATH, buf.as_mut_ptr()) };
    if rc == -1 {
        return Err(io::Error::last_os_error());
    }
    let c = CStr::from_bytes_until_nul(&buf)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "descriptor path"))?;
    Ok(PathBuf::from(OsStr::from_bytes(c.to_bytes())))
}

#[cfg(target_os = "linux")]
pub(super) fn fd_path(file: &File) -> io::Result<PathBuf> {
    std::fs::read_link(format!("/proc/self/fd/{}", file.as_raw_fd()))
}

/// No way to learn the path of a descriptor here: fail closed.
#[cfg(not(any(target_os = "macos", target_os = "linux")))]
pub(super) fn fd_path(_file: &File) -> io::Result<PathBuf> {
    Err(io::Error::from(io::ErrorKind::Unsupported))
}

/// One name read from a directory descriptor.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct RawEntry {
    pub name: OsString,
    pub d_type: u8,
}

/// List the directory behind `dir` through its descriptor (`fdopendir`), so the listing cannot be redirected by a path
/// swapped after the open. Skips `.` and `..`.
#[cfg(any(target_os = "macos", target_os = "linux"))]
pub(super) fn list_dir(dir: &File) -> io::Result<Vec<RawEntry>> {
    let owned = dir.try_clone()?;
    let fd = std::os::fd::IntoRawFd::into_raw_fd(owned);
    // SAFETY: fd is a fresh duplicate we own; on success fdopendir takes ownership of it.
    let stream = unsafe { libc::fdopendir(fd) };
    if stream.is_null() {
        let err = io::Error::last_os_error();
        // SAFETY: fdopendir failed, so the descriptor is still ours to close.
        unsafe { libc::close(fd) };
        return Err(err);
    }
    // SAFETY: these libc calls return the writable errno slot for the current thread.
    #[cfg(target_os = "macos")]
    let errno = unsafe { libc::__error() };
    #[cfg(target_os = "linux")]
    let errno = unsafe { libc::__errno_location() };
    let mut out = Vec::new();
    let result = loop {
        // SAFETY: errno is the current thread's slot. stream is valid until closedir.
        let ent = unsafe {
            *errno = 0;
            libc::readdir(stream)
        };
        if ent.is_null() {
            // SAFETY: readdir leaves errno unchanged at EOF and sets it on error.
            let error = unsafe { *errno };
            break if error == 0 {
                Ok(out)
            } else {
                Err(io::Error::from_raw_os_error(error))
            };
        }
        // SAFETY: ent points to a valid dirent whose d_name is NUL-terminated.
        let (name, d_type) = unsafe {
            let ent = &*ent;
            (
                CStr::from_ptr(ent.d_name.as_ptr()).to_bytes().to_vec(),
                ent.d_type,
            )
        };
        if name == b"." || name == b".." {
            continue;
        }
        out.push(RawEntry {
            name: OsString::from_vec(name),
            d_type,
        });
    };
    // SAFETY: stream came from fdopendir and is closed exactly once.
    if unsafe { libc::closedir(stream) } == -1 && result.is_ok() {
        return Err(io::Error::last_os_error());
    }
    result
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
pub(super) fn list_dir(_dir: &File) -> io::Result<Vec<RawEntry>> {
    Err(io::Error::from(io::ErrorKind::Unsupported))
}

pub(super) const DT_DIR: u8 = libc::DT_DIR;
pub(super) const DT_REG: u8 = libc::DT_REG;
pub(super) const DT_LNK: u8 = libc::DT_LNK;

/// The account's home directory from the password database (`getpwuid_r`), not from `$HOME`.
pub(super) fn account_home() -> io::Result<PathBuf> {
    let mut buf = vec![0u8; 16 * 1024];
    // SAFETY: passwd is plain data; getpwuid_r fills it and points its strings into `buf`, which outlives the use.
    let mut pwd: libc::passwd = unsafe { std::mem::zeroed() };
    let mut result: *mut libc::passwd = std::ptr::null_mut();
    // SAFETY: all pointers are valid for the lengths given.
    let rc = unsafe {
        libc::getpwuid_r(
            libc::getuid(),
            &mut pwd,
            buf.as_mut_ptr().cast(),
            buf.len(),
            &mut result,
        )
    };
    if rc != 0 {
        return Err(io::Error::from_raw_os_error(rc));
    }
    if result.is_null() || pwd.pw_dir.is_null() {
        return Err(io::Error::new(io::ErrorKind::NotFound, "no account home"));
    }
    // SAFETY: pw_dir is a NUL-terminated string inside `buf`.
    let dir = unsafe { CStr::from_ptr(pwd.pw_dir) };
    let path = PathBuf::from(OsStr::from_bytes(dir.to_bytes()));
    if !path.is_absolute() {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "account home"));
    }
    Ok(path)
}
