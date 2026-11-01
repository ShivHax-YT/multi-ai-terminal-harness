//! Real CLI observations, kept separate from permission to execute work (T-133).
//! Raw CLI output, account details and tokens never enter the IPC response/logs.

use crate::binary::{self, Discovery, ProbeCommand};
use crate::fs_guard::{self, FileGuard, GuardError, NullSink, RootKind};
use crate::process::{Capture, ProbeError};
use crate::provider::ProviderId;
use serde_json::{json, Value};
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

#[derive(Default)]
pub struct ProviderRegistry {
    confirmed: Mutex<BTreeSet<ProviderId>>,
}

/// Called only by the app's explicit human Terminal login mode, never by a task
/// or scheduler. The CLI's own sign-in UI handles every authentication response.
pub fn login_in_terminal(provider: ProviderId) -> Result<i32, String> {
    let Discovery::Found(cli) = binary::discover(provider) else {
        return Err("A supported native CLI was not found.".into());
    };
    cli.terminal_login().map_err(|e| e.to_string())
}

/// Called only by the app's closed human terminal mode, on the terminal the human is driving. The kernel checks the
/// CLI's identity at launch. Nothing the app or a model produced enters its arguments.
pub fn session_in_terminal(provider: ProviderId, cwd: &Path) -> Result<i32, String> {
    let Discovery::Found(cli) = binary::discover(provider) else {
        return Err("A supported native CLI was not found.".into());
    };
    let ambient: Vec<(String, String)> = std::env::vars().collect();
    cli.terminal_session(cwd, &ambient)
        .map_err(|e| e.to_string())
}

/// The current time as the contract's timestamp text.
pub fn timestamp() -> String {
    chrono::Utc::now().to_rfc3339()
}

/// The whole environment for a human terminal's child process (rules 2 and 4).
pub fn human_terminal_env() -> Result<Vec<(String, String)>, String> {
    let home = fs_guard::account_home().map_err(|e| e.to_string())?;
    let ambient: Vec<(String, String)> = std::env::vars().collect();
    Ok(binary::session_env(&home, &ambient))
}

/// Why a provider cannot open a human terminal, before anything starts.
pub fn human_terminal_check(provider: ProviderId) -> Result<(), &'static str> {
    if !supported(provider) {
        return Err("This provider has no supported terminal yet.");
    }
    match binary::discover(provider) {
        Discovery::Found(_) => Ok(()),
        Discovery::Missing => Err("Install the official CLI first."),
        Discovery::Unverified => Err("The installed CLI could not be checked safely."),
    }
}

/// Resolves a folder the human picked. It must be a real directory and never a credential store (rule 4).
pub fn human_terminal_folder(folder: &Path) -> Result<PathBuf, &'static str> {
    const REFUSED: &str = "That folder cannot be used.";
    let home = fs_guard::account_home().map_err(|_| REFUSED)?;
    let guard = FileGuard::new(&home, Arc::new(NullSink)).map_err(|_| REFUSED)?;
    match guard.register_root(RootKind::Repo, folder) {
        Ok(()) => {}
        Err(GuardError::Denied { .. }) => {
            return Err("That folder holds CLI credentials, so it cannot be used.")
        }
        Err(GuardError::NotAbsolute) => return Err("Enter the full path of a folder."),
        Err(GuardError::Io(_)) => return Err("That folder does not exist."),
        Err(_) => return Err(REFUSED),
    }
    let canonical = folder.canonicalize().map_err(|_| REFUSED)?;
    if !canonical.is_dir() {
        return Err("That path is not a folder.");
    }
    Ok(canonical)
}

impl ProviderRegistry {
    pub fn personal_use_confirmed(&self, provider: ProviderId) -> bool {
        self.confirmed
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .contains(&provider)
    }

    /// The human confirmed in the terminal dialog that this is their own account (rule 5).
    /// This is the in-memory mark only. It does not check that the CLI is verified; `confirm` keeps that check.
    /// It never clears task blockers or makes a provider usable for automated work.
    pub fn note_personal_use(&self, provider: ProviderId) {
        self.confirmed
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(provider);
    }

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
        let cli = match binary::discover(provider) {
            Discovery::Missing => return status,
            Discovery::Unverified => {
                status["install"]["state"] = json!("installed");
                status["usable"]["blockers"] = json!([
                    "binary_unchecked",
                    "execution_boundary_unavailable",
                    "runtime_controls_unavailable",
                    "provider_policy_unverified"
                ]);
                return status;
            }
            Discovery::Found(cli) => cli,
        };
        status["install"]["state"] = json!("installed");
        status["install"]["path"] = json!(cli.path);
        let now = chrono::Utc::now().to_rfc3339();
        status["binary"]["checked_at"] = json!(now);
        // A routine vendor update changes the release hash. Report it as the official CLI it is, on the vendor
        // identity alone, and record that this release is unreviewed. Tasks stay off either way.
        let (first_probe, release_reviewed) = match cli.probe(ProbeCommand::Version) {
            Err(ProbeError::Verification) => (cli.probe_any_release(ProbeCommand::Version), false),
            other => (other, true),
        };
        let version = match first_probe {
            Ok(output) if output.code == 0 => parse_version(provider, &output.stdout),
            Err(error) => {
                probe_failure(&mut status, &error);
                return status;
            }
            _ => None,
        };
        let Some(version) = version else {
            status["binary"]["state"] = json!("failed");
            status["binary"]["checks"] = json!([{"kind":"codesign", "result":"fail", "detail":"The signed CLI did not return a supported version response."}]);
            status["usable"]["blockers"] = json!([
                "binary_failed",
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
            {"kind":"install_source", "result":"pass", "detail":"Native vendor-signed image discovered at a supported installation entrypoint; installer history is not inferred."}
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
        if state != "signed_in" {
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
        // Lead and worker stay false. An unreviewed vendor release is an explicit task blocker, separate from the
        // human terminal, which may still open that signed CLI.
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
        "macOS enforced the vendor, CLI identifier, Developer ID category and hardened runtime at launch. This vendor-signed release is newer than the one reviewed for this build, so tasks stay off for it. Terminals are not affected."
    }
}

/// Human terminals are open only for providers this build can launch with a compiled vendor pin.
/// Grok, Kimi, Gemini and GLM stay closed: this tree has no pin for the first three, Gemini has no
/// app-managed key launch, and GLM has no base-URL setting here.
pub fn human_terminal_supported(provider: ProviderId) -> bool {
    matches!(provider, ProviderId::Claude | ProviderId::Codex)
}

fn supported(provider: ProviderId) -> bool {
    human_terminal_supported(provider)
}

/// Automated workers are not part of this build. `tasks_enabled` still refuses `release_unreviewed` on its own,
/// so deleting the placeholder blockers cannot make an unreviewed release runnable.
const WORKERS_ENABLED: bool = false;

/// Writes the automated-task gate. A vendor-signed release that this build has not reviewed gets its own blocker,
/// separate from the human terminal.
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
    WORKERS_ENABLED
        && blockers
            .iter()
            .all(|blocker| *blocker != "release_unreviewed")
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
    status["binary"]["state"] = json!(if refused { "failed" } else { "unchecked" });
    status["binary"]["checks"] = json!([{"kind":"codesign", "result":if refused { "fail" } else { "not_applicable" }, "detail":error.to_string()}]);
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
        assert!(unreviewed.contains("tasks stay off"));
    }

    #[test]
    fn a_terminal_folder_must_be_a_real_directory_outside_credential_stores() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(
            human_terminal_folder(dir.path()).unwrap(),
            dir.path().canonicalize().unwrap()
        );
        assert!(human_terminal_folder(Path::new("relative/path")).is_err());
        assert!(human_terminal_folder(&dir.path().join("missing")).is_err());
        let file = dir.path().join("file");
        std::fs::write(&file, "x").unwrap();
        assert!(human_terminal_folder(&file).is_err());
        let home = fs_guard::account_home().unwrap();
        let denylist = fs_guard::Denylist::embedded().unwrap();
        assert!(!denylist.home_dirs().is_empty());
        for store in denylist.home_dirs() {
            // Lexical refusal: the path is never opened.
            assert!(human_terminal_folder(&home.join(store)).is_err(), "{store}");
        }
    }

    #[test]
    fn only_supported_providers_can_open_a_human_terminal() {
        for provider in [
            ProviderId::Grok,
            ProviderId::Kimi,
            ProviderId::Gemini,
            ProviderId::Glm,
        ] {
            assert!(human_terminal_check(provider).is_err());
        }
    }

    #[test]
    fn noting_personal_use_never_makes_a_provider_usable_for_tasks() {
        let registry = ProviderRegistry::default();
        assert!(!registry.personal_use_confirmed(ProviderId::Claude));
        registry.note_personal_use(ProviderId::Claude);
        assert!(registry.personal_use_confirmed(ProviderId::Claude));
        // Supported provider, signed in, no confirmation: tasks stay blocked on that fact.
        let mut status = unavailable(ProviderId::Claude);
        set_task_usability(&mut status, true, "signed_in", false);
        assert_eq!(status["usable"]["lead"], false);
        assert_eq!(status["usable"]["worker"], false);
        let blockers = status["usable"]["blockers"].as_array().unwrap();
        assert!(blockers
            .iter()
            .any(|blocker| blocker == "personal_use_unconfirmed"));
        assert!(blockers
            .iter()
            .any(|blocker| blocker == "execution_boundary_unavailable"));
        set_task_usability(&mut status, true, "signed_in", true);
        assert_eq!(status["usable"]["lead"], false);
        assert_eq!(status["usable"]["worker"], false);
        let confirmed = status["usable"]["blockers"].as_array().unwrap();
        assert!(!confirmed
            .iter()
            .any(|blocker| blocker == "personal_use_unconfirmed"));
        assert!(confirmed
            .iter()
            .any(|blocker| blocker == "execution_boundary_unavailable"));
        let gemini = registry.refresh(ProviderId::Gemini);
        assert_eq!(gemini["usable"]["worker"], false);
        assert_eq!(gemini["usable"]["lead"], false);
    }

    #[test]
    fn an_unreviewed_release_blocks_automated_tasks_and_not_the_terminal_gate() {
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
        assert!(human_terminal_supported(ProviderId::Claude));
        assert!(human_terminal_supported(ProviderId::Codex));
        for provider in [
            ProviderId::Grok,
            ProviderId::Kimi,
            ProviderId::Gemini,
            ProviderId::Glm,
        ] {
            assert!(!human_terminal_supported(provider), "{provider}");
        }
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
        ] {
            let mut status = unavailable(ProviderId::Claude);
            status["binary"]["state"] = json!("verified");
            status["sign_in"]["state"] = json!("signed_in");
            probe_failure(&mut status, &error);
            assert_ne!(status["binary"]["state"], "verified");
            assert_eq!(status["sign_in"]["state"], "unknown");
            if !matches!(error, ProbeError::Verification) {
                assert_ne!(status["binary"]["state"], "failed");
            }
        }
    }
}
