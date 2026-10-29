//! Denylist parsing, refusals, root rules and the two static source checks (hard rule 4).

#[path = "fs_guard_support.rs"]
mod support;

mod fs_guard {
    use super::support::{env, plant, plant_all, Env};
    use harness_core::fs_guard::{
        Denylist, DenylistError, FileGuard, GuardError, RootKind, TraceOp, TraceOutcome,
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
    }

    // ---- denylist data -------------------------------------------------------------------------------------------

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

    // ---- refusals ------------------------------------------------------------------------------------------------

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
        // A backup or lock copy of a listed entry is refused too.
        let env = env();
        for entry in env.denylist.home_dirs() {
            for suffix in [".bak", ".lock", ".backup.1"] {
                let sibling = env.home.join(format!("{entry}{suffix}"));
                fs::write(&sibling, b"fake").unwrap();
                assert_all_ops_denied(&env, &sibling);
            }
        }
    }

    #[test]
    fn denylist_refuses_case_variants() {
        let env = env();
        let canaries = plant_all(&env);
        for (entry, canary) in env.denylist.home_dirs().iter().zip(&canaries) {
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
            let _ = canary;
        }
        // The home itself spelled in another case is covered too.
        let home_upper = PathBuf::from(env.home.to_string_lossy().to_uppercase());
        let first = &env.denylist.home_dirs()[0];
        assert_all_ops_denied(&env, &home_upper.join(first).join("canary.txt"));
    }

    #[test]
    fn denylist_refuses_parent_traversal() {
        let env = env();
        let canaries = plant_all(&env);
        for (entry, canary) in env.denylist.home_dirs().iter().zip(&canaries) {
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
            let _ = canary;
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
        let bare = FileGuard::with_denylist(env.denylist, &env.home, env.sink.clone()).unwrap();
        let f = env.worktree.join("f.txt");
        fs::write(&f, b"x").unwrap();
        assert!(matches!(
            bare.open_read(&f),
            Err(GuardError::OutsideRoots { .. })
        ));
    }

    #[test]
    fn repo_root_is_read_only_and_worktree_is_writable() {
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
        assert!(!repo.join("new").exists());
        use std::io::Write;
        let mut f = env.guard.create_write(&env.worktree.join("new")).unwrap();
        f.write_all(b"ok").unwrap();
        drop(f);
        assert_eq!(fs::read(env.worktree.join("new")).unwrap(), b"ok");
    }

    #[test]
    fn create_write_truncates_an_existing_app_file() {
        let env = env();
        let p = env.appdata.join("state.txt");
        fs::write(&p, b"old contents").unwrap();
        drop(env.guard.create_write(&p).unwrap());
        assert_eq!(fs::read(&p).unwrap(), b"");
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

    #[test]
    fn guard_requires_an_absolute_home() {
        let env = env();
        let r =
            FileGuard::with_denylist(env.denylist, Path::new("home"), Arc::clone(&env.sink) as _);
        assert!(matches!(r, Err(GuardError::NotAbsolute)));
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
        let _ = plant; // fixture helper shared with sibling test files
    }

    // ---- static source checks ------------------------------------------------------------------------------------

    fn crate_dir() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
    }

    fn collect_rs(dir: &Path, out: &mut Vec<PathBuf>) {
        let Ok(entries) = fs::read_dir(dir) else {
            return;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if path.is_dir() {
                if matches!(name.as_ref(), "target" | "node_modules" | ".git") {
                    continue;
                }
                collect_rs(&path, out);
            } else if name.ends_with(".rs") {
                out.push(path);
            }
        }
    }

    #[test]
    fn keychain_names_only_in_denylist() {
        let src_tauri = crate_dir().join("..").join("..");
        let mut files = Vec::new();
        collect_rs(&src_tauri, &mut files);
        assert!(
            files.len() > 5,
            "walked too few files ({}); the path to src-tauri is wrong",
            files.len()
        );
        let list = Denylist::embedded().unwrap();
        assert!(!list.keychain_services().is_empty());
        for file in &files {
            let text = fs::read_to_string(file).unwrap();
            for name in list.keychain_services() {
                assert!(
                    !text.contains(name.as_str()),
                    "{} names a Keychain service; those names live in compliance/denylist.toml only",
                    file.display()
                );
            }
        }
    }

    /// Lines of `text` that use a raw filesystem read. Scanning stops at the first `#[cfg(test)]`, and comment lines
    /// are skipped. Returns (1-based line number, line).
    fn raw_fs_lines(text: &str) -> Vec<(usize, String)> {
        const PATTERNS: [&str; 4] = ["File::open", "fs::read", "OpenOptions", "std::fs::File"];
        let mut hits = Vec::new();
        for (i, line) in text.lines().enumerate() {
            let trimmed = line.trim_start();
            if trimmed.starts_with("#[cfg(test)]") {
                break;
            }
            if trimmed.starts_with("//") {
                continue;
            }
            let bare_read = line.match_indices("read_to_string(").any(|(at, _)| {
                let before = line[..at].chars().next_back();
                !matches!(before, Some(c) if c == '.' || c == '_' || c.is_alphanumeric())
                    && !line.contains("fn read_to_string")
            });
            if bare_read || PATTERNS.iter().any(|p| line.contains(p)) {
                hits.push((i + 1, line.to_owned()));
            }
        }
        hits
    }

    #[test]
    fn raw_fs_scanner_detects_what_it_should() {
        assert_eq!(raw_fs_lines("let f = File::open(p)?;").len(), 1);
        assert_eq!(
            raw_fs_lines("let s = std::fs::read_to_string(p)?;").len(),
            1
        );
        assert_eq!(
            raw_fs_lines("use std::fs::{read_to_string};\nread_to_string(p)").len(),
            1
        );
        assert_eq!(raw_fs_lines("let d = fs::read_dir(p)?;").len(), 1);
        assert_eq!(raw_fs_lines("OpenOptions::new()").len(), 1);
        assert!(raw_fs_lines("// File::open is forbidden").is_empty());
        assert!(raw_fs_lines("child.stdout.read_to_string(&mut s)").is_empty());
        assert!(raw_fs_lines("fn ok() {}\n#[cfg(test)]\nmod t { fs::read(p); }").is_empty());
    }

    #[test]
    fn no_raw_fs_outside_module() {
        let src = crate_dir().join("src");
        let mut files = Vec::new();
        collect_rs(&src, &mut files);
        assert!(
            files.iter().any(|f| f.ends_with("lib.rs")),
            "walked the wrong directory"
        );
        let guard_dir = src.join("fs_guard");
        let mut offenders = Vec::new();
        for file in files.iter().filter(|f| !f.starts_with(&guard_dir)) {
            let text = fs::read_to_string(file).unwrap();
            for (line_no, line) in raw_fs_lines(&text) {
                offenders.push(format!("{}:{}: {}", file.display(), line_no, line.trim()));
            }
        }
        assert!(
            offenders.is_empty(),
            "raw filesystem reads outside fs_guard (use the file-access layer):\n{}",
            offenders.join("\n")
        );
    }
}
