//! The process-wide install: nothing is installed implicitly, one install per process. This is the only test in the
//! crate that calls `install`, and it does everything in one function so the order is fixed.

use super::support::env;
use crate::fs_guard::{self, FileGuard, GuardError, RecordingSink, RootKind};
use std::fs;
use std::sync::Arc;

#[test]
fn global_layer_fails_closed_until_installed() {
    let env = env();
    let f = env.worktree.join("g.txt");
    fs::write(&f, b"global").unwrap();

    assert!(matches!(
        fs_guard::open_read(&f),
        Err(GuardError::NotInstalled)
    ));
    assert!(matches!(
        fs_guard::append(&f),
        Err(GuardError::NotInstalled)
    ));
    assert!(matches!(
        fs_guard::create_dir_all(&env.worktree.join("d")),
        Err(GuardError::NotInstalled)
    ));
    assert!(matches!(
        fs_guard::exec_resolve(&f),
        Err(GuardError::NotInstalled)
    ));
    assert!(matches!(
        fs_guard::hash_executable(&f),
        Err(GuardError::NotInstalled)
    ));

    let sink = Arc::new(RecordingSink::new());
    fs_guard::install(FileGuard::for_test(&[&env.home], sink.clone()))
        .expect("first install succeeds");
    assert!(matches!(
        fs_guard::install(FileGuard::for_test(&[&env.home], sink.clone())),
        Err(GuardError::AlreadyInstalled)
    ));

    // Installed, but still deny by default until a root is registered.
    assert!(matches!(
        fs_guard::read_to_string(&f),
        Err(GuardError::OutsideRoots { .. })
    ));
    fs_guard::register_root(RootKind::Worktree, &env.worktree).unwrap();
    assert_eq!(fs_guard::read_to_string(&f).unwrap(), "global");
    assert!(fs_guard::metadata(&f).unwrap().is_file());
    assert_eq!(fs_guard::read_dir(&env.worktree).unwrap().len(), 1);
    assert!(matches!(
        fs_guard::create_write(&env.worktree.join("w.txt")),
        Err(GuardError::FileMutationUnavailable)
    ));
    assert!(matches!(
        fs_guard::append(&env.worktree.join("log.jsonl")),
        Err(GuardError::FileMutationUnavailable)
    ));
    assert!(!env.worktree.join("w.txt").exists());
    assert!(!env.worktree.join("log.jsonl").exists());
    assert!(matches!(
        fs_guard::create_dir_all(&env.worktree.join("d").join("e")),
        Err(GuardError::DirectoryCreationUnavailable)
    ));
    assert!(!env.worktree.join("d").exists());
    assert!(
        !sink.events().is_empty(),
        "the installed sink got the events"
    );
}

#[test]
fn production_guard_refuses_all_access_without_opening_a_path() {
    use crate::fs_guard::open::test_hooks;
    use crate::fs_guard::{FileGuard, GuardError, NullSink, RootKind};

    let guard = FileGuard::new(
        std::path::Path::new("/fake-home"),
        std::sync::Arc::new(NullSink),
    )
    .unwrap();
    let path = std::path::Path::new("/fake-home/project");
    test_hooks::set_before_open(Some(Box::new(|| panic!("production access reached open"))));
    assert!(matches!(
        guard.register_root(RootKind::Repo, path),
        Err(GuardError::FileAccessUnavailable)
    ));
    assert!(matches!(
        guard.open_read(path),
        Err(GuardError::FileAccessUnavailable)
    ));
    assert!(matches!(
        guard.read_to_string(path),
        Err(GuardError::FileAccessUnavailable)
    ));
    assert!(matches!(
        guard.read_dir(path),
        Err(GuardError::FileAccessUnavailable)
    ));
    assert!(matches!(
        guard.metadata(path),
        Err(GuardError::FileAccessUnavailable)
    ));
    assert!(matches!(
        guard.exec_resolve(path),
        Err(GuardError::FileAccessUnavailable)
    ));
    assert!(matches!(
        guard.hash_executable(path),
        Err(GuardError::FileAccessUnavailable)
    ));
    assert!(matches!(
        guard.create_write(path),
        Err(GuardError::FileMutationUnavailable)
    ));
    assert!(matches!(
        guard.append(path),
        Err(GuardError::FileMutationUnavailable)
    ));
    assert!(matches!(
        guard.create_dir_all(path),
        Err(GuardError::DirectoryCreationUnavailable)
    ));
    test_hooks::set_before_open(None);
}
