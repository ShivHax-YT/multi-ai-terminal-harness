//! The credential denylist: parsing of `compliance/denylist.toml` and path matching (hard rule 4).
//!
//! The data file is the only place the credential directory names and Keychain service names appear. This module never
//! names them. Matching works on absolute paths and compares path components case-insensitively, so a case variant on a
//! case-insensitive volume cannot slip through. A [`DenySnapshot`] is taken per check and also covers where each
//! existing entry really lives: if the user made an entry a symlink to a dotfiles repo, the target subtree is denied
//! too, and the (device, inode) of each entry is remembered so a different spelling of the same object is still caught.

use std::fs;
use std::os::unix::fs::MetadataExt;
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

/// The parsed denylist data. Only the embedded list can be loaded outside this crate.
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

    /// Parse a denylist document. Fails closed: empty lists, odd entries and any exception are errors. Crate-private so
    /// no caller can build a weaker list than the embedded one.
    pub(crate) fn parse(toml_text: &str) -> Result<Denylist, DenylistError> {
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

/// One denied path as lowercase components.
#[derive(Debug, Clone)]
struct Prefix {
    comps: Vec<String>,
    /// True for the entries named in the denylist: the final component also matches a name that continues the entry
    /// after a non-alphanumeric character (a backup, lock or renamed copy). False for resolved symlink targets, where
    /// only the exact subtree is denied.
    fuzzy_last: bool,
}

impl Prefix {
    fn matches(&self, path: &[String]) -> bool {
        let n = self.comps.len();
        if n == 0 || path.len() < n || path[..n - 1] != self.comps[..n - 1] {
            return false;
        }
        let (p, d) = (&path[n - 1], &self.comps[n - 1]);
        if p == d {
            return true;
        }
        self.fuzzy_last
            && p.starts_with(d.as_str())
            && p[d.len()..]
                .chars()
                .next()
                .is_some_and(|c| !c.is_alphanumeric())
    }
}

/// Builds [`DenySnapshot`]s for a set of account homes.
#[derive(Debug, Clone)]
pub struct DenyMatcher {
    /// Every spelling (given and canonical) of every home.
    homes: Vec<PathBuf>,
    entries: Vec<String>,
}

impl DenyMatcher {
    /// Expand canonical spellings only for fake homes used to exercise the guard's filesystem checks.
    pub(crate) fn new(denylist: &Denylist, homes: &[PathBuf], fixture_access: bool) -> DenyMatcher {
        let mut all: Vec<PathBuf> = Vec::new();
        for home in homes {
            let mut spellings = vec![lexical_normalize(home)];
            if let Some(Ok(canonical)) = fixture_access.then(|| home.canonicalize()) {
                spellings.push(canonical);
            }
            for s in spellings {
                if !all.contains(&s) {
                    all.push(s);
                }
            }
        }
        DenyMatcher {
            homes: all,
            entries: denylist.home_dirs().to_vec(),
        }
    }

    /// Take a snapshot of what is denied right now. Cheap but not free: it looks at each existing entry on disk, so a
    /// symlink created after the guard was built is still honored.
    pub(crate) fn snapshot(&self) -> DenySnapshot {
        let mut prefixes = Vec::new();
        let mut identities: Vec<(u64, u64)> = Vec::new();
        for home in &self.homes {
            for entry in &self.entries {
                let mut comps = components_lower(home);
                comps.extend(entry.split('/').map(str::to_lowercase));
                prefixes.push(Prefix {
                    comps,
                    fuzzy_last: true,
                });
                let spot = entry
                    .split('/')
                    .fold(home.clone(), |acc, seg| acc.join(seg));
                let is_link = fs::symlink_metadata(&spot)
                    .map(|m| m.file_type().is_symlink())
                    .unwrap_or(false);
                if is_link {
                    if let Some(target) = link_target(&spot) {
                        prefixes.push(Prefix {
                            comps: components_lower(&target),
                            fuzzy_last: false,
                        });
                    }
                }
                if let Ok(meta) = fs::metadata(&spot) {
                    identities.push((meta.dev(), meta.ino()));
                }
            }
        }
        identities.sort_unstable();
        identities.dedup();
        DenySnapshot {
            prefixes,
            identities,
        }
    }
}

/// Where a symlink really points: the canonical target when it exists, otherwise the lexically resolved link text.
fn link_target(link: &Path) -> Option<PathBuf> {
    if let Ok(canonical) = link.canonicalize() {
        return Some(canonical);
    }
    let text = fs::read_link(link).ok()?;
    let joined = if text.is_absolute() {
        text
    } else {
        link.parent()?.join(text)
    };
    Some(lexical_normalize(&joined))
}

/// A point-in-time view of what is denied.
#[derive(Debug, Clone)]
pub struct DenySnapshot {
    prefixes: Vec<Prefix>,
    identities: Vec<(u64, u64)>,
}

impl DenySnapshot {
    /// True when `path` is a denied path, anything under one, a continuation-named sibling of one, or inside the real
    /// location of a symlinked entry.
    pub fn is_denied(&self, path: &Path) -> bool {
        let comps = components_lower(path);
        self.prefixes.iter().any(|p| p.matches(&comps))
    }

    /// True when `path` or any directory above it is the same filesystem object (device and inode) as a denied entry.
    /// A backstop for spellings the path comparison cannot see.
    pub fn identity_denied(&self, path: &Path) -> bool {
        if self.identities.is_empty() {
            return false;
        }
        path.ancestors().any(|a| {
            fs::metadata(a)
                .map(|m| self.identities.binary_search(&(m.dev(), m.ino())).is_ok())
                .unwrap_or(false)
        })
    }

    /// True when `meta` describes the same object as a denied entry that is a file.
    pub fn is_denied_object(&self, meta: &fs::Metadata) -> bool {
        meta.is_file()
            && self
                .identities
                .binary_search(&(meta.dev(), meta.ino()))
                .is_ok()
    }
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
