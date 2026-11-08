//! Static source checks for the file-access layer (hard rule 4): Keychain service names live in the denylist file only,
//! and no workspace code outside `fs_guard` opens files directly. The behavioural tests live in the crate
//! (`src/fs_guard/tests/`) because they need guards over fake homes.

mod fs_guard {
    use harness_core::fs_guard::Denylist;
    use std::fs;
    use std::path::{Path, PathBuf};

    fn crate_dir() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
    }

    fn src_tauri() -> PathBuf {
        crate_dir()
            .join("..")
            .join("..")
            .canonicalize()
            .expect("src-tauri directory")
    }

    fn collect_sources(dir: &Path, out: &mut Vec<PathBuf>) {
        let entries = fs::read_dir(dir)
            .unwrap_or_else(|error| panic!("cannot scan {}: {error}", dir.display()));
        for entry in entries {
            let entry = entry.expect("cannot inspect source directory entry");
            let path = entry.path();
            let name = entry.file_name();
            let name = name.to_string_lossy();
            if matches!(name.as_ref(), "target" | "node_modules" | ".git") {
                continue;
            }
            let kind = entry.file_type().expect("cannot inspect source file type");
            assert!(
                !kind.is_symlink(),
                "unexpected symlink at {}",
                path.display()
            );
            if kind.is_dir() {
                collect_sources(&path, out);
            } else if kind.is_file()
                && matches!(
                    path.extension().and_then(|ext| ext.to_str()),
                    Some("rs" | "swift")
                )
            {
                out.push(path);
            }
        }
    }

    #[test]
    fn keychain_names_only_in_denylist() {
        let mut files = Vec::new();
        collect_sources(&src_tauri(), &mut files);
        assert!(
            files.len() > 5,
            "walked too few files ({}); the path to src-tauri is wrong",
            files.len()
        );
        let list = Denylist::embedded().unwrap();
        assert!(!list.keychain_services().is_empty());
        let keychain_apis = [
            ["SecItem", "CopyMatching"],
            ["SecKeychain", "FindGenericPassword"],
            ["SecKeychain", "FindInternetPassword"],
        ]
        .map(|parts| parts.concat());
        for file in &files {
            let text = fs::read_to_string(file).unwrap();
            for api in &keychain_apis {
                assert!(
                    !text.contains(api),
                    "{} queries Keychain directly",
                    file.display()
                );
            }
            for name in list.keychain_services() {
                assert!(
                    !text.contains(name.as_str()),
                    "{} names a Keychain service; those names live in compliance/denylist.toml only",
                    file.display()
                );
            }
        }
    }

    const PATTERNS: &[&str] = &[
        "File::open",
        "File::create",
        "OpenOptions",
        "std::fs::File",
        "fs::read",
        "fs::write",
        "fs::metadata",
        "fs::copy",
        "fs::canonicalize",
        "fs::rename",
        "fs::remove",
        "fs::create_dir",
        "fs::symlink_metadata",
        "tokio::fs",
        "Connection::open",
        ".canonicalize(",
        ".is_file(",
        ".is_dir(",
        ".metadata(",
        ".symlink_metadata(",
        "libc::open(",
        "libc::openat(",
        "FileManager",
        "forReadingAtPath",
        "forWritingAtPath",
        "Data(contentsOf:",
        "NSOpenPanel",
    ];

    /// True when a complete `use` statement brings in the standard or async filesystem module in any spelling: plain,
    /// aliased (`as f`), grouped (`{self, File}`) or nested in `std::{...}`.
    fn use_imports_fs(statement: &str) -> bool {
        let rest = statement
            .trim_start_matches("pub ")
            .trim_start_matches("pub(crate) ")
            .trim_start_matches("use ")
            .trim();
        if rest.contains("std::fs") || rest.contains("tokio::fs") {
            return true;
        }
        if rest.starts_with("std::{") || rest.starts_with("tokio::{") {
            return rest
                .split(|c: char| !(c.is_alphanumeric() || c == '_'))
                .any(|token| token == "fs");
        }
        false
    }

    /// Lines of `text` that spell direct filesystem operations. Skip comment lines and rustfmt-style test modules,
    /// resuming at the first line after each module. Returns (1-based line number of the statement, text).
    fn raw_fs_lines(text: &str) -> Vec<(usize, String)> {
        let lines: Vec<&str> = text.lines().collect();
        let mut hits = Vec::new();
        let mut pending_use: Option<(usize, String)> = None;
        let mut skip_until = 0;
        for (i, line) in lines.iter().enumerate() {
            if i < skip_until {
                continue;
            }
            let trimmed = line.trim_start();
            if trimmed == "#[cfg(test)]" {
                if let Some((index, module)) =
                    lines.iter().enumerate().skip(i + 1).find(|(_, line)| {
                        !line.trim_start().starts_with("#[") && !line.trim().is_empty()
                    })
                {
                    let declaration = module.trim_start();
                    if declaration.starts_with("mod ") || declaration.starts_with("pub mod ") {
                        skip_until = index + 1;
                        if declaration.trim_end().ends_with('{') {
                            let indent = &module[..module.len() - declaration.len()];
                            let closing = format!("{indent}}}");
                            let end = lines
                                .iter()
                                .enumerate()
                                .skip(index + 1)
                                .find(|(_, line)| line.trim_end() == closing)
                                .expect("test module must have a rustfmt-style closing brace");
                            skip_until = end.0 + 1;
                        }
                        continue;
                    }
                }
            }
            if trimmed.starts_with("//") {
                continue;
            }
            if let Some((start, buf)) = pending_use.as_mut() {
                buf.push(' ');
                buf.push_str(trimmed);
                if trimmed.contains(';') {
                    if use_imports_fs(buf) {
                        hits.push((*start, buf.clone()));
                    }
                    pending_use = None;
                }
                continue;
            }
            let is_use = ["use ", "pub use ", "pub(crate) use "]
                .iter()
                .any(|p| trimmed.starts_with(p));
            if is_use {
                if trimmed.contains(';') {
                    if use_imports_fs(trimmed) {
                        hits.push((i + 1, (*line).to_owned()));
                    }
                } else {
                    pending_use = Some((i + 1, trimmed.to_owned()));
                }
                continue;
            }
            let bare_read = line.match_indices("read_to_string(").any(|(at, _)| {
                let before = line[..at].chars().next_back();
                !matches!(before, Some(c) if c == '.' || c == '_' || c.is_alphanumeric())
                    && !line.contains("fn read_to_string")
            });
            let qualified = line.contains("std::fs::");
            if bare_read || qualified || PATTERNS.iter().any(|p| line.contains(p)) {
                hits.push((i + 1, (*line).to_owned()));
            }
        }
        hits
    }

    #[test]
    fn raw_fs_scanner_detects_what_it_should() {
        for hit in [
            "let f = File::open(p)?;",
            "let f = std::fs::File::create(p)?;",
            "let s = std::fs::read_to_string(p)?;",
            "use std::fs::{read_to_string};\nread_to_string(p)",
            "let d = fs::read_dir(p)?;",
            "OpenOptions::new()",
            "fs::write(p, b)?;",
            "let m = fs::metadata(p)?;",
            "fs::copy(a, b)?;",
            "fs::canonicalize(p)?;",
            "fs::rename(a, b)?;",
            "fs::remove_file(p)?;",
            "fs::remove_dir_all(p)?;",
            "tokio::fs::read(p).await?;",
            "let c = rusqlite::Connection::open(p)?;",
            "let p = path.canonicalize()?;",
            "let p = path.is_dir();",
            "let p = unsafe { libc::open(path, flags) };",
            "let data = try Data(contentsOf: path)",
            "let panel = NSOpenPanel()",
            // Imports, in every spelling.
            "use std::fs;",
            "use std::fs as f;",
            "use std::fs::File as F;",
            "use std::fs::{self, File};",
            "use std::fs::{\n    self,\n    File,\n};",
            "use std::{fs, io};",
            "use std::{\n    io,\n    fs,\n};",
            "use std::{io, fs::File};",
            "use tokio::fs;",
            "use tokio::{fs as tfs, io};",
            "pub use std::fs::File;",
            "pub(crate) use std::fs as f;",
        ] {
            assert!(!raw_fs_lines(hit).is_empty(), "missed: {hit}");
        }
        for fine in [
            "// File::open is forbidden",
            "child.stdout.read_to_string(&mut s)",
            "use std::io::Read;",
            "use std::os::unix::fs::PermissionsExt;",
            "use std::{io, path::Path};",
            "use std::{\n    io,\n    path::Path,\n};",
        ] {
            assert!(raw_fs_lines(fine).is_empty(), "false hit: {fine}");
        }
        assert!(raw_fs_lines("fn ok() {}\n#[cfg(test)]\nmod t { fs::read(p); }").is_empty());
        assert_eq!(
            raw_fs_lines("#[cfg(test)]\nmod t {\n    fs::read(p);\n}\nfs::read(q);"),
            vec![(5, "fs::read(q);".to_owned())]
        );
        assert_eq!(
            raw_fs_lines("#[cfg(test)]\nmod t;\nfs::read(q);"),
            vec![(3, "fs::read(q);".to_owned())]
        );
        assert_eq!(
            raw_fs_lines("#[cfg(test)]\nfn helper() {}\nfs::read(p);").len(),
            1
        );
    }

    #[test]
    fn no_raw_fs_outside_module() {
        // Every workspace crate's src, except the file-access layer itself.
        let mut roots = vec![src_tauri().join("src")];
        let crates = src_tauri().join("crates");
        for entry in fs::read_dir(&crates).unwrap() {
            let entry = entry.expect("cannot inspect workspace crate");
            if entry
                .file_type()
                .expect("cannot inspect workspace crate type")
                .is_dir()
            {
                roots.push(entry.path().join("src"));
            }
        }
        let mut files = Vec::new();
        for root in &roots {
            collect_sources(root, &mut files);
        }
        collect_sources(&crate_dir().join("native"), &mut files);
        assert!(
            files.iter().any(|f| f.ends_with("harness-core/src/lib.rs")),
            "walked the wrong directory"
        );
        assert!(
            roots.len() >= 3,
            "expected the core crate, the terminal crate and the app shell"
        );
        let guard_dir = crate_dir()
            .canonicalize()
            .unwrap()
            .join("src")
            .join("fs_guard");
        let mut offenders = Vec::new();
        for file in files.iter().filter(|f| !f.starts_with(&guard_dir)) {
            let text = fs::read_to_string(file).unwrap();
            for (line_no, line) in raw_fs_lines(&text) {
                offenders.push(format!("{}:{}: {}", file.display(), line_no, line.trim()));
            }
        }
        assert!(
            offenders.is_empty(),
            "raw filesystem access outside fs_guard (use the file-access layer):\n{}",
            offenders.join("\n")
        );
    }
}
