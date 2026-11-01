//! Special files: a FIFO (or anything that is not a regular file) must produce a prompt error, never a hang and
//! never a read. A blocked open would stall the whole app.

use super::support::env;
use crate::fs_guard::open::test_hooks;
use crate::fs_guard::GuardError;
use std::ffi::CString;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::sync::mpsc;
use std::time::Duration;

fn mkfifo(path: &Path) {
    let c = CString::new(path.as_os_str().as_bytes()).unwrap();
    // SAFETY: c is a valid NUL-terminated path; mkfifo only creates a filesystem entry.
    let rc = unsafe { libc::mkfifo(c.as_ptr(), 0o600) };
    assert_eq!(rc, 0, "mkfifo failed");
}

#[test]
fn a_fifo_in_a_root_is_refused_promptly_by_every_call() {
    let env = env();
    let fifo = env.worktree.join("pipe");
    mkfifo(&fifo);
    let (tx, rx) = mpsc::channel();
    // The calls run on their own thread so a regression shows up as a timeout instead of a hung test run.
    let worker = std::thread::spawn(move || {
        let g = &env.guard;
        let results = vec![
            g.open_read(&fifo).map(|_| ()),
            g.read_to_string(&fifo).map(|_| ()),
            g.metadata(&fifo).map(|_| ()),
            g.create_write(&fifo).map(|_| ()),
            g.append(&fifo).map(|_| ()),
            g.read_dir(&fifo).map(|_| ()),
        ];
        tx.send(results).unwrap();
    });
    let results = rx
        .recv_timeout(Duration::from_secs(10))
        .expect("a call on a FIFO hung");
    worker.join().unwrap();
    for r in &results {
        assert!(matches!(r, Err(GuardError::NotAFile)), "{r:?}");
    }
}

#[test]
fn a_fifo_is_refused_before_it_is_opened() {
    let env = env();
    let fifo = env.worktree.join("pipe");
    mkfifo(&fifo);
    let reached = std::rc::Rc::new(std::cell::Cell::new(false));
    let flag = reached.clone();
    test_hooks::set_before_open(Some(Box::new(move || flag.set(true))));
    let r = env.guard.open_read(&fifo);
    test_hooks::set_before_open(None);
    assert!(matches!(r, Err(GuardError::NotAFile)));
    assert!(!reached.get(), "the FIFO was opened");
}

#[test]
fn a_file_swapped_for_a_fifo_after_the_precheck_is_refused_without_blocking() {
    let env = env();
    let target = env.worktree.join("t.txt");
    std::fs::write(&target, b"plain").unwrap();
    let (tx, rx) = mpsc::channel();
    // The hook is thread-local, so it is installed on the thread that makes the call.
    let worker = std::thread::spawn(move || {
        let t2 = target.clone();
        test_hooks::set_before_open(Some(Box::new(move || {
            std::fs::remove_file(&t2).unwrap();
            mkfifo(&t2);
        })));
        let r = env.guard.read_to_string(&target).map(|_| ());
        test_hooks::set_before_open(None);
        tx.send(r).unwrap();
    });
    let r = rx
        .recv_timeout(Duration::from_secs(10))
        .expect("opening a swapped-in FIFO hung");
    worker.join().unwrap();
    assert!(
        matches!(
            r,
            Err(GuardError::NotAFile | GuardError::ChangedDuringCheck)
        ),
        "{r:?}"
    );
}

#[test]
fn returned_files_are_blocking_again() {
    use std::os::fd::AsRawFd;
    let env = env();
    let f = env.worktree.join("plain.txt");
    std::fs::write(&f, b"x").unwrap();
    let file = env.guard.open_read(&f).unwrap();
    // SAFETY: F_GETFL only reads the flags of a descriptor that `file` keeps open.
    let flags = unsafe { libc::fcntl(file.as_raw_fd(), libc::F_GETFL) };
    assert!(flags >= 0);
    assert_eq!(flags & libc::O_NONBLOCK, 0, "O_NONBLOCK left set");
    assert!(matches!(
        env.guard.append(&f),
        Err(GuardError::FileMutationUnavailable)
    ));
    assert_eq!(std::fs::read(&f).unwrap(), b"x");
}
