//! Swap races: a parent directory flipped to a symlink into a denied home between the path check and the open must
//! never produce a successful read, listing or stat of the denied target (hard rule 4).

use super::support::{env, plant, set_mode, Env};
use crate::fs_guard::open::test_hooks;
use crate::fs_guard::{FileGuard, GuardError, NullSink, RootKind};
use std::fs;
use std::os::unix::fs::symlink;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

const ORDINARY: &[u8] = b"ordinary";

/// `work/swap` is a real directory holding `f.txt` and `plain-only.txt`; the denied home holds `f.txt` (the secret) and
/// `secret-only.txt`.
struct Swap {
    swap: PathBuf,
    real: PathBuf,
    denied_dir: PathBuf,
}

fn swap_setup(env: &Env) -> Swap {
    let entry = &env.denylist.home_dirs()[0];
    let denied_dir = env.home.join(entry);
    plant(&env.home, entry);
    fs::write(denied_dir.join("f.txt"), b"fake-secret-do-not-read").unwrap();
    fs::write(
        denied_dir.join("secret-only.txt"),
        b"fake-secret-do-not-read",
    )
    .unwrap();
    let swap = env.worktree.join("swap");
    let real = env.worktree.join("swap.real");
    fs::create_dir_all(&swap).unwrap();
    fs::write(swap.join("f.txt"), ORDINARY).unwrap();
    fs::write(swap.join("plain-only.txt"), ORDINARY).unwrap();
    Swap {
        swap,
        real,
        denied_dir,
    }
}

/// Flip `swap` from the real directory to a symlink into the denied home.
fn flip_to_link(s: &Swap) {
    fs::rename(&s.swap, &s.real).unwrap();
    symlink(&s.denied_dir, &s.swap).unwrap();
}

fn flip_back(s: &Swap) {
    let _ = fs::remove_file(&s.swap);
    if s.real.exists() {
        fs::rename(&s.real, &s.swap).unwrap();
    }
}

#[test]
fn mkdir_parent_swap_must_not_create_in_denied_home() {
    let env = env();
    let s = swap_setup(&env);
    let dest = s.swap.join("must-not-exist");
    let (swap, real, denied) = (s.swap.clone(), s.real.clone(), s.denied_dir.clone());
    let armed = std::rc::Rc::new(std::cell::Cell::new(true));
    let flag = armed.clone();
    test_hooks::set_before_open(Some(Box::new(move || {
        if flag.replace(false) {
            fs::rename(&swap, &real).unwrap();
            symlink(&denied, &swap).unwrap();
        }
    })));
    let result = env.guard.create_dir_all(&dest);
    test_hooks::set_before_open(None);
    assert!(!armed.get(), "the swap hook did not run");
    assert!(result.is_err(), "the swapped path must be refused");
    assert!(
        !s.denied_dir.join("must-not-exist").exists(),
        "directory was created in the denied home before the refusal"
    );
}

#[test]
fn a_real_protected_parent_swap_must_not_create_a_file_before_refusal() {
    for append in [false, true] {
        let env = env();
        let s = swap_setup(&env);
        // No symlinks: move the protected directory itself under an already-authorized
        // pathname. Its identity is still protected, even after its name changes.
        let (swap, real, denied) = (s.swap.clone(), s.real.clone(), s.denied_dir.clone());
        let armed = std::rc::Rc::new(std::cell::Cell::new(true));
        let flag = armed.clone();
        test_hooks::set_before_open(Some(Box::new(move || {
            if flag.replace(false) {
                fs::rename(&swap, &real).unwrap();
                fs::rename(&denied, &swap).unwrap();
            }
        })));
        let target = s.swap.join("must-not-exist");
        let result = if append {
            env.guard.append(&target)
        } else {
            env.guard.create_write(&target)
        };
        test_hooks::set_before_open(None);
        assert!(!armed.get(), "the real-directory swap did not run");
        assert!(
            !target.exists(),
            "O_CREAT mutated a protected directory before returning an error"
        );
        assert!(result.is_err(), "the swapped target must be refused");
    }
}

#[test]
fn no_write_handle_may_survive_a_parent_rename_into_a_protected_destination() {
    use std::io::Write;

    for append in [false, true] {
        let env = env();
        let s = swap_setup(&env);
        let target = s.swap.join("f.txt");
        let result = if append {
            env.guard.append(&target)
        } else {
            env.guard.create_write(&target)
        };
        if let Ok(mut file) = result {
            let moved = s.denied_dir.join("moved-parent");
            fs::rename(&s.swap, &moved).unwrap();
            let before = fs::read(moved.join("f.txt")).unwrap();
            let write = file.write_all(b"must-not-write");
            assert!(
                write.is_err(),
                "a raw handle bypassed destination authorization"
            );
            assert_eq!(fs::read(moved.join("f.txt")).unwrap(), before);
        } else {
            assert_eq!(fs::read(&target).unwrap(), ORDINARY);
        }
    }
}

/// Run `op` with the parent swapped to a link right after the guard has approved the path and before it opens it.
fn with_swap_after_check<T>(env: &Env, op: impl FnOnce(&FileGuard, &Path) -> T) -> T {
    let s = swap_setup(env);
    let armed = std::rc::Rc::new(std::cell::Cell::new(true));
    let flag = armed.clone();
    let (swap, real, denied_dir) = (s.swap.clone(), s.real.clone(), s.denied_dir.clone());
    test_hooks::set_before_open(Some(Box::new(move || {
        if flag.replace(false) {
            fs::rename(&swap, &real).unwrap();
            symlink(&denied_dir, &swap).unwrap();
        }
    })));
    let out = op(&env.guard, &s.swap.join("f.txt"));
    test_hooks::set_before_open(None);
    assert!(!armed.get(), "the swap hook never ran");
    out
}

#[test]
fn a_parent_swapped_after_the_check_is_never_followed() {
    // On macOS the open itself refuses a symlink in any component; elsewhere the descriptor check refuses it.
    fn refused(e: &GuardError) -> bool {
        if cfg!(target_os = "macos") {
            matches!(e, GuardError::Io(_))
        } else {
            matches!(e, GuardError::Io(_) | GuardError::Denied { .. })
        }
    }
    let env = env();
    let e = with_swap_after_check(&env, |g, p| g.read_to_string(p)).unwrap_err();
    assert!(refused(&e), "{e:?}");
    let env = env_fresh();
    let e = with_swap_after_check(&env, |g, p| g.open_read(p)).unwrap_err();
    assert!(refused(&e), "{e:?}");
    let env = env_fresh();
    let e = with_swap_after_check(&env, |g, p| g.metadata(p)).unwrap_err();
    assert!(refused(&e), "{e:?}");
    let env = env_fresh();
    let e = with_swap_after_check(&env, |g, p| g.read_dir(p.parent().unwrap())).unwrap_err();
    assert!(refused(&e), "{e:?}");
    // Writes: nothing may be truncated or created in the denied directory.
    let env = env_fresh();
    let secret = env.home.join(&env.denylist.home_dirs()[0]).join("f.txt");
    let e = with_swap_after_check(&env, |g, p| g.create_write(p)).unwrap_err();
    assert!(matches!(e, GuardError::FileMutationUnavailable), "{e:?}");
    assert_eq!(fs::read(&secret).unwrap(), b"fake-secret-do-not-read");
    let env = env_fresh();
    let secret = env.home.join(&env.denylist.home_dirs()[0]).join("f.txt");
    let e = with_swap_after_check(&env, |g, p| g.append(p)).unwrap_err();
    assert!(matches!(e, GuardError::FileMutationUnavailable), "{e:?}");
    assert_eq!(fs::read(&secret).unwrap(), b"fake-secret-do-not-read");
}

fn env_fresh() -> Env {
    env()
}

#[test]
fn verify_fd_refuses_a_descriptor_that_points_into_a_denied_home() {
    // Hand the verifier descriptors that a swap would have produced if the open had followed the link.
    let env = env();
    let canary = plant(&env.home, &env.denylist.home_dirs()[0]);
    let denied = fs::File::open(&canary).unwrap();
    assert!(matches!(
        env.guard.verify_fd(&denied, false),
        Err(GuardError::Denied { .. })
    ));
    let stray = env.other.join("stray.txt");
    fs::write(&stray, b"x").unwrap();
    assert!(matches!(
        env.guard.verify_fd(&fs::File::open(&stray).unwrap(), false),
        Err(GuardError::OutsideRoots { .. })
    ));
    let repo = env.base.join("repo");
    fs::create_dir_all(&repo).unwrap();
    fs::write(repo.join("r.txt"), b"r").unwrap();
    env.guard.register_root(RootKind::Repo, &repo).unwrap();
    let r = fs::File::open(repo.join("r.txt")).unwrap();
    assert!(env.guard.verify_fd(&r, false).is_ok());
    assert!(matches!(
        env.guard.verify_fd(&r, true),
        Err(GuardError::ReadOnlyRoot)
    ));
    // A descriptor for a file reached through a symlinked denied entry is caught by device/inode as well as by path.
    let entry = &env.denylist.home_dirs()[1];
    let dotfiles = env.base.join("dotfiles");
    fs::create_dir_all(dotfiles.join("cfg")).unwrap();
    fs::write(dotfiles.join("cfg").join("x"), b"secret").unwrap();
    env.guard.register_root(RootKind::Repo, &dotfiles).unwrap();
    symlink(dotfiles.join("cfg"), env.home.join(entry)).unwrap();
    let via_link = fs::File::open(dotfiles.join("cfg").join("x")).unwrap();
    assert!(matches!(
        env.guard.verify_fd(&via_link, false),
        Err(GuardError::Denied { .. })
    ));
}

#[test]
fn swap_race_never_yields_a_denied_read_listing_or_stat() {
    let env = env();
    let s = swap_setup(&env);
    set_mode(&s.denied_dir, 0o755);
    // A quiet guard: a million events would otherwise pile up in memory.
    let guard = FileGuard::for_test(&[&env.home], Arc::new(NullSink));
    guard
        .register_root(RootKind::Worktree, &env.worktree)
        .unwrap();

    let stop = AtomicBool::new(false);
    let flips = AtomicU64::new(0);
    let legit = AtomicU64::new(0);
    let leaks = AtomicU64::new(0);
    let file = s.swap.join("f.txt");
    let deadline = Instant::now() + Duration::from_secs(3);

    std::thread::scope(|scope| {
        scope.spawn(|| {
            while !stop.load(Ordering::Relaxed) {
                flip_to_link(&s);
                flip_back(&s);
                flips.fetch_add(1, Ordering::Relaxed);
            }
        });
        let readers: Vec<_> = (0..4)
            .map(|_| {
                scope.spawn(|| {
                    while Instant::now() < deadline {
                        match guard.read_to_string(&file) {
                            Ok(text) if text.as_bytes() == ORDINARY => {
                                legit.fetch_add(1, Ordering::Relaxed);
                            }
                            Ok(_) => {
                                leaks.fetch_add(1, Ordering::Relaxed);
                            }
                            Err(_) => {}
                        }
                        if let Ok(mut f) = guard.open_read(&file) {
                            let mut text = String::new();
                            std::io::Read::read_to_string(&mut f, &mut text).unwrap_or(0);
                            if !text.is_empty() && text.as_bytes() != ORDINARY {
                                leaks.fetch_add(1, Ordering::Relaxed);
                            }
                        }
                        if let Ok(meta) = guard.metadata(&file) {
                            if meta.len() != ORDINARY.len() as u64 {
                                leaks.fetch_add(1, Ordering::Relaxed);
                            }
                        }
                        if let Ok(entries) = guard.read_dir(&s.swap) {
                            if entries.iter().any(|e| e.file_name() == "secret-only.txt") {
                                leaks.fetch_add(1, Ordering::Relaxed);
                            }
                        }
                    }
                })
            })
            .collect();
        for r in readers {
            r.join().unwrap();
        }
        stop.store(true, Ordering::Relaxed);
    });
    flip_back(&s);

    assert!(flips.load(Ordering::Relaxed) > 50, "the flipper barely ran");
    assert!(
        legit.load(Ordering::Relaxed) > 50,
        "no legitimate reads got through"
    );
    assert_eq!(
        leaks.load(Ordering::Relaxed),
        0,
        "a read, listing or stat reached the denied target"
    );
}
