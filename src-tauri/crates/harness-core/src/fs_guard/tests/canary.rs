//! The credential canary in unit form and trace contents (hard rule 4).

use super::support::{env, lock_down, plant_all, set_mode};
use crate::fs_guard::{hash_path, TraceOutcome};
use std::fs;

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
    for entry in env.guard.read_dir(&env.worktree).unwrap() {
        let path = entry.path();
        if path.is_file() {
            env.guard.read_to_string(path).unwrap();
            env.guard.open_read(path).unwrap();
        }
        env.guard.metadata(path).unwrap();
    }
    let log = env.appdata.join("log.txt");
    assert!(matches!(
        env.guard.create_write(&log),
        Err(crate::fs_guard::GuardError::FileMutationUnavailable)
    ));
    assert!(!log.exists());
    // Listing the account home is outside every root and refused; it must not touch any planted file either.
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
    for entry in env.denylist.home_dirs() {
        assert!(env.sink.events_for(&env.home.join(entry)).is_empty());
    }

    // Now go looking for them on purpose: every attempt is refused and none is ever recorded as allowed.
    env.sink.clear();
    for canary in &canaries {
        assert!(env.guard.open_read(canary).is_err());
        assert!(env.guard.read_to_string(canary).is_err());
        assert!(env.guard.metadata(canary).is_err());
        assert!(env.guard.create_write(canary).is_err());
        assert!(env.guard.append(canary).is_err());
        let seen = env.sink.events_for(canary);
        assert_eq!(seen.len(), 5);
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
