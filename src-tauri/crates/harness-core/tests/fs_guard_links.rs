//! Link tricks: symlinks, hard links, dangling and looping links cannot reach a denied path (hard rule 4).
#![cfg(unix)]

#[path = "fs_guard_support.rs"]
mod support;

mod fs_guard {
    use super::support::{env, plant_all, set_mode};
    use harness_core::fs_guard::{GuardError, TraceOutcome};
    use std::fs;
    use std::os::unix::fs::symlink;

    #[test]
    fn symlink_into_denied_refused() {
        let env = env();
        let canaries = plant_all(&env);
        for (i, (entry, canary)) in env.denylist.home_dirs().iter().zip(&canaries).enumerate() {
            // A link from inside the worktree to a denied directory.
            let dir_link = env.worktree.join(format!("dir-link-{i}"));
            symlink(env.home.join(entry), &dir_link).unwrap();
            // A link straight to the canary file.
            let file_link = env.worktree.join(format!("file-link-{i}"));
            symlink(canary, &file_link).unwrap();
            // A relative link that climbs out of the worktree.
            let rel_link = env.worktree.join(format!("rel-link-{i}"));
            symlink(format!("../home/{entry}/canary.txt"), &rel_link).unwrap();

            let g = &env.guard;
            let through_dir = dir_link.join("canary.txt");
            for target in [&through_dir, &file_link, &rel_link] {
                assert!(matches!(
                    g.open_read(target),
                    Err(GuardError::Denied { .. })
                ));
                assert!(matches!(
                    g.read_to_string(target),
                    Err(GuardError::Denied { .. })
                ));
                assert!(matches!(g.metadata(target), Err(GuardError::Denied { .. })));
                assert!(matches!(
                    g.create_write(target),
                    Err(GuardError::Denied { .. })
                ));
            }
            assert!(matches!(
                g.read_dir(&dir_link),
                Err(GuardError::Denied { .. })
            ));
            assert!(matches!(
                g.create_write(&dir_link.join("new-file")),
                Err(GuardError::Denied { .. })
            ));
            assert!(
                !env.home.join(entry).join("new-file").exists(),
                "nothing may be created through the link"
            );
        }
        assert!(env
            .sink
            .events()
            .iter()
            .all(|e| e.outcome == TraceOutcome::Denied));
    }

    #[test]
    fn symlinked_home_spelling_is_still_denied() {
        let env = env();
        let canaries = plant_all(&env);
        let alias = env.base.join("home-alias");
        symlink(&env.home, &alias).unwrap();
        for (entry, _) in env.denylist.home_dirs().iter().zip(&canaries) {
            let via_alias = alias.join(entry).join("canary.txt");
            assert!(matches!(
                env.guard.open_read(&via_alias),
                Err(GuardError::Denied { .. })
            ));
        }
        // And a guard told about the alias spelling of the home still covers the real one.
        let sink = std::sync::Arc::new(harness_core::fs_guard::RecordingSink::new());
        let g =
            harness_core::fs_guard::FileGuard::with_denylist(env.denylist, &alias, sink).unwrap();
        g.register_root(harness_core::fs_guard::RootKind::AppData, &env.base)
            .unwrap();
        for canary in &canaries {
            assert!(matches!(
                g.open_read(canary),
                Err(GuardError::Denied { .. })
            ));
        }
    }

    #[test]
    fn symlink_out_of_roots_is_refused_as_outside() {
        let env = env();
        let stray = env.other.join("stray.txt");
        fs::write(&stray, b"x").unwrap();
        let link = env.worktree.join("to-stray");
        symlink(&stray, &link).unwrap();
        assert!(matches!(
            env.guard.open_read(&link),
            Err(GuardError::OutsideRoots { .. })
        ));
    }

    #[test]
    fn dangling_symlink_into_denied_home_is_refused() {
        let env = env();
        let first = &env.denylist.home_dirs()[0];
        // The target does not exist, so a plain canonicalize fails; the layer must not fall back to following it.
        let target = env.home.join(first).join("not-created-yet");
        let link = env.worktree.join("dangling");
        symlink(&target, &link).unwrap();
        assert!(matches!(
            env.guard.create_write(&link),
            Err(GuardError::DanglingLink)
        ));
        assert!(matches!(
            env.guard.open_read(&link),
            Err(GuardError::DanglingLink)
        ));
        assert!(!target.exists(), "the write must not create the target");
        assert!(!env.home.join(first).exists());
    }

    #[test]
    fn symlink_loop_is_an_error_not_a_hang() {
        let env = env();
        let a = env.worktree.join("a");
        let b = env.worktree.join("b");
        symlink(&b, &a).unwrap();
        symlink(&a, &b).unwrap();
        assert!(env.guard.open_read(&a).is_err());
        assert!(env.guard.create_write(&a).is_err());
    }

    #[test]
    fn hard_link_to_a_credential_file_is_refused() {
        let env = env();
        let canaries = plant_all(&env);
        for (i, canary) in canaries.iter().enumerate() {
            set_mode(canary, 0o644);
            let linked = env.worktree.join(format!("hard-{i}"));
            fs::hard_link(canary, &linked).unwrap();
            // The path looks harmless; the layer refuses a regular file with more than one link.
            assert!(matches!(
                env.guard.open_read(&linked),
                Err(GuardError::HardLinked)
            ));
            assert!(matches!(
                env.guard.read_to_string(&linked),
                Err(GuardError::HardLinked)
            ));
            // A write must be refused before the file is truncated.
            assert!(matches!(
                env.guard.create_write(&linked),
                Err(GuardError::HardLinked)
            ));
            assert_eq!(fs::read(canary).unwrap(), b"fake-secret-do-not-read");
        }
        assert!(env
            .sink
            .events()
            .iter()
            .all(|e| e.outcome == TraceOutcome::Refused));
    }

    #[test]
    fn ordinary_files_with_one_link_are_fine() {
        let env = env();
        let f = env.worktree.join("plain.txt");
        fs::write(&f, b"plain").unwrap();
        assert_eq!(env.guard.read_to_string(&f).unwrap(), "plain");
        let sub = env.worktree.join("sub");
        fs::create_dir_all(&sub).unwrap();
        fs::write(sub.join("n.txt"), b"n").unwrap();
        let names: Vec<_> = env
            .guard
            .read_dir(&env.worktree)
            .unwrap()
            .flatten()
            .map(|e| e.file_name())
            .collect();
        assert_eq!(names.len(), 2);
        assert!(env.guard.metadata(&sub).unwrap().is_dir());
    }
}
