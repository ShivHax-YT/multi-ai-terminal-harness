//! The credential denylist: parsing of `compliance/denylist.toml` and path matching (hard rule 4).
//!
//! The data file is the only place the credential directory names and Keychain service names appear. This module never
//! names them. Matching works on absolute paths and compares path components case-insensitively, so a case variant on a
//! case-insensitive volume cannot slip through. Callers pass canonicalized paths (see `open.rs`); this module also gets
//! the lexically normalized form so a refusal does not depend on the path existing.

use std::path::{Component, Path, PathBuf};
use std::sync::OnceLock;

use serde::Deserialize;
use thiserror::Error;

/// The denylist source, embedded at compile time. There is no run-time override.
pub const EMBEDDED_DENYLIST_TOML: &str = include_str!("../../../../../compliance/denylist.toml");

/// Why a denylist failed to load. Every variant is fatal: the layer fails closed.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum DenylistError {
    #[error("denylist is not valid TOML: {0}")]
    Parse(String),
    #[error("denylist has no home_dirs entries")]
    NoHomeDirs,
    #[error("denylist has no keychain_services entries")]
    NoKeychainServices,
    #[error("denylist entry {index} in {list} is not a plain relative path")]
    BadEntry { list: &'static str, index: usize },
    #[error("allowed_exceptions must be empty in Phase 1")]
    ExceptionsNotPermitted,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RawDenylist {
    home_dirs: Vec<String>,
    keychain_services: Vec<String>,
    #[serde(default)]
    allowed_exceptions: Vec<String>,
}

/// The parsed denylist data.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Denylist {
    home_dirs: Vec<String>,
    keychain_services: Vec<String>,
}

impl Denylist {
    /// The embedded list, parsed once per process. A parse failure is cached and returned on every call.
    pub fn embedded() -> Result<&'static Denylist, DenylistError> {
        static PARSED: OnceLock<Result<Denylist, DenylistError>> = OnceLock::new();
        PARSED
            .get_or_init(|| Denylist::parse(EMBEDDED_DENYLIST_TOML))
            .as_ref()
            .map_err(Clone::clone)
    }

    /// Parse a denylist document. Fails closed: empty lists, odd entries and any exception are errors.
    pub fn parse(toml_text: &str) -> Result<Denylist, DenylistError> {
        let raw: RawDenylist =
            toml::from_str(toml_text).map_err(|e| DenylistError::Parse(e.message().to_owned()))?;
        if raw.home_dirs.is_empty() {
            return Err(DenylistError::NoHomeDirs);
        }
        if raw.keychain_services.is_empty() {
            return Err(DenylistError::NoKeychainServices);
        }
        if !raw.allowed_exceptions.is_empty() {
            return Err(DenylistError::ExceptionsNotPermitted);
        }
        for (index, entry) in raw.home_dirs.iter().enumerate() {
            if !is_plain_relative(entry) {
                return Err(DenylistError::BadEntry {
                    list: "home_dirs",
                    index,
                });
            }
        }
        for (index, entry) in raw.keychain_services.iter().enumerate() {
            if entry.trim().is_empty() {
                return Err(DenylistError::BadEntry {
                    list: "keychain_services",
                    index,
                });
            }
        }
        Ok(Denylist {
            home_dirs: raw.home_dirs,
            keychain_services: raw.keychain_services,
        })
    }

    /// Entries relative to the account's home directory.
    pub fn home_dirs(&self) -> &[String] {
        &self.home_dirs
    }

    /// Keychain service names, exposed as data only.
    pub fn keychain_services(&self) -> &[String] {
        &self.keychain_services
    }
}

fn is_plain_relative(entry: &str) -> bool {
    !entry.is_empty()
        && !entry.starts_with('/')
        && !entry.contains('\\')
        && entry
            .split('/')
            .all(|seg| !seg.is_empty() && seg != "." && seg != "..")
}

/// Matches absolute paths against the denylist for one home directory.
#[derive(Debug, Clone)]
pub struct DenyMatcher {
    /// Lowercased component lists of every denied path, under both the given and the canonical home.
    denied: Vec<Vec<String>>,
}

impl DenyMatcher {
    /// Build the matcher for `home`. The caller expands `$HOME`; this only canonicalizes it, so a symlinked home is
    /// covered under both spellings.
    pub fn new(denylist: &Denylist, home: &Path) -> DenyMatcher {
        let mut homes = vec![lexical_normalize(home)];
        if let Ok(canonical) = home.canonicalize() {
            if !homes.contains(&canonical) {
                homes.push(canonical);
            }
        }
        let mut denied = Vec::new();
        for home in &homes {
            let base = components_lower(home);
            for entry in denylist.home_dirs() {
                let mut parts = base.clone();
                parts.extend(entry.split('/').map(str::to_lowercase));
                denied.push(parts);
            }
        }
        DenyMatcher { denied }
    }

    /// True when `path` is a denied path, anything under one, or a dot-continued sibling of one (a backup or lock copy).
    pub fn is_denied(&self, path: &Path) -> bool {
        let comps = components_lower(path);
        self.denied.iter().any(|d| matches_prefix(&comps, d))
    }
}

fn matches_prefix(path: &[String], denied: &[String]) -> bool {
    let n = denied.len();
    if path.len() < n {
        return false;
    }
    if path[..n - 1] != denied[..n - 1] {
        return false;
    }
    let (p, d) = (&path[n - 1], &denied[n - 1]);
    p == d || (p.starts_with(d.as_str()) && p[d.len()..].starts_with('.'))
}

fn components_lower(path: &Path) -> Vec<String> {
    path.components()
        .filter_map(|c| match c {
            Component::Normal(s) => Some(s.to_string_lossy().to_lowercase()),
            Component::Prefix(p) => Some(p.as_os_str().to_string_lossy().to_lowercase()),
            _ => None,
        })
        .collect()
}

/// Collapse `.` and `..` without touching the filesystem. `..` at the root stays at the root.
pub fn lexical_normalize(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for comp in path.components() {
        match comp {
            Component::CurDir => {}
            Component::ParentDir => {
                if matches!(out.components().next_back(), Some(Component::Normal(_))) {
                    out.pop();
                }
            }
            other => out.push(other.as_os_str()),
        }
    }
    out
}
