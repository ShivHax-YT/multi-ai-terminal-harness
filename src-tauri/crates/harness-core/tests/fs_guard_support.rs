//! Shared fixtures for the fs_guard integration tests. Included with `#[path]` by the test files; compiles to an empty
//! test target on its own. Fake homes live in temp directories; nothing here names a real home or credential file.
#![allow(dead_code)]

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use harness_core::fs_guard::{Denylist, FileGuard, RecordingSink, RootKind};
use tempfile::TempDir;

pub struct Env {
    pub _tmp: TempDir,
    /// Canonical base directory of the whole fixture.
    pub base: PathBuf,
    /// Fake account home (inside `base`).
    pub home: PathBuf,
    pub worktree: PathBuf,
    pub appdata: PathBuf,
    /// A directory that is never registered as a root.
    pub other: PathBuf,
    pub sink: Arc<RecordingSink>,
    pub guard: FileGuard,
    pub denylist: &'static Denylist,
}

/// A guard over a fake home with a worktree and an app-data root registered. The home itself is not a root.
pub fn env() -> Env {
    let tmp = tempfile::tempdir().expect("tempdir");
    let base = tmp.path().canonicalize().expect("canonical tempdir");
    let home = base.join("home");
    let worktree = base.join("work");
    let appdata = base.join("data");
    let other = base.join("other");
    for dir in [&home, &worktree, &appdata, &other] {
        fs::create_dir_all(dir).expect("mkdir");
    }
    let sink = Arc::new(RecordingSink::new());
    let denylist = Denylist::embedded().expect("embedded denylist parses");
    let guard =
        FileGuard::with_denylist(denylist, &home, sink.clone()).expect("guard over the fake home");
    guard
        .register_root(RootKind::Worktree, &worktree)
        .expect("register worktree");
    guard
        .register_root(RootKind::AppData, &appdata)
        .expect("register appdata");
    sink.clear();
    Env {
        _tmp: tmp,
        base,
        home,
        worktree,
        appdata,
        other,
        sink,
        guard,
        denylist,
    }
}

/// Plant a fake credential canary for a denylist entry: `home/<entry>/canary.txt`. Returns the canary file.
pub fn plant(home: &Path, entry: &str) -> PathBuf {
    let dir = home.join(entry);
    fs::create_dir_all(&dir).expect("plant dir");
    let canary = dir.join("canary.txt");
    fs::write(&canary, b"fake-secret-do-not-read").expect("plant file");
    canary
}

/// Plant a canary for every denylist entry and return them in order.
pub fn plant_all(env: &Env) -> Vec<PathBuf> {
    env.denylist
        .home_dirs()
        .iter()
        .map(|entry| plant(&env.home, entry))
        .collect()
}

/// Make a planted file unreadable so a stray open by the app shows up as a permission error as well as in the trace.
#[cfg(unix)]
pub fn lock_down(path: &Path) {
    set_mode(path, 0o000);
}

#[cfg(unix)]
pub fn set_mode(path: &Path, mode: u32) {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(mode)).expect("chmod");
}
