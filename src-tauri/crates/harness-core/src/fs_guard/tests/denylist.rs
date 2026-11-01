//! Denylist parsing, refusals, root rules, the write API and error hygiene (hard rule 4).

use super::support::{env, plant_all, Env};
use crate::fs_guard::{
    Denylist, DenylistError, FileGuard, GuardError, RecordingSink, RootKind, TraceOp, TraceOutcome,
    EMBEDDED_DENYLIST_TOML,
};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;

const VALID: &str = r#"
    home_dirs = ["a", "b/c"]
    keychain_services = ["svc"]
    allowed_exceptions = []
"#;

/// Run every guard operation on `path` and assert each one is refused as Denied.
fn assert_all_ops_denied(env: &Env, path: &Path) {
    let g = &env.guard;
    assert!(matches!(g.open_read(path), Err(GuardError::Denied { .. })));
    assert!(matches!(
        g.read_to_string(path),
        Err(GuardError::Denied { .. })
    ));
    assert!(matches!(g.read_dir(path), Err(GuardError::Denied { .. })));
    assert!(matches!(g.metadata(path), Err(GuardError::Denied { .. })));
    assert!(matches!(
        g.create_write(path),
        Err(GuardError::Denied { .. })
    ));
    assert!(matches!(g.append(path), Err(GuardError::Denied { .. })));
    assert!(matches!(
        g.create_dir_all(path),
        Err(GuardError::Denied { .. })
    ));
}

// ---- denylist data -----------------------------------------------------------------------------------------------

#[test]
fn embedded_denylist_loads_and_is_not_empty() {
    let list = Denylist::embedded().expect("embedded list parses");
    assert!(!list.home_dirs().is_empty());
    assert!(!list.keychain_services().is_empty());
    assert!(EMBEDDED_DENYLIST_TOML.contains("home_dirs"));
    // Parsed once: the same allocation comes back.
    assert!(std::ptr::eq(list, Denylist::embedded().unwrap()));
}

#[test]
fn denylist_fails_closed_on_bad_data() {
    assert!(Denylist::parse(VALID).is_ok());
    assert!(matches!(
        Denylist::parse("home_dirs = []\nkeychain_services = [\"s\"]"),
        Err(DenylistError::NoHomeDirs)
    ));
    assert!(matches!(
        Denylist::parse("home_dirs = [\"a\"]\nkeychain_services = []"),
        Err(DenylistError::NoKeychainServices)
    ));
    assert!(matches!(
        Denylist::parse(
            "home_dirs = [\"a\"]\nkeychain_services = [\"s\"]\nallowed_exceptions = [\"x\"]"
        ),
        Err(DenylistError::ExceptionsNotPermitted)
    ));
    for bad in ["/abs", "a/../b", "./a", "a//b", "", "a\\\\b"] {
        let doc = format!("home_dirs = [\"{bad}\"]\nkeychain_services = [\"s\"]");
        assert!(
            matches!(Denylist::parse(&doc), Err(DenylistError::BadEntry { .. })),
            "entry {bad:?} must be rejected"
        );
    }
    assert!(matches!(
        Denylist::parse("home_dirs = [\"a\"]\nkeychain_services = [\"s\"]\nunlimited = true"),
        Err(DenylistError::Parse(_))
    ));
    assert!(matches!(
        Denylist::parse("not toml ["),
        Err(DenylistError::Parse(_))
    ));
}

// ---- refusals ----------------------------------------------------------------------------------------------------

#[test]
fn denylist_refuses_cli_homes() {
    let env = env();
    let canaries = plant_all(&env);
    for (entry, canary) in env.denylist.home_dirs().iter().zip(&canaries) {
        let dir = env.home.join(entry);
        assert_all_ops_denied(&env, &dir);
        assert_all_ops_denied(&env, canary);
        assert_all_ops_denied(&env, &dir.join("does-not-exist-yet"));
        assert_all_ops_denied(&env, &dir.join("a").join("b").join("c"));
    }
    let events = env.sink.events();
    assert!(!events.is_empty());
    assert!(
        events.iter().all(|e| e.outcome == TraceOutcome::Denied),
        "nothing under a denied home may be allowed: {events:?}"
    );
}

#[test]
fn denylist_refuses_dot_continued_siblings() {
    // A backup, lock or renamed copy of a listed entry is refused too.
    let env = env();
    for entry in env.denylist.home_dirs() {
        for suffix in [".bak", ".lock", ".backup.1", "~", "-old", "_bak", "--x"] {
            let sibling = env.home.join(format!("{entry}{suffix}"));
            fs::write(&sibling, b"fake").unwrap();
            assert_all_ops_denied(&env, &sibling);
        }
    }
}

#[test]
fn unrelated_neighbours_of_a_denied_entry_are_not_denied() {
    // Continuation matching stops at alphanumerics, so unrelated names stay reachable under a registered root.
    let env = env();
    env.guard
        .register_root(RootKind::AppData, &env.home)
        .unwrap();
    let entries = env.denylist.home_dirs();
    // Skip entries that extend another entry (the longer name is covered by the shorter one's continuation rule).
    for entry in entries
        .iter()
        .filter(|e| !entries.iter().any(|o| o != *e && e.starts_with(o.as_str())))
    {
        let neighbour = env.home.join(format!("{entry}x"));
        fs::write(&neighbour, b"fine").unwrap();
        assert_eq!(env.guard.read_to_string(&neighbour).unwrap(), "fine");
    }
}

#[test]
fn denylist_refuses_case_variants() {
    let env = env();
    plant_all(&env);
    for entry in env.denylist.home_dirs() {
        let upper = env.home.join(entry.to_uppercase()).join("CANARY.TXT");
        assert_all_ops_denied(&env, &upper);
        let mixed: String = entry
            .chars()
            .enumerate()
            .map(|(i, c)| {
                if i % 2 == 0 {
                    c.to_ascii_uppercase()
                } else {
                    c
                }
            })
            .collect();
        assert_all_ops_denied(&env, &env.home.join(mixed).join("canary.txt"));
    }
    // The home itself spelled in another case is covered too.
    let home_upper = PathBuf::from(env.home.to_string_lossy().to_uppercase());
    let first = &env.denylist.home_dirs()[0];
    assert_all_ops_denied(&env, &home_upper.join(first).join("canary.txt"));
}

#[test]
fn denylist_refuses_parent_traversal() {
    let env = env();
    plant_all(&env);
    for entry in env.denylist.home_dirs() {
        // Out of the worktree, across the base, into the denied home.
        let sneaky = env
            .worktree
            .join("..")
            .join("home")
            .join(entry)
            .join("canary.txt");
        assert_all_ops_denied(&env, &sneaky);
        // Dots after the denied segment.
        let dotted = env.home.join(entry).join("x").join("..").join("canary.txt");
        assert_all_ops_denied(&env, &dotted);
        // Dots that cancel before the denied segment.
        let cancel = env
            .home
            .join("zzz")
            .join("..")
            .join(entry)
            .join("canary.txt");
        assert_all_ops_denied(&env, &cancel);
    }
}

#[test]
fn relative_paths_are_refused() {
    let env = env();
    let rel = Path::new("some/relative/file.txt");
    assert!(matches!(
        env.guard.open_read(rel),
        Err(GuardError::NotAbsolute)
    ));
    assert!(matches!(
        env.guard.create_write(Path::new("x")),
        Err(GuardError::NotAbsolute)
    ));
    let ev = env.sink.events();
    assert_eq!(ev.len(), 2);
    assert!(ev.iter().all(|e| e.outcome == TraceOutcome::Refused));
}

#[test]
fn deny_beats_allow() {
    // The whole fake home is registered as a writable root, an allow rule that covers every denied entry.
    let env = env();
    let canaries = plant_all(&env);
    env.guard
        .register_root(RootKind::AppData, &env.home)
        .expect("home may be a root");
    let ok = env.home.join("ordinary.txt");
    fs::write(&ok, b"fine").unwrap();
    assert_eq!(env.guard.read_to_string(&ok).unwrap(), "fine");
    for (entry, canary) in env.denylist.home_dirs().iter().zip(&canaries) {
        assert_all_ops_denied(&env, canary);
        assert_all_ops_denied(&env, &env.home.join(entry));
    }
}

#[test]
fn outside_roots_refused() {
    let env = env();
    let stray = env.other.join("stray.txt");
    fs::write(&stray, b"not a credential").unwrap();
    assert!(matches!(
        env.guard.open_read(&stray),
        Err(GuardError::OutsideRoots { .. })
    ));
    assert!(matches!(
        env.guard.read_dir(&env.other),
        Err(GuardError::OutsideRoots { .. })
    ));
    assert!(matches!(
        env.guard.metadata(&stray),
        Err(GuardError::OutsideRoots { .. })
    ));
    assert!(matches!(
        env.guard.create_write(&env.other.join("new.txt")),
        Err(GuardError::OutsideRoots { .. })
    ));
    assert!(!env.other.join("new.txt").exists());
    // A path next to a root that shares its name prefix is not inside it.
    let lookalike = env.base.join("work-evil");
    fs::create_dir_all(&lookalike).unwrap();
    fs::write(lookalike.join("f"), b"x").unwrap();
    assert!(matches!(
        env.guard.open_read(&lookalike.join("f")),
        Err(GuardError::OutsideRoots { .. })
    ));
    let events = env.sink.events();
    assert_eq!(events.len(), 5);
    assert!(events
        .iter()
        .all(|e| e.outcome == TraceOutcome::OutsideRoots));
}

#[test]
fn no_roots_means_nothing_is_allowed() {
    let env = env();
    let bare = FileGuard::for_test(&[&env.home], env.sink.clone());
    let f = env.worktree.join("f.txt");
    fs::write(&f, b"x").unwrap();
    assert!(matches!(
        bare.open_read(&f),
        Err(GuardError::OutsideRoots { .. })
    ));
}

#[test]
fn repo_root_is_read_only_and_worktree_mutation_remains_unavailable() {
    let env = env();
    let repo = env.base.join("repo");
    fs::create_dir_all(&repo).unwrap();
    fs::write(repo.join("README"), b"hello").unwrap();
    env.guard.register_root(RootKind::Repo, &repo).unwrap();
    assert_eq!(
        env.guard.read_to_string(&repo.join("README")).unwrap(),
        "hello"
    );
    assert!(matches!(
        env.guard.create_write(&repo.join("new")),
        Err(GuardError::ReadOnlyRoot)
    ));
    assert!(matches!(
        env.guard.append(&repo.join("new")),
        Err(GuardError::ReadOnlyRoot)
    ));
    assert!(matches!(
        env.guard.create_dir_all(&repo.join("d").join("e")),
        Err(GuardError::ReadOnlyRoot)
    ));
    assert!(!repo.join("new").exists());
    assert!(!repo.join("d").exists());
    assert!(matches!(
        env.guard.create_write(&env.worktree.join("new")),
        Err(GuardError::FileMutationUnavailable)
    ));
    assert!(!env.worktree.join("new").exists());
}

#[test]
fn create_write_never_truncates_an_existing_app_file() {
    let env = env();
    let p = env.appdata.join("state.txt");
    fs::write(&p, b"old contents").unwrap();
    assert!(matches!(
        env.guard.create_write(&p),
        Err(GuardError::FileMutationUnavailable)
    ));
    assert_eq!(fs::read(&p).unwrap(), b"old contents");
}

#[test]
fn append_keeps_existing_content_and_never_creates_missing_files() {
    let env = env();
    let log = env.appdata.join("events.jsonl");
    assert!(matches!(
        env.guard.append(&log),
        Err(GuardError::FileMutationUnavailable)
    ));
    assert!(!log.exists());
    fs::write(&log, b"{\"a\":1}\n").unwrap();
    assert!(matches!(
        env.guard.append(&log),
        Err(GuardError::FileMutationUnavailable)
    ));
    assert_eq!(fs::read(&log).unwrap(), b"{\"a\":1}\n");
    let ev = env.sink.events_for(&log);
    assert!(ev
        .iter()
        .all(|e| e.op == TraceOp::Append && e.outcome == TraceOutcome::Refused));
    // Outside every root: refused, and nothing is created.
    assert!(matches!(
        env.guard.append(&env.other.join("x.jsonl")),
        Err(GuardError::OutsideRoots { .. })
    ));
    assert!(!env.other.join("x.jsonl").exists());
}

#[test]
fn create_dir_all_fails_closed_even_under_writable_roots() {
    let env = env();
    let deep = env.appdata.join("a").join("b").join("c");
    assert!(matches!(
        env.guard.create_dir_all(&deep),
        Err(GuardError::DirectoryCreationUnavailable)
    ));
    assert!(!env.appdata.join("a").exists());
    assert!(matches!(
        env.guard.create_dir_all(&env.appdata),
        Err(GuardError::DirectoryCreationUnavailable)
    ));
    assert!(matches!(
        env.guard.create_dir_all(&env.other.join("a").join("b")),
        Err(GuardError::OutsideRoots { .. })
    ));
    assert!(!env.other.join("a").exists());
    // Not a way to create a directory inside a denied home, even with a registered root above it.
    let entry = &env.denylist.home_dirs()[0];
    env.guard
        .register_root(RootKind::AppData, &env.home)
        .unwrap();
    assert!(matches!(
        env.guard.create_dir_all(&env.home.join(entry).join("x")),
        Err(GuardError::Denied { .. })
    ));
    assert!(!env.home.join(entry).exists());
}

#[test]
fn register_root_rejects_denied_and_filesystem_roots() {
    let env = env();
    let canaries = plant_all(&env);
    for (entry, _) in env.denylist.home_dirs().iter().zip(&canaries) {
        let r = env
            .guard
            .register_root(RootKind::Repo, &env.home.join(entry));
        assert!(matches!(r, Err(GuardError::Denied { .. })), "{r:?}");
    }
    assert!(matches!(
        env.guard.register_root(RootKind::Repo, Path::new("/")),
        Err(GuardError::RootRejected)
    ));
    assert!(matches!(
        env.guard.register_root(RootKind::Repo, Path::new("rel")),
        Err(GuardError::NotAbsolute)
    ));
    assert!(matches!(
        env.guard
            .register_root(RootKind::Repo, &env.base.join("missing")),
        Err(GuardError::Io(_))
    ));
    let ev = env.sink.events();
    assert!(ev.iter().all(|e| e.op == TraceOp::RegisterRoot));
    assert!(ev.iter().all(|e| e.outcome != TraceOutcome::Allowed));
}

// ---- which homes are covered -------------------------------------------------------------------------------------

#[test]
fn guard_requires_an_absolute_home() {
    let r = FileGuard::new(Path::new("home"), Arc::new(RecordingSink::new()));
    assert!(matches!(r, Err(GuardError::NotAbsolute)));
}

#[test]
fn homes_cover_the_account_home_and_the_callers_home() {
    // Pure path logic: no filesystem access to either home.
    let given = Path::new("/definitely/not/the/account/home");
    let homes = FileGuard::homes_for(given).unwrap();
    let account = super::super::sys::account_home().unwrap();
    assert!(homes.contains(&account), "account home from getpwuid");
    assert!(homes.iter().any(|h| h == given), "caller's home");
}

#[test]
fn denial_applies_under_every_home_the_guard_covers() {
    // Two fake homes: a caller-supplied one and an "account" one the caller did not mention first.
    let env = env();
    let account = env.base.join("account");
    fs::create_dir_all(&account).unwrap();
    let guard = FileGuard::for_test(&[&account, &env.home], env.sink.clone());
    guard
        .register_root(RootKind::AppData, &env.base)
        .expect("base as a root");
    for entry in env.denylist.home_dirs() {
        for home in [&account, &env.home] {
            let target = home.join(entry).join("canary.txt");
            assert!(matches!(
                guard.open_read(&target),
                Err(GuardError::Denied { .. })
            ));
        }
    }
    // A guard that only knew the caller's home would not have covered the account one.
    let narrow = FileGuard::for_test(&[&env.home], env.sink.clone());
    narrow
        .register_root(RootKind::AppData, &env.base)
        .expect("base as a root");
    let entry = &env.denylist.home_dirs()[0];
    let missing = account.join(entry).join("canary.txt");
    assert!(matches!(narrow.open_read(&missing), Err(GuardError::Io(_))));
}

#[test]
fn allowed_reads_are_traced_as_allowed() {
    let env = env();
    let f = env.worktree.join("a.txt");
    fs::write(&f, b"hi").unwrap();
    assert_eq!(env.guard.read_to_string(&f).unwrap(), "hi");
    let ev = env.sink.events_for(&f);
    assert_eq!(ev.len(), 1);
    assert_eq!(ev[0].op, TraceOp::ReadToString);
    assert_eq!(ev[0].outcome, TraceOutcome::Allowed);
    // A missing file inside a root is an io error, traced as such, not a refusal.
    let missing = env.worktree.join("nope.txt");
    assert!(matches!(
        env.guard.open_read(&missing),
        Err(GuardError::Io(_))
    ));
    assert_eq!(
        env.sink.events_for(&missing)[0].outcome,
        TraceOutcome::IoError
    );
}

// ---- error hygiene -----------------------------------------------------------------------------------------------

#[test]
fn guard_error_display_never_contains_the_path() {
    let env = env();
    plant_all(&env);
    let marker = "distinctive-marker-name";
    let entry = &env.denylist.home_dirs()[0];
    let base = env.base.to_string_lossy().into_owned();
    let paths = [
        env.home.join(entry).join(marker),                 // Denied
        env.other.join(marker),                            // OutsideRoots
        env.worktree.join(marker),                         // Io (missing)
        env.worktree.join(marker).join("..").join(marker), // Io or InvalidPath
        PathBuf::from(format!("relative/{marker}")),       // NotAbsolute
    ];
    let mut errors: Vec<GuardError> = Vec::new();
    for p in &paths {
        errors.push(env.guard.open_read(p).unwrap_err());
        errors.push(env.guard.read_dir(p).unwrap_err());
        errors.push(env.guard.metadata(p).unwrap_err());
        if !p.starts_with(&env.worktree) {
            // Inside the worktree a write to a new name is legitimately allowed.
            errors.push(env.guard.create_write(p).unwrap_err());
            errors.push(env.guard.append(p).unwrap_err());
        }
    }
    errors.push(
        env.guard
            .create_write(&env.worktree.join(marker).join("..").join(marker))
            .unwrap_err(),
    );
    let dangling = env.worktree.join("dangling");
    std::os::unix::fs::symlink(env.other.join(marker), &dangling).unwrap();
    errors.push(env.guard.open_read(&dangling).unwrap_err());
    let repo = env.base.join("repo");
    fs::create_dir_all(&repo).unwrap();
    env.guard.register_root(RootKind::Repo, &repo).unwrap();
    errors.push(env.guard.create_write(&repo.join(marker)).unwrap_err());
    errors.push(
        env.guard
            .register_root(RootKind::Repo, &env.base.join(marker))
            .unwrap_err(),
    );
    assert!(errors.len() > 20);
    for e in &errors {
        for text in [e.to_string(), format!("{e:?}")] {
            assert!(!text.contains(marker), "error leaks a file name: {text}");
            assert!(!text.contains(&base), "error leaks a directory: {text}");
        }
    }
}
