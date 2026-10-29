//! The process-wide install: nothing is installed implicitly, one install per process (own test binary, so no other
//! test can install first).

#[path = "fs_guard_support.rs"]
mod support;

mod fs_guard {
    use super::support::env;
    use harness_core::fs_guard::{self, FileGuard, GuardError, RecordingSink, RootKind};
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
            fs_guard::exec_resolve(&f),
            Err(GuardError::NotInstalled)
        ));

        let sink = Arc::new(RecordingSink::new());
        let guard = FileGuard::with_denylist(env.denylist, &env.home, sink.clone()).unwrap();
        fs_guard::install(guard).expect("first install succeeds");
        let again = FileGuard::with_denylist(env.denylist, &env.home, sink.clone()).unwrap();
        assert!(matches!(
            fs_guard::install(again),
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
        assert!(fs_guard::read_dir(&env.worktree).is_ok());
        drop(fs_guard::create_write(&env.worktree.join("w.txt")).unwrap());
        assert!(
            !sink.events().is_empty(),
            "the installed sink got the events"
        );
    }
}
