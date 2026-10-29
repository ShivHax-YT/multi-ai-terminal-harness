//! The credential canary in unit form, the binary-verifier exception, and trace contents (hard rules 4 and 6).
#![cfg(unix)]

#[path = "fs_guard_support.rs"]
mod support;

mod fs_guard {
    use super::support::{env, lock_down, plant_all, set_mode};
    use harness_core::fs_guard::{hash_path, GuardError, TraceOp, TraceOutcome};
    use std::fs;
    use std::io::Write;
    use std::os::unix::fs::symlink;

    #[test]
    fn canary_planted_files_never_opened() {
        let env = env();
        let canaries = plant_all(&env);
        for canary in &canaries {
            lock_down(canary);
        }

        // A normal session's worth of file access: list, read, stat and write inside the registered roots.
        for i in 0..5 {
            fs::write(env.worktree.join(format!("src-{i}.rs")), b"fn main() {}").unwrap();
        }
        fs::create_dir_all(env.worktree.join("nested")).unwrap();
        fs::write(env.worktree.join("nested").join("deep.txt"), b"deep").unwrap();
        for entry in env.guard.read_dir(&env.worktree).unwrap().flatten() {
            let path = entry.path();
            if path.is_file() {
                env.guard.read_to_string(&path).unwrap();
                env.guard.open_read(&path).unwrap();
            }
            env.guard.metadata(&path).unwrap();
        }
        let mut log = env
            .guard
            .create_write(&env.appdata.join("log.txt"))
            .unwrap();
        log.write_all(b"session started").unwrap();
        drop(log);
        // The app walks its own home too (listing the account home is outside every root and refused), which must
        // not touch any planted file either.
        let _ = env.guard.read_dir(&env.home);

        let events = env.sink.events();
        assert!(events.len() >= 10, "the workload should have been traced");
        for canary in &canaries {
            assert!(
                env.sink.events_for(canary).is_empty(),
                "the layer saw a call for a planted credential file"
            );
        }
        // Belt and braces: no event of any kind carries a canary directory hash either.
        for (entry, _) in env.denylist.home_dirs().iter().zip(&canaries) {
            assert!(env.sink.events_for(&env.home.join(entry)).is_empty());
        }

        // Now go looking for them on purpose: every attempt is refused and none is ever recorded as allowed.
        env.sink.clear();
        for canary in &canaries {
            assert!(env.guard.open_read(canary).is_err());
            assert!(env.guard.read_to_string(canary).is_err());
            assert!(env.guard.metadata(canary).is_err());
            assert!(env.guard.create_write(canary).is_err());
            let seen = env.sink.events_for(canary);
            assert_eq!(seen.len(), 4);
            assert!(seen.iter().all(|e| e.outcome == TraceOutcome::Denied));
        }
        // The planted files are untouched.
        for canary in &canaries {
            set_mode(canary, 0o644);
            assert_eq!(fs::read(canary).unwrap(), b"fake-secret-do-not-read");
        }
    }

    #[test]
    fn trace_holds_hashes_not_paths() {
        let env = env();
        let f = env.worktree.join("secret-looking-name.txt");
        fs::write(&f, b"x").unwrap();
        env.guard.open_read(&f).unwrap();
        let events = env.sink.events();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].path_hash, hash_path(&f));
        assert_eq!(events[0].path_hash.len(), 64);
        let json = serde_json::to_string(&events).unwrap();
        assert!(!json.contains("secret-looking-name"));
        assert!(!json.contains(env.base.to_string_lossy().as_ref()));
        // Error messages carry a hash at most, never the path.
        let e = env
            .guard
            .open_read(&env.other.join("secret-looking-name.txt"));
        let msg = e.unwrap_err().to_string();
        assert!(!msg.contains("secret-looking-name"));
        assert!(!msg.contains(env.base.to_string_lossy().as_ref()));
    }

    // ---- binary-verifier exception (rule 6) ----------------------------------------------------------------------

    /// A fake CLI binary inside a denied home, with a sibling canary next to it.
    fn fake_cli(env: &super::support::Env) -> (std::path::PathBuf, std::path::PathBuf) {
        let entry = &env.denylist.home_dirs()[0];
        let bin_dir = env.home.join(entry).join("packages").join("bin");
        fs::create_dir_all(&bin_dir).unwrap();
        let binary = bin_dir.join("fake-cli");
        fs::write(&binary, b"#!/bin/sh\nexit 0\n").unwrap();
        set_mode(&binary, 0o755);
        let sibling = bin_dir.join("sibling-canary");
        fs::write(&sibling, b"fake-secret-do-not-read").unwrap();
        lock_down(&sibling);
        (binary, sibling)
    }

    #[test]
    fn sibling_file_unreadable() {
        let env = env();
        let (binary, sibling) = fake_cli(&env);
        let bin_dir = binary.parent().unwrap().to_path_buf();

        // The verifier may resolve the binary path...
        let resolved = env.guard.exec_resolve(&binary).unwrap();
        assert_eq!(resolved, binary);
        let ev = env.sink.events_for(&binary);
        assert_eq!(ev.len(), 1);
        assert_eq!(ev[0].op, TraceOp::ExecResolve);
        assert_eq!(ev[0].outcome, TraceOutcome::Allowed);

        // ...but the exception does not open it, nor anything next to it.
        env.sink.clear();
        assert!(matches!(
            env.guard.open_read(&binary),
            Err(GuardError::Denied { .. })
        ));
        assert!(matches!(
            env.guard.read_to_string(&sibling),
            Err(GuardError::Denied { .. })
        ));
        assert!(matches!(
            env.guard.open_read(&sibling),
            Err(GuardError::Denied { .. })
        ));
        assert!(matches!(
            env.guard.read_dir(&bin_dir),
            Err(GuardError::Denied { .. })
        ));
        assert!(matches!(
            env.guard.metadata(&sibling),
            Err(GuardError::Denied { .. })
        ));
        assert!(matches!(
            env.guard.create_write(&sibling),
            Err(GuardError::Denied { .. })
        ));
        assert!(env
            .sink
            .events()
            .iter()
            .all(|e| e.outcome == TraceOutcome::Denied));
        // The sibling is not a runnable file, so resolving it as a binary fails as well.
        assert!(matches!(
            env.guard.exec_resolve(&sibling),
            Err(GuardError::NotExecutable)
        ));
        set_mode(&sibling, 0o644);
        assert_eq!(fs::read(&sibling).unwrap(), b"fake-secret-do-not-read");
    }

    #[test]
    fn exec_resolve_follows_links_to_the_real_binary() {
        let env = env();
        let (binary, _sibling) = fake_cli(&env);
        let link_dir = env.base.join("usr-bin");
        fs::create_dir_all(&link_dir).unwrap();
        let link = link_dir.join("fake-cli");
        symlink(&binary, &link).unwrap();
        // The link directory is not a registered root; exec_resolve does not need one.
        assert_eq!(env.guard.exec_resolve(&link).unwrap(), binary);
    }

    #[test]
    fn exec_resolve_refuses_non_binaries() {
        let env = env();
        let dir = env.worktree.join("d");
        fs::create_dir_all(&dir).unwrap();
        let text = env.worktree.join("notes.txt");
        fs::write(&text, b"x").unwrap();
        set_mode(&text, 0o644);
        assert!(matches!(
            env.guard.exec_resolve(&dir),
            Err(GuardError::NotAFile)
        ));
        assert!(matches!(
            env.guard.exec_resolve(&text),
            Err(GuardError::NotExecutable)
        ));
        assert!(matches!(
            env.guard.exec_resolve(&env.worktree.join("missing")),
            Err(GuardError::Io(_))
        ));
        assert!(matches!(
            env.guard.exec_resolve(std::path::Path::new("fake-cli")),
            Err(GuardError::NotAbsolute)
        ));
        assert!(env
            .sink
            .events()
            .iter()
            .all(|e| e.op == TraceOp::ExecResolve && e.outcome != TraceOutcome::Allowed));
    }
}
