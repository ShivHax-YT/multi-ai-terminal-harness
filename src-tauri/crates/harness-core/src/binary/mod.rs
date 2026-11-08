//! Official native CLI discovery and pinned signing policy (T-133).
//! No PATH search, npm/shim launch, credential-file read, or generic command API.

use crate::fs_guard;
use crate::process::{self, Capture, ProbeError, SignaturePolicy};
use crate::provider::ProviderId;
use serde::Deserialize;
use std::path::PathBuf;
use std::sync::OnceLock;

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

pub(crate) fn install_hint(provider: ProviderId) -> Option<&'static str> {
    pin(provider).map(|pin| pin.install_hint.as_str())
}

/// Try documented entrypoints without inspecting candidate paths or the CLI stores.
/// Only a missing entrypoint allows fallback. The kernel checks each launched image.
pub(crate) fn try_candidates<T>(
    provider: ProviderId,
    invoke: impl FnMut(&InstalledCli) -> Result<T, ProbeError>,
) -> Result<(InstalledCli, T), ProbeError> {
    let policy = pin(provider).ok_or(ProbeError::Unsupported)?;
    let home = fs_guard::account_home().map_err(|_| ProbeError::Failed)?;
    let candidates = [
        home.join(".local/bin").join(provider.as_str()),
        PathBuf::from("/opt/homebrew/bin").join(provider.as_str()),
        PathBuf::from("/usr/local/bin").join(provider.as_str()),
    ]
    .into_iter()
    .map(|path| InstalledCli {
        path,
        home: home.clone(),
        provider,
        policy: SignaturePolicy {
            team: &policy.team,
            identifier: &policy.identifier,
            release_cdhash: &policy.release_cdhash,
            platform_test: false,
        },
    });
    first_available(candidates, invoke)
}

fn first_available<T>(
    candidates: impl IntoIterator<Item = InstalledCli>,
    mut invoke: impl FnMut(&InstalledCli) -> Result<T, ProbeError>,
) -> Result<(InstalledCli, T), ProbeError> {
    for cli in candidates {
        match invoke(&cli) {
            Ok(output) => return Ok((cli, output)),
            Err(ProbeError::Missing) => continue,
            Err(error) => return Err(error),
        }
    }
    Err(ProbeError::Missing)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    #[test]
    fn discovery_falls_back_only_when_an_entrypoint_is_missing() {
        let pin = pin(ProviderId::Claude).unwrap();
        let candidates = || {
            ["/first", "/second"].map(|path| InstalledCli {
                path: path.into(),
                home: "/fake-home".into(),
                provider: ProviderId::Claude,
                policy: SignaturePolicy {
                    team: &pin.team,
                    identifier: &pin.identifier,
                    release_cdhash: &pin.release_cdhash,
                    platform_test: false,
                },
            })
        };
        let (cli, output) = first_available(candidates(), |cli| match cli.path.to_str() {
            Some("/first") => Err(ProbeError::Missing),
            Some("/second") => Ok("second"),
            _ => unreachable!(),
        })
        .unwrap();
        assert_eq!(cli.path, Path::new("/second"));
        assert_eq!(output, "second");
        assert!(matches!(
            first_available(candidates(), |_| Err::<(), _>(ProbeError::Missing)),
            Err(ProbeError::Missing)
        ));
        assert!(matches!(
            first_available(candidates(), |cli| {
                assert_eq!(cli.path, Path::new("/first"));
                Err::<(), _>(ProbeError::Verification)
            }),
            Err(ProbeError::Verification)
        ));
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
