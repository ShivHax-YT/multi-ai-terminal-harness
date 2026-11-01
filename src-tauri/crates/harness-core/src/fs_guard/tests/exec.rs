//! The binary-verifier exception (hard rule 6): resolve and hash a CLI binary, nothing else in a denied directory.

use super::support::{env, lock_down, set_mode, Env};
use crate::fs_guard::open::CLI_BINARY_NAMES;
use crate::fs_guard::{GuardError, TraceOp, TraceOutcome};
use sha2::{Digest, Sha256};
use std::fs;
use std::os::unix::fs::symlink;
use std::path::PathBuf;

const BINARY_BYTES: &[u8] = b"#!/bin/sh\nexit 0\n";

fn sha(bytes: &[u8]) -> [u8; 32] {
    Sha256::digest(bytes).into()
}

/// A fake CLI binary inside a denied home, with a sibling canary and a non-CLI executable next to it.
struct FakeCli {
    binary: PathBuf,
    sibling: PathBuf,
    other_exec: PathBuf,
    dir: PathBuf,
}

fn fake_cli(env: &Env) -> FakeCli {
    let entry = &env.denylist.home_dirs()[0];
    let dir = env.home.join(entry).join("packages").join("bin");
    fs::create_dir_all(&dir).unwrap();
    let binary = dir.join(CLI_BINARY_NAMES[0]);
    fs::write(&binary, BINARY_BYTES).unwrap();
    set_mode(&binary, 0o755);
    let sibling = dir.join("sibling-canary");
    fs::write(&sibling, b"fake-secret-do-not-read").unwrap();
    lock_down(&sibling);
    let other_exec = dir.join("helper-tool");
    fs::write(&other_exec, b"#!/bin/sh\n").unwrap();
    set_mode(&other_exec, 0o755);
    FakeCli {
        binary,
        sibling,
        other_exec,
        dir,
    }
}

#[test]
fn sibling_file_unreadable() {
    let env = env();
    let cli = fake_cli(&env);

    // The verifier may resolve and hash the binary...
    assert_eq!(env.guard.exec_resolve(&cli.binary).unwrap(), cli.binary);
    assert_eq!(
        env.guard.hash_executable(&cli.binary).unwrap(),
        sha(BINARY_BYTES)
    );
    let ev = env.sink.events_for(&cli.binary);
    assert_eq!(ev.len(), 2);
    assert_eq!(ev[0].op, TraceOp::ExecResolve);
    assert_eq!(ev[1].op, TraceOp::ExecHash);
    assert!(ev.iter().all(|e| e.outcome == TraceOutcome::Allowed));

    // ...but the exception does not extend to anything next to it, through any entry point.
    env.sink.clear();
    let g = &env.guard;
    for target in [&cli.sibling, &cli.other_exec] {
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
        assert!(matches!(g.append(target), Err(GuardError::Denied { .. })));
        assert!(matches!(
            g.exec_resolve(target),
            Err(GuardError::Denied { .. })
        ));
        assert!(matches!(
            g.hash_executable(target),
            Err(GuardError::Denied { .. })
        ));
    }
    // Neither the directory nor the binary itself can be opened or listed through the ordinary calls.
    assert!(matches!(
        g.open_read(&cli.binary),
        Err(GuardError::Denied { .. })
    ));
    assert!(matches!(
        g.read_dir(&cli.dir),
        Err(GuardError::Denied { .. })
    ));
    for sibling in [&cli.sibling, &cli.other_exec] {
        let seen = env.sink.events_for(sibling);
        assert!(!seen.is_empty());
        assert!(seen.iter().all(|e| e.outcome == TraceOutcome::Denied));
    }
    set_mode(&cli.sibling, 0o644);
    assert_eq!(fs::read(&cli.sibling).unwrap(), b"fake-secret-do-not-read");
}

#[test]
fn exec_calls_in_a_denied_directory_do_not_reveal_what_exists() {
    let env = env();
    let cli = fake_cli(&env);
    let existing_exec = env.guard.exec_resolve(&cli.other_exec).unwrap_err();
    let existing_secret = env.guard.exec_resolve(&cli.sibling).unwrap_err();
    let missing = env
        .guard
        .exec_resolve(&cli.dir.join("nothing-here"))
        .unwrap_err();
    let missing_deep = env
        .guard
        .exec_resolve(&cli.dir.join("x").join("y").join("z"))
        .unwrap_err();
    for e in [&existing_exec, &existing_secret, &missing, &missing_deep] {
        assert!(matches!(e, GuardError::Denied { .. }), "{e:?}");
    }
    // Same for hashing, and for a symlink from outside that lands on a non-binary in the denied home.
    let link = env.worktree.join("looks-fine");
    symlink(&cli.other_exec, &link).unwrap();
    assert!(matches!(
        env.guard.exec_resolve(&link),
        Err(GuardError::Denied { .. })
    ));
    assert!(matches!(
        env.guard.hash_executable(&link),
        Err(GuardError::Denied { .. })
    ));
    // A link that merely carries a CLI name does not unlock a non-binary file in the denied directory.
    let named = env.worktree.join(CLI_BINARY_NAMES[1]);
    symlink(&cli.other_exec, &named).unwrap();
    assert!(matches!(
        env.guard.exec_resolve(&named),
        Err(GuardError::Denied { .. })
    ));
    assert!(matches!(
        env.guard.hash_executable(&named),
        Err(GuardError::Denied { .. })
    ));
    // The same name check applies to the real file's own name: a credential-looking file with +x stays refused.
    set_mode(&cli.sibling, 0o755);
    assert!(matches!(
        env.guard.hash_executable(&cli.sibling),
        Err(GuardError::Denied { .. })
    ));
    set_mode(&cli.sibling, 0o644);
}

#[test]
fn exec_follows_a_link_to_the_real_binary() {
    let env = env();
    let cli = fake_cli(&env);
    let link_dir = env.base.join("usr-bin");
    fs::create_dir_all(&link_dir).unwrap();
    let link = link_dir.join("fake-cli");
    symlink(&cli.binary, &link).unwrap();
    // The link directory is not a registered root; the exception does not need one.
    assert_eq!(env.guard.exec_resolve(&link).unwrap(), cli.binary);
    assert_eq!(env.guard.hash_executable(&link).unwrap(), sha(BINARY_BYTES));
}

#[test]
fn exec_outside_denied_directories_accepts_any_regular_executable() {
    let env = env();
    let tool = env.other.join("some-tool");
    fs::write(&tool, b"#!/bin/sh\n").unwrap();
    set_mode(&tool, 0o755);
    assert_eq!(env.guard.exec_resolve(&tool).unwrap(), tool);
    assert_eq!(
        env.guard.hash_executable(&tool).unwrap(),
        sha(b"#!/bin/sh\n")
    );
}

#[test]
fn exec_refuses_non_binaries() {
    let env = env();
    let dir = env.worktree.join("d");
    fs::create_dir_all(&dir).unwrap();
    let text = env.worktree.join("notes.txt");
    fs::write(&text, b"x").unwrap();
    set_mode(&text, 0o644);
    for refused in [
        env.guard.exec_resolve(&dir).map(|_| ()),
        env.guard.hash_executable(&dir).map(|_| ()),
    ] {
        assert!(matches!(refused, Err(GuardError::NotAFile)));
    }
    assert!(matches!(
        env.guard.exec_resolve(&text),
        Err(GuardError::NotExecutable)
    ));
    assert!(matches!(
        env.guard.hash_executable(&text),
        Err(GuardError::NotExecutable)
    ));
    assert!(matches!(
        env.guard.exec_resolve(&env.worktree.join("missing")),
        Err(GuardError::Io(_))
    ));
    assert!(matches!(
        env.guard.hash_executable(std::path::Path::new("fake-cli")),
        Err(GuardError::NotAbsolute)
    ));
    assert!(env
        .sink
        .events()
        .iter()
        .all(|e| matches!(e.op, TraceOp::ExecResolve | TraceOp::ExecHash)
            && e.outcome != TraceOutcome::Allowed));
}

#[test]
fn hash_executable_returns_a_digest_never_a_handle_and_streams_large_files() {
    let env = env();
    let big = env.other.join("big-tool");
    let bytes: Vec<u8> = (0..300_000u32).map(|i| (i % 251) as u8).collect();
    fs::write(&big, &bytes).unwrap();
    set_mode(&big, 0o755);
    let digest: [u8; 32] = env.guard.hash_executable(&big).unwrap();
    assert_eq!(digest, sha(&bytes));
}

#[test]
fn exec_exception_does_not_cover_a_denied_file_entry_itself() {
    // A denied entry that is a regular file, executable bit set, hard-linked under a CLI name elsewhere.
    let env = env();
    let entry = &env.denylist.home_dirs()[0];
    fs::write(env.home.join(entry), b"fake-secret-do-not-read").unwrap();
    set_mode(&env.home.join(entry), 0o755);
    let linked = env.other.join(CLI_BINARY_NAMES[2]);
    fs::hard_link(env.home.join(entry), &linked).unwrap();
    assert!(matches!(
        env.guard.exec_resolve(&linked),
        Err(GuardError::Denied { .. })
    ));
    assert!(matches!(
        env.guard.hash_executable(&linked),
        Err(GuardError::Denied { .. })
    ));
}

#[test]
fn hash_executable_refuses_a_file_replaced_after_it_was_vetted() {
    use crate::fs_guard::open::test_hooks;
    let env = env();
    let tool = env.other.join("swap-tool");
    let replacement = env.other.join("replacement");
    fs::write(&tool, b"#!/bin/sh\necho original\n").unwrap();
    fs::write(&replacement, b"#!/bin/sh\necho replaced\n").unwrap();
    set_mode(&tool, 0o755);
    set_mode(&replacement, 0o755);
    let (from, to) = (replacement.clone(), tool.clone());
    test_hooks::set_before_open(Some(Box::new(move || {
        fs::rename(&from, &to).unwrap();
    })));
    let result = env.guard.hash_executable(&tool);
    test_hooks::set_before_open(None);
    assert!(
        matches!(result, Err(GuardError::ChangedDuringCheck)),
        "{result:?}"
    );
}
