//! Official native CLI discovery and pinned signing policy (T-133).
//! No PATH search, npm/shim launch, credential-file read, or generic command API.

use crate::fs_guard::{self, FileGuard, NullSink};
use crate::process::{self, Capture, ProbeError, SignaturePolicy};
use crate::provider::ProviderId;
use serde::Deserialize;
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};

#[derive(Deserialize)]
struct Pins {
    vendor: Vec<Pin>,
}

#[derive(Deserialize)]
struct Pin {
    provider: ProviderId,
    team: String,
    identifier: String,
    release_cdhash: String,
    install_hint: String,
}

fn pin(provider: ProviderId) -> Option<&'static Pin> {
    static PINS: OnceLock<Option<Pins>> = OnceLock::new();
    PINS.get_or_init(|| {
        toml::from_str(include_str!("../../../../../compliance/vendor-pins.toml")).ok()
    })
    .as_ref()?
    .vendor
    .iter()
    .find(|pin| pin.provider == provider)
}

pub(crate) enum Discovery {
    Missing,
    Unverified,
    Found(InstalledCli),
}

pub(crate) struct InstalledCli {
    pub path: PathBuf,
    home: PathBuf,
    provider: ProviderId,
    policy: SignaturePolicy,
}

#[derive(Clone, Copy)]
pub(crate) enum ProbeCommand {
    Version,
    AuthStatus,
}

impl InstalledCli {
    pub fn terminal_login(&self) -> Result<i32, ProbeError> {
        let args: &[&str] = match self.provider {
            ProviderId::Claude => &["auth", "login"],
            ProviderId::Codex => &["login"],
            _ => return Err(ProbeError::Unsupported),
        };
        process::terminal_login(&self.path, &self.home, self.policy, args)
    }

    /// The CLI's own interactive mode, no arguments, for a human on a real terminal.
    pub fn terminal_session(
        &self,
        cwd: &Path,
        ambient: &[(String, String)],
    ) -> Result<i32, ProbeError> {
        let env: Vec<String> = session_env(&self.home, ambient)
            .into_iter()
            .map(|(key, value)| format!("{key}={value}"))
            .collect();
        process::terminal_session(&self.path, cwd, self.policy, &env)
    }

    fn probe_args(&self, command: ProbeCommand) -> Result<&'static [&'static str], ProbeError> {
        // No task/agent/UI text enters argv. Worker invocation is absent here.
        match (self.provider, command) {
            (_, ProbeCommand::Version) => Ok(&["--version"]),
            (ProviderId::Claude, ProbeCommand::AuthStatus) => Ok(&["auth", "status"]),
            (ProviderId::Codex, ProbeCommand::AuthStatus) => Ok(&["login", "status"]),
            _ => Err(ProbeError::Unsupported),
        }
    }

    pub fn probe(&self, command: ProbeCommand) -> Result<Capture, ProbeError> {
        let args = self.probe_args(command)?;
        process::probe(&self.path, &self.home, self.policy, args)
    }

    /// For reporting status when the pinned probe refused: a routine vendor update changes the release hash. The
    /// kernel still requires the vendor identity. The caller records that the release is unreviewed.
    pub fn probe_any_release(&self, command: ProbeCommand) -> Result<Capture, ProbeError> {
        let args = self.probe_args(command)?;
        process::probe_any_release(&self.path, &self.home, self.policy, args)
    }
}

/// Everything an interactive CLI may inherit from the launch environment. This is an allowlist, so a config-home
/// override (rule 2) or anything else set in the app's environment never reaches a CLI.
const SESSION_ENV_PASSTHROUGH: [&str; 3] = ["SHELL", "TMPDIR", "SSH_AUTH_SOCK"];

/// The whole environment of a human terminal session (rules 2 and 4). The CLI keeps its default config home.
pub fn session_env(home: &Path, ambient: &[(String, String)]) -> Vec<(String, String)> {
    let home_text = home.to_string_lossy();
    let path = format!(
        "{home_text}/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    );
    let mut env = vec![
        ("HOME".to_owned(), home_text.into_owned()),
        ("PATH".to_owned(), path),
        ("TERM".to_owned(), "xterm-256color".to_owned()),
        ("COLORTERM".to_owned(), "truecolor".to_owned()),
        ("LANG".to_owned(), "en_US.UTF-8".to_owned()),
    ];
    for (key, value) in ambient {
        if SESSION_ENV_PASSTHROUGH.contains(&key.as_str()) {
            env.push((key.clone(), value.clone()));
        }
    }
    env
}

pub(crate) fn install_hint(provider: ProviderId) -> Option<&'static str> {
    pin(provider).map(|pin| pin.install_hint.as_str())
}

pub(crate) fn discover(provider: ProviderId) -> Discovery {
    let Some(pin) = pin(provider) else {
        return Discovery::Missing;
    };
    let Ok(home) = fs_guard::account_home() else {
        return Discovery::Unverified;
    };
    let Ok(guard) = FileGuard::new(&home, Arc::new(NullSink)) else {
        return Discovery::Unverified;
    };
    // Documented native installation entrypoints only. The CLI-specific guard
    // exception resolves the public executable, never siblings in its store.
    let candidates = [
        home.join(".local/bin").join(provider.as_str()),
        PathBuf::from("/opt/homebrew/bin").join(provider.as_str()),
        PathBuf::from("/usr/local/bin").join(provider.as_str()),
    ];
    for candidate in candidates {
        match guard.exec_resolve(&candidate) {
            Ok(path) => {
                return Discovery::Found(InstalledCli {
                    path,
                    home,
                    provider,
                    policy: SignaturePolicy {
                        team: &pin.team,
                        identifier: &pin.identifier,
                        release_cdhash: &pin.release_cdhash,
                        platform_test: false,
                    },
                })
            }
            Err(fs_guard::GuardError::Io(e)) if e.kind() == std::io::ErrorKind::NotFound => {}
            // Refuse a present but unsafe preferred installation; don't silently
            // fall through to a different binary or trust an arbitrary PATH entry.
            Err(_) => return Discovery::Unverified,
        }
    }
    Discovery::Missing
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_session_environment_is_an_allowlist_without_config_homes() {
        // Any name outside the allowlist is dropped, including a provider's config-home override (rule 2).
        let ambient: Vec<(String, String)> = [
            "SOME_PROVIDER_HOME",
            "SOME_CONFIG_DIR",
            "ANTHROPIC_API_KEY",
            "OPENAI_API_KEY",
            "CLAUDECODE",
            "SSH_AUTH_SOCK",
        ]
        .iter()
        .map(|key| (key.to_string(), "x".to_string()))
        .collect();
        let env = session_env(Path::new("/Users/someone"), &ambient);
        let keys: Vec<&str> = env.iter().map(|(key, _)| key.as_str()).collect();
        assert_eq!(
            keys,
            ["HOME", "PATH", "TERM", "COLORTERM", "LANG", "SSH_AUTH_SOCK"]
        );
    }

    #[test]
    fn only_the_two_native_providers_have_compiled_trust_pins() {
        for provider in ProviderId::ALL {
            let policy = pin(provider);
            assert_eq!(
                policy.is_some(),
                matches!(provider, ProviderId::Claude | ProviderId::Codex)
            );
            if let Some(policy) = policy {
                assert_eq!(policy.team.len(), 10);
                assert!(!policy.identifier.is_empty());
                assert_eq!(policy.release_cdhash.len(), 40);
                assert!(policy.release_cdhash.chars().all(|c| c.is_ascii_hexdigit()));
                assert!(policy.install_hint.starts_with("Install the "));
            }
        }
    }
}
