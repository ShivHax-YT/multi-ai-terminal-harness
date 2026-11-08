//! Real CLI observations, kept separate from permission to execute work (T-133).
//! Raw CLI output, account details and tokens never enter the IPC response/logs.

use crate::binary::{self, ProbeCommand};
use crate::process::{Capture, ProbeError};
use crate::provider::ProviderId;
use serde_json::{json, Value};
use std::collections::BTreeSet;
use std::sync::Mutex;

#[derive(Default)]
pub struct ProviderRegistry {
    confirmed: Mutex<BTreeSet<ProviderId>>,
}

/// Called only by the app's explicit human Terminal login mode, never by a task
/// or scheduler. The CLI's own sign-in UI handles every authentication response.
pub fn login_in_terminal(provider: ProviderId) -> Result<i32, String> {
    binary::try_candidates(provider, binary::InstalledCli::terminal_login)
        .map(|(_, code)| code)
        .map_err(|e| e.to_string())
}

impl ProviderRegistry {
    pub fn list(&self) -> Vec<Value> {
        ProviderId::ALL
            .into_iter()
            .map(|id| self.refresh(id))
            .collect()
    }

    pub fn refresh(&self, provider: ProviderId) -> Value {
        let mut status = unavailable(provider);
        if !supported(provider) {
            return status;
        }
        // Search only by attempting a kernel-verified launch. The app never resolves or stats the executable
        // or a credential-store alias. Prefer the reviewed image and report a distinct scope after a pin mismatch.
        let probe =
            binary::try_candidates(provider, |cli| match cli.probe(ProbeCommand::Version) {
                Err(ProbeError::Verification) => match cli.probe_any_release(ProbeCommand::Version)
                {
                    Err(ProbeError::Missing) => Err(ProbeError::Verification),
                    result => result.map(|capture| (capture, false)),
                },
                result => result.map(|capture| (capture, true)),
            });
        let (cli, (capture, release_reviewed)) = match probe {
            Ok(result) => result,
            Err(ProbeError::Missing) => return status,
            Err(error) => {
                status["install"]["state"] = json!("unknown");
                probe_failure(&mut status, &error);
                return status;
            }
        };
        status["install"]["state"] = json!("installed");
        status["install"]["path"] = json!(cli.path);
        status["binary"]["checked_at"] = json!(chrono::Utc::now().to_rfc3339());
        let version = (capture.code == 0)
            .then(|| parse_version(provider, &capture.stdout))
            .flatten();
        let Some(version) = version else {
            status["binary"]["state"] = json!("unchecked");
            status["sign_in"]["detail"] =
                json!("The CLI did not return a supported version response.");
            status["usable"]["blockers"] = json!([
                "binary_unchecked",
                "execution_boundary_unavailable",
                "runtime_controls_unavailable",
                "provider_policy_unverified"
            ]);
            return status;
        };
        status["install"]["version"] = json!(version);
        status["binary"]["state"] = json!("verified");
        status["binary"]["verification_scope"] = json!("kernel_identity");
        status["binary"]["release_reviewed"] = json!(release_reviewed);
        status["binary"]["checks"] = json!([
            {"kind":"codesign", "result":"pass", "detail":codesign_detail(release_reviewed)},
            {"kind":"install_source", "result":"not_checked", "detail":"Found at a supported CLI entrypoint. Installer provenance was not verified."}
        ]);
        // Authentication has its own documented interface. Worker/help support
        // must not suppress an authentication observation. No worker verb is
        // exposed by this lane, and successful auth never grants dispatch.
        let auth_probe = if release_reviewed {
            cli.probe(ProbeCommand::AuthStatus)
        } else {
            cli.probe_any_release(ProbeCommand::AuthStatus)
        };
        let (state, detail) = match auth_probe {
            Ok(output) => parse_auth(provider, &output),
            Err(error) => {
                probe_failure(&mut status, &error);
                return status;
            }
        };
        status["sign_in"] =
            json!({"state":state, "detail":detail, "checked_at":chrono::Utc::now().to_rfc3339()});
        // Preparation only: the human runs the vendor's official browser login
        // in their own Terminal. No interactive keystroke or login/account change
        // is dispatched by this app. A refresh checks the actual CLI afterward.
        if state != "signed_in" && release_reviewed {
            if let Ok(executable) = std::env::current_exe() {
                // The app's closed Terminal mode re-applies the kernel identity
                // requirement at the moment of login, instead of asking the
                // human to launch a mutable provider pathname directly.
                status["sign_in"]["login_command"] = json!(format!(
                    "{} --provider-login={provider}",
                    shell_literal(&executable.to_string_lossy())
                ));
            }
        }
        let confirmed = self
            .confirmed
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .contains(&provider);
        status["personal_use_confirmed"] = json!(confirmed);
        // Lead and worker stay false. An unreviewed vendor release is also an explicit task blocker.
        set_task_usability(&mut status, release_reviewed, state, confirmed);
        status
    }

    pub fn confirm(&self, provider: ProviderId) -> Result<Value, &'static str> {
        if !supported(provider) {
            return Err("This provider has no supported subscription onboarding.");
        }
        let mut status = self.refresh(provider);
        if status["binary"]["state"] != "verified" {
            return Err("Verify the official CLI before confirming personal use.");
        }
        self.confirmed
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(provider);
        status["personal_use_confirmed"] = json!(true);
        if let Some(blockers) = status["usable"]["blockers"].as_array_mut() {
            blockers.retain(|b| b != "personal_use_unconfirmed");
        }
        Ok(status)
    }
}

fn codesign_detail(release_reviewed: bool) -> &'static str {
    if release_reviewed {
        "macOS enforced the pinned vendor, CLI identifier, Developer ID category and hardened runtime at launch."
    } else {
        "macOS enforced the vendor, CLI identifier, Developer ID category and hardened runtime at launch. This vendor-signed release does not match the reviewed release pin."
    }
}

fn supported(provider: ProviderId) -> bool {
    matches!(provider, ProviderId::Claude | ProviderId::Codex)
}

/// Automated workers remain closed until the execution boundary and runtime controls are connected.
const WORKERS_ENABLED: bool = false;

/// Writes the automated-task gate and the independent blocker for an unreviewed release.
fn set_task_usability(status: &mut Value, release_reviewed: bool, sign_in: &str, confirmed: bool) {
    let blockers = automated_task_blockers(release_reviewed, sign_in, confirmed);
    let allowed = tasks_enabled(&blockers);
    status["usable"] = json!({
        "lead": allowed,
        "worker": allowed,
        "blockers": blockers,
    });
}

fn tasks_enabled(blockers: &[&str]) -> bool {
    WORKERS_ENABLED && blockers.is_empty()
}

/// Blockers for automated tasks. `lead` and `worker` are never turned on by this list.
fn automated_task_blockers(
    release_reviewed: bool,
    sign_in: &str,
    confirmed: bool,
) -> Vec<&'static str> {
    let mut blockers = vec![
        "execution_boundary_unavailable",
        "runtime_controls_unavailable",
        "provider_policy_unverified",
    ];
    if !release_reviewed {
        blockers.push("release_unreviewed");
    }
    if sign_in == "signed_out" {
        blockers.push("signed_out");
    }
    if sign_in == "unknown" {
        blockers.push("sign_in_unknown");
    }
    if !confirmed {
        blockers.push("personal_use_unconfirmed");
    }
    blockers
}

fn probe_failure(status: &mut Value, error: &ProbeError) {
    let refused = matches!(error, ProbeError::Verification);
    status["binary"] = json!({
        "state": if refused { "failed" } else { "unchecked" },
        "checks": [{"kind": "codesign", "result": if refused { "fail" } else { "not_checked" }, "detail": error.to_string()}],
    });
    status["sign_in"] = json!({"state":"unknown", "detail":error.to_string()});
    status["usable"]["blockers"] = json!([
        if refused {
            "binary_failed"
        } else {
            "binary_unchecked"
        },
        "execution_boundary_unavailable",
        "runtime_controls_unavailable",
        "provider_policy_unverified"
    ]);
}

fn unavailable(provider: ProviderId) -> Value {
    let available = supported(provider);
    json!({
        "provider":provider,
        "adapter_available":available,
        "auth_modes":if provider == ProviderId::Gemini { vec!["api_key"] } else if available { vec!["subscription"] } else { vec![] },
        "install":{"state":"not_installed", "install_hint":binary::install_hint(provider)},
        "binary":{"state":"unchecked", "checks":[]},
        "sign_in":{"state":"unknown"},
        "personal_use_confirmed":false,
        "api_key":null,
        "killswitch":if provider == ProviderId::Gemini { "api_key_only" } else { "unknown" },
        "usable":{"lead":false, "worker":false, "blockers":if available { vec!["not_installed", "execution_boundary_unavailable", "runtime_controls_unavailable", "provider_policy_unverified"] } else { vec!["adapter_unavailable"] }}
    })
}

fn parse_version(provider: ProviderId, stdout: &str) -> Option<String> {
    let text = stdout.trim();
    if text.len() > 128 || text.contains(['\n', '\r']) {
        return None;
    }
    let version = match provider {
        ProviderId::Claude => text.strip_suffix(" (Claude Code)")?,
        ProviderId::Codex => text.strip_prefix("codex-cli ")?,
        _ => return None,
    };
    if !version.starts_with(|c: char| c.is_ascii_digit())
        || !version
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || ".-+".contains(c))
    {
        return None;
    }
    Some(version.to_owned())
}

fn parse_auth(provider: ProviderId, output: &Capture) -> (&'static str, &'static str) {
    const UNKNOWN: (&str, &str) = (
        "unknown",
        "The CLI response was not a recognized authentication result.",
    );
    match provider {
        ProviderId::Claude => {
            let Ok(value) = serde_json::from_str::<Value>(&output.stdout) else {
                return UNKNOWN;
            };
            match (output.code, value["loggedIn"].as_bool(), value["authMethod"].as_str()) {
                (0, Some(true), Some("claude.ai" | "oauth_token")) => ("signed_in", "The official CLI reports a stored subscription sign-in; no inference request was made."),
                (1, Some(false), Some("none")) => ("signed_out", "The official CLI reports that you are signed out."),
                (0, Some(true), Some("api_key" | "api_key_helper" | "third_party")) => ("unknown", "The CLI uses API or third-party authentication. App-managed API spend caps are not available."),
                _ => UNKNOWN,
            }
        }
        ProviderId::Codex => {
            // The documented interface is plain text plus exit status. Do not
            // infer sign-in from exit 0 alone or retain an API-key diagnostic.
            let text = if output.stderr.trim().is_empty() {
                output.stdout.trim()
            } else if output.stdout.trim().is_empty() {
                output.stderr.trim()
            } else {
                return UNKNOWN;
            };
            match (output.code, text) {
                (0, "Logged in using ChatGPT") => ("signed_in", "The official CLI reports a stored subscription sign-in; no inference request was made."),
                (1, "Not logged in") => ("signed_out", "The official CLI reports that you are signed out."),
                _ => UNKNOWN,
            }
        }
        _ => UNKNOWN,
    }
}

fn shell_literal(text: &str) -> String {
    format!("'{}'", text.replace('\'', "'\\''"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn capture(code: i32, stdout: &str, stderr: &str) -> Capture {
        Capture {
            code,
            stdout: stdout.into(),
            stderr: stderr.into(),
        }
    }

    #[test]
    fn authentication_requires_consistent_documented_output_and_exit_status() {
        assert_eq!(parse_auth(ProviderId::Claude, &capture(0, r#"{"loggedIn":true,"authMethod":"claude.ai","email":"private@example.invalid"}"#, "")).0, "signed_in");
        assert_eq!(
            parse_auth(
                ProviderId::Claude,
                &capture(0, r#"{"loggedIn":false,"authMethod":"none"}"#, "")
            )
            .0,
            "unknown"
        );
        assert_eq!(
            parse_auth(
                ProviderId::Claude,
                &capture(1, r#"{"loggedIn":false,"authMethod":"none"}"#, "")
            )
            .0,
            "signed_out"
        );
        assert_eq!(
            parse_auth(
                ProviderId::Codex,
                &capture(0, "", "Logged in using ChatGPT\n")
            )
            .0,
            "signed_in"
        );
        assert_eq!(
            parse_auth(ProviderId::Codex, &capture(1, "", "Not logged in\n")).0,
            "signed_out"
        );
        for output in [
            capture(0, "", ""),
            capture(0, "unknown", ""),
            capture(1, "", "Logged in using ChatGPT"),
            capture(0, "", "Logged in using an API key - never-return-this"),
        ] {
            let (state, detail) = parse_auth(ProviderId::Codex, &output);
            assert_eq!(state, "unknown");
            assert!(!detail.contains("never-return-this"));
        }
    }

    #[test]
    fn native_defaults_never_claim_automation_readiness_or_a_live_policy() {
        for provider in ProviderId::ALL {
            let status = unavailable(provider);
            assert_eq!(status["usable"]["lead"], false);
            assert_eq!(status["usable"]["worker"], false);
            assert_ne!(status["killswitch"], "enabled");
            assert_ne!(status["sign_in"]["state"], "signed_in");
        }
        assert_eq!(
            unavailable(ProviderId::Gemini)["auth_modes"],
            json!(["api_key"])
        );
    }

    #[test]
    fn unknown_versions_are_not_used_to_query_authentication() {
        assert_eq!(
            parse_version(ProviderId::Claude, "2.1.310 (Claude Code)\n"),
            Some("2.1.310".into())
        );
        assert_eq!(
            parse_version(ProviderId::Codex, "codex-cli 0.162.0\n"),
            Some("0.162.0".into())
        );
        assert!(parse_version(ProviderId::Codex, "codex-cli <script>").is_none());
        assert!(parse_version(ProviderId::Claude, "2.1.310\nextra (Claude Code)").is_none());
        assert_eq!(
            parse_auth(
                ProviderId::Gemini,
                &capture(0, "", "Logged in using ChatGPT")
            )
            .0,
            "unknown"
        );
    }

    #[test]
    fn an_unreviewed_release_says_so_and_never_claims_the_pin() {
        assert!(codesign_detail(true).contains("pinned"));
        let unreviewed = codesign_detail(false);
        assert!(!unreviewed.contains("pinned"));
        assert!(unreviewed.contains("does not match the reviewed release pin"));
    }

    #[test]
    fn personal_use_confirmation_cannot_make_a_signed_in_provider_usable() {
        let mut status = unavailable(ProviderId::Claude);
        for confirmed in [false, true] {
            set_task_usability(&mut status, true, "signed_in", confirmed);
            assert_eq!(status["usable"]["lead"], false);
            assert_eq!(status["usable"]["worker"], false);
            let blockers = status["usable"]["blockers"].as_array().unwrap();
            assert_eq!(
                blockers
                    .iter()
                    .any(|blocker| blocker == "personal_use_unconfirmed"),
                !confirmed
            );
            assert!(blockers
                .iter()
                .any(|blocker| blocker == "execution_boundary_unavailable"));
        }
    }

    #[test]
    fn an_unreviewed_release_blocks_automated_tasks() {
        let mut status = unavailable(ProviderId::Codex);
        status["usable"]["lead"] = json!(true);
        status["usable"]["worker"] = json!(true);
        set_task_usability(&mut status, false, "signed_in", true);
        assert_eq!(status["usable"]["lead"], false);
        assert_eq!(status["usable"]["worker"], false);
        let blockers = status["usable"]["blockers"].as_array().unwrap();
        assert!(blockers
            .iter()
            .any(|blocker| blocker == "release_unreviewed"));
        assert!(!blockers
            .iter()
            .any(|blocker| blocker == "personal_use_unconfirmed"));
        // The placeholder blockers are not what keeps tasks off for this release.
        assert!(!tasks_enabled(&["release_unreviewed"]));
        assert!(!tasks_enabled(&[]));
    }

    #[test]
    fn a_manual_login_path_is_one_literal_shell_argument() {
        assert_eq!(
            shell_literal("/some path/it's/cli"),
            "'/some path/it'\\''s/cli'"
        );
    }

    #[test]
    fn a_later_launch_failure_invalidates_the_verified_badge() {
        for error in [
            ProbeError::Verification,
            ProbeError::Timeout,
            ProbeError::CleanupPending,
            ProbeError::Busy,
            ProbeError::IdentityGateUnavailable,
        ] {
            let mut status = unavailable(ProviderId::Claude);
            status["binary"]["state"] = json!("verified");
            status["binary"]["verification_scope"] = json!("kernel_identity");
            status["binary"]["release_reviewed"] = json!(false);
            status["sign_in"]["state"] = json!("signed_in");
            probe_failure(&mut status, &error);
            assert_ne!(status["binary"]["state"], "verified");
            assert!(status["binary"].get("verification_scope").is_none());
            assert!(status["binary"].get("release_reviewed").is_none());
            assert_eq!(status["sign_in"]["state"], "unknown");
            if !matches!(error, ProbeError::Verification) {
                assert_ne!(status["binary"]["state"], "failed");
            }
        }
    }
}
