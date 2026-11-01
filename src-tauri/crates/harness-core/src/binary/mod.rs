//! Official native CLI discovery and pinned signing policy (T-133).
//! No PATH search, npm/shim launch, credential-file read, or generic command API.

use crate::fs_guard::{self, FileGuard, NullSink};
use crate::process::{self, Capture, ProbeError, SignaturePolicy};
use crate::provider::ProviderId;
use serde::Deserialize;
use std::path::PathBuf;
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

    pub fn probe(&self, command: ProbeCommand) -> Result<Capture, ProbeError> {
        // No task/agent/UI text enters argv. Worker invocation is absent here.
        let args: &[&str] = match (self.provider, command) {
            (_, ProbeCommand::Version) => &["--version"],
            (ProviderId::Claude, ProbeCommand::AuthStatus) => &["auth", "status"],
            (ProviderId::Codex, ProbeCommand::AuthStatus) => &["login", "status"],
            _ => return Err(ProbeError::Unsupported),
        };
        process::probe(&self.path, &self.home, self.policy, args)
    }
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
