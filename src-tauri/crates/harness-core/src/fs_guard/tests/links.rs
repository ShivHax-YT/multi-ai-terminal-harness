//! Link tricks: symlinks, hard links, dangling and looping links, and a denied home that is itself a symlink cannot
//! reach a denied path (hard rule 4).

use super::support::{env, plant_all, set_mode};
use crate::fs_guard::{EntryKind, FileGuard, GuardError, RootKind, TraceOutcome};
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
    for entry in env.denylist.home_dirs() {
        let via_alias = alias.join(entry).join("canary.txt");
        assert!(matches!(
            env.guard.open_read(&via_alias),
            Err(GuardError::Denied { .. })
        ));
    }
    // And a guard told about the alias spelling of the home still covers the real one.
    let g = FileGuard::for_test(&[&alias], env.sink.clone());
    g.register_root(RootKind::AppData, &env.base).unwrap();
    for canary in &canaries {
        assert!(matches!(
            g.open_read(canary),
            Err(GuardError::Denied { .. })
        ));
    }
}

/// The user keeps `~/<denied>` as a symlink into a dotfiles repo, which is also a registered root.
#[test]
fn denied_entry_behind_a_users_symlink_is_denied_at_its_target() {
    let env = env();
    let dotfiles = env.base.join("dotfiles");
    fs::create_dir_all(dotfiles.join("cfg")).unwrap();
    fs::write(
        dotfiles.join("cfg").join("canary.txt"),
        b"fake-secret-do-not-read",
    )
    .unwrap();
    fs::write(dotfiles.join("README"), b"ordinary").unwrap();
    // Built before the link exists, to prove the check looks at the disk each time.
    env.guard.register_root(RootKind::Repo, &dotfiles).unwrap();
    let guard_before = &env.guard;

    let entry = &env.denylist.home_dirs()[0];
    symlink(dotfiles.join("cfg"), env.home.join(entry)).unwrap();

    let g = guard_before;
    let via_home = env.home.join(entry).join("canary.txt");
    let direct = dotfiles.join("cfg").join("canary.txt");
    for target in [&via_home, &direct] {
        assert!(matches!(
            g.read_to_string(target),
            Err(GuardError::Denied { .. })
        ));
        assert!(matches!(
            g.open_read(target),
            Err(GuardError::Denied { .. })
        ));
        assert!(matches!(g.metadata(target), Err(GuardError::Denied { .. })));
    }
    assert!(matches!(
        g.read_dir(&dotfiles.join("cfg")),
        Err(GuardError::Denied { .. })
    ));
    // The rest of the dotfiles repo is still readable, and a sibling that merely shares a prefix is not swept up.
    assert_eq!(
        g.read_to_string(&dotfiles.join("README")).unwrap(),
        "ordinary"
    );
    fs::create_dir_all(dotfiles.join("cfg-other")).unwrap();
    fs::write(dotfiles.join("cfg-other").join("f"), b"fine").unwrap();
    assert_eq!(
        g.read_to_string(&dotfiles.join("cfg-other").join("f"))
            .unwrap(),
        "fine"
    );
}

#[test]
fn denied_entry_that_is_a_dangling_symlink_denies_its_target() {
    let env = env();
    let dotfiles = env.base.join("dotfiles");
    fs::create_dir_all(&dotfiles).unwrap();
    env.guard.register_root(RootKind::Repo, &dotfiles).unwrap();
    let entry = &env.denylist.home_dirs()[0];
    // Points at a directory that does not exist yet; a CLI may create it on first login.
    symlink(dotfiles.join("future"), env.home.join(entry)).unwrap();
    assert!(matches!(
        env.guard.open_read(&dotfiles.join("future").join("auth")),
        Err(GuardError::Denied { .. })
    ));
}

#[test]
fn denied_identity_is_caught_even_when_the_path_looks_harmless() {
    // A hard link to a denied entry that is a regular file: same device and inode, harmless-looking path.
    let env = env();
    let entry = &env.denylist.home_dirs()[0];
    fs::write(env.home.join(entry), b"fake-secret-do-not-read").unwrap();
    let linked = env.worktree.join("innocent.txt");
    fs::hard_link(env.home.join(entry), &linked).unwrap();
    assert!(matches!(
        env.guard.open_read(&linked),
        Err(GuardError::Denied { .. })
    ));
    assert!(matches!(
        env.guard.metadata(&linked),
        Err(GuardError::Denied { .. })
    ));
    assert!(matches!(
        env.guard.create_write(&linked),
        Err(GuardError::Denied { .. })
    ));
    assert_eq!(
        fs::read(env.home.join(entry)).unwrap(),
        b"fake-secret-do-not-read"
    );
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
        {
            let r = env.guard.open_read(&linked).map(|_| ());
            assert!(
                matches!(r, Err(GuardError::HardLinked | GuardError::Denied { .. })),
                "{r:?}"
            );
        }
        {
            let r = env.guard.read_to_string(&linked).map(|_| ());
            assert!(
                matches!(r, Err(GuardError::HardLinked | GuardError::Denied { .. })),
                "{r:?}"
            );
        }
        // A write must be refused before the file is truncated.
        {
            let r = env.guard.create_write(&linked).map(|_| ());
            assert!(
                matches!(r, Err(GuardError::HardLinked | GuardError::Denied { .. })),
                "{r:?}"
            );
        }
        {
            let r = env.guard.append(&linked).map(|_| ());
            assert!(
                matches!(r, Err(GuardError::HardLinked | GuardError::Denied { .. })),
                "{r:?}"
            );
        }
        assert_eq!(fs::read(canary).unwrap(), b"fake-secret-do-not-read");
    }
    assert!(env
        .sink
        .events()
        .iter()
        .all(|e| matches!(e.outcome, TraceOutcome::Refused | TraceOutcome::Denied)));
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
    let mut entries = env.guard.read_dir(&env.worktree).unwrap();
    entries.sort_by(|a, b| a.file_name().cmp(b.file_name()));
    assert_eq!(entries.len(), 2);
    assert_eq!(entries[0].file_name(), "plain.txt");
    assert_eq!(entries[0].kind(), EntryKind::File);
    assert_eq!(entries[1].kind(), EntryKind::Dir);
    assert_eq!(entries[1].path(), sub);
    assert!(env.guard.metadata(&sub).unwrap().is_dir());
}

/// Run `op` and report whether the guard reached the point of opening anything.
fn open_attempted_during<T>(op: impl FnOnce() -> T) -> (T, bool) {
    use crate::fs_guard::open::test_hooks;
    let reached = std::rc::Rc::new(std::cell::Cell::new(false));
    let flag = reached.clone();
    test_hooks::set_before_open(Some(Box::new(move || flag.set(true))));
    let out = op();
    test_hooks::set_before_open(None);
    (out, reached.get())
}

#[test]
fn hard_linked_files_are_refused_before_they_are_opened() {
    let env = env();
    let a = env.worktree.join("a.txt");
    let b = env.worktree.join("b.txt");
    fs::write(&a, b"shared").unwrap();
    fs::hard_link(&a, &b).unwrap();
    for target in [&a, &b] {
        let calls: [(&str, Result<(), GuardError>, bool); 5] = [
            {
                let (r, o) = open_attempted_during(|| env.guard.open_read(target).map(|_| ()));
                ("open_read", r, o)
            },
            {
                let (r, o) = open_attempted_during(|| env.guard.read_to_string(target).map(|_| ()));
                ("read_to_string", r, o)
            },
            {
                let (r, o) = open_attempted_during(|| env.guard.metadata(target).map(|_| ()));
                ("metadata", r, o)
            },
            {
                let (r, o) = open_attempted_during(|| env.guard.create_write(target).map(|_| ()));
                ("create_write", r, o)
            },
            {
                let (r, o) = open_attempted_during(|| env.guard.append(target).map(|_| ()));
                ("append", r, o)
            },
        ];
        for (name, r, opened) in calls {
            assert!(matches!(r, Err(GuardError::HardLinked)), "{name}: {r:?}");
            assert!(!opened, "{name}: opened before the link count was checked");
        }
    }
    assert_eq!(fs::read(&a).unwrap(), b"shared");
    // The refusal is traced against the target's own hash.
    let ev = env.sink.events_for(&a);
    assert_eq!(ev.len(), 5);
    assert!(ev.iter().all(|e| e.outcome == TraceOutcome::Refused));
}

#[test]
fn a_file_swapped_for_a_hard_linked_one_after_the_precheck_is_refused() {
    use crate::fs_guard::open::test_hooks;
    let env = env();
    let target = env.worktree.join("t.txt");
    fs::write(&target, b"plain").unwrap();
    let shared = env.worktree.join("shared.txt");
    let shared_twin = env.worktree.join("shared-twin.txt");
    fs::write(&shared, b"shared").unwrap();
    fs::hard_link(&shared, &shared_twin).unwrap();
    let (from, to) = (shared.clone(), target.clone());
    test_hooks::set_before_open(Some(Box::new(move || {
        fs::rename(&from, &to).unwrap();
    })));
    let r = env.guard.read_to_string(&target);
    test_hooks::set_before_open(None);
    assert!(
        matches!(
            r,
            Err(GuardError::HardLinked | GuardError::ChangedDuringCheck)
        ),
        "{r:?}"
    );
}
